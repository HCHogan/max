//! `max run` serves; `max check-config` checks a configuration file's
//! structure without reading its secrets, which the NixOS module does when
//! it builds the file.

use std::collections::{BTreeSet, HashMap};
use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use clap::{Parser, Subcommand};
use color_eyre::config::{HookBuilder, Theme};
use color_eyre::eyre::{Result, WrapErr, bail};
use max_core::ids::PrincipalId;
use max_core::message::Platform;
use max_db::{PgPool, platform};
use tokio::signal::unix::{SignalKind, signal};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use tracing::{error, info};

use max::config::{self, Config};
use max::conversation::Shared;
use max::historian::{self, Historian};
use max::llm::Models;
use max::qq::{listen, send};
use max::scope::Scope;
use max::table::{self, Me, Table};
use max::vm::Vms;

// Stopping, in order, within systemd's TimeoutStopSec of 60 seconds.
/// The QQ gateway saves its session.
const INTAKE_GRACE: Duration = Duration::from_secs(5);
/// A conversation's core may go on this long, then is interrupted;
const STOP_GRACE: Duration = Duration::from_secs(20);
/// the table waits a little longer for every conversation.
const CONVERSATIONS_GRACE: Duration = Duration::from_secs(25);
/// The sender sends and records what conversations said.
const DRAIN: Duration = Duration::from_secs(15);
/// Tasks still running when the runtime shuts down.
const SHUTDOWN: Duration = Duration::from_secs(10);

#[derive(Parser)]
#[command(version, about)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Serve.
    Run(Args),
    /// Check a configuration file without reading the secrets it names.
    CheckConfig(Args),
}

#[derive(clap::Args)]
struct Args {
    /// The configuration file.
    #[arg(long)]
    config: PathBuf,
}

fn main() -> Result<()> {
    // journald keeps the colours' escape codes as they are.
    let theme = if std::io::stderr().is_terminal() {
        Theme::dark()
    } else {
        Theme::new()
    };
    HookBuilder::new().theme(theme).install()?;
    match Cli::parse().command {
        Command::CheckConfig(args) => Config::load(&args.config).map(drop),
        Command::Run(args) => run(&args.config),
    }
}

fn run(path: &Path) -> Result<()> {
    let config = Config::load(path)?;
    logging(&config);
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    let served = runtime.block_on(serve(config));
    // Dropping the runtime would wait on blocking tasks for as long as
    // they take.
    runtime.shutdown_timeout(SHUTDOWN);
    served
}

fn logging(config: &Config) {
    let journal = std::env::var_os("JOURNAL_STREAM").is_some();
    let logs = tracing_subscriber::fmt()
        .with_max_level(config.log.level)
        .with_ansi(std::io::stdout().is_terminal());
    // journald stamps each line itself.
    if journal {
        logs.without_time().init();
    } else {
        logs.init();
    }
}

async fn serve(config: Config) -> Result<()> {
    let qq = config
        .platforms
        .qq
        .as_ref()
        .map(config::Qq::credentials)
        .transpose()?;
    let models = Arc::new(Models::new(&config.llm)?);

    let pool = PgPool::connect(&config.database.url)
        .await
        .wrap_err("connecting to the database")?;
    max_db::MIGRATOR
        .run(&pool)
        .await
        .wrap_err("migrating the database")?;
    info!("migrations applied");
    table::close_unfinished(&pool).await?;
    let owners = owners(&pool, &config).await?;

    let mut historians = Scope::new();
    let historian = match models.historian().transpose()? {
        Some(chosen) => {
            let historian = Arc::new(Historian {
                pool: pool.clone(),
                models: Arc::clone(&models),
                chosen,
                offset: config.utc_offset,
            });
            let (notices, rx) = mpsc::unbounded_channel();
            historians.spawn(move |_| historian::run(historian, rx));
            Some(notices)
        }
        None => {
            info!("no historian model: nothing is summarized");
            None
        }
    };
    let mut services = Scope::new();
    let vms = match config.vm {
        Some(vm) => Some(Vms::start(vm, &mut services)?),
        None => {
            info!("no VMs: the tools can't run");
            None
        }
    };
    let (outbound, outbound_rx) = mpsc::unbounded_channel();
    let shared = Arc::new(Shared {
        pool: pool.clone(),
        models,
        outbound,
        offset: config.utc_offset,
        stop_grace: STOP_GRACE,
        owners,
        binds: Arc::default(),
        historian,
        vms,
    });
    let (intake_tx, intake_rx) = mpsc::unbounded_channel();
    let mut me = HashMap::new();
    let mut intake = Scope::new();
    let mut senders = Scope::new();
    // Set when an adapter stops for good: Max stops too, and fails.
    let failed = CancellationToken::new();
    if let Some(credentials) = qq {
        let client = Arc::new(qqbot::Client::new(credentials)?);
        let bot = client.me().await.wrap_err("checking the QQ credentials")?;
        let mut conn = pool.acquire().await?;
        let account = platform::account(&mut conn, Platform::Qq, &bot.id, &bot.username).await?;
        drop(conn);
        info!(bot = %bot.username, "QQ credentials work");
        me.insert(
            Platform::Qq,
            Me {
                account,
                name: bot.username,
            },
        );
        let unconfirmed = send::recover(&pool).await?;
        if unconfirmed > 0 {
            info!(unconfirmed, "messages the last run never heard back about");
        }
        // The only sender, while QQ is the only platform.
        let api = Arc::clone(&client) as Arc<dyn send::Api>;
        let sending = pool.clone();
        senders.spawn(move |_| send::run(api, sending, outbound_rx, DRAIN));
        let (pool, intake_tx, failed) = (pool.clone(), intake_tx.clone(), failed.clone());
        intake.spawn(move |stop| async move {
            if let Err(error) = listen::listen(&client, &pool, &intake_tx, stop).await {
                error!(%error, "QQ's gateway stopped");
                failed.cancel();
            }
        });
    }
    drop(intake_tx);
    let mut conversations = Scope::new();
    let table = Table::new(Arc::clone(&shared), me);
    conversations.spawn(move |_| table.run(intake_rx, CONVERSATIONS_GRACE));
    info!("serving");

    let mut terminate = signal(SignalKind::terminate())?;
    tokio::select! {
        _ = terminate.recv() => {}
        interrupted = tokio::signal::ctrl_c() => interrupted?,
        () = failed.cancelled() => {}
    }
    info!("stopping");
    intake.close(INTAKE_GRACE).await;
    // With intake closed, the table stops every conversation.
    conversations
        .close(CONVERSATIONS_GRACE + Duration::from_secs(5))
        .await;
    // The sender drains, and the historian stops, once every handle to
    // them is gone.
    drop(shared);
    senders.close(DRAIN + Duration::from_secs(5)).await;
    historians.close(Duration::from_secs(5)).await;
    // The VMs are killed: what still ran in them was interrupted already.
    services.close(Duration::ZERO).await;
    pool.close().await;
    if failed.is_cancelled() {
        bail!("a platform's connection stopped for good");
    }
    Ok(())
}

/// The people behind the owners file's accounts, who may run every
/// command.
async fn owners(pool: &PgPool, config: &Config) -> Result<BTreeSet<PrincipalId>> {
    let mut conn = pool.acquire().await?;
    let mut owners = BTreeSet::new();
    for (name, native_id) in config.owners()? {
        let platform = match name.as_str() {
            "qq" => Platform::Qq,
            other => bail!("an owner on a platform Max isn't on: {other:?}"),
        };
        // A name until they first write.
        let account = platform::account(&mut conn, platform, &native_id, "主人").await?;
        owners.insert(account.principal);
    }
    info!(owners = owners.len(), "owners");
    Ok(owners)
}
