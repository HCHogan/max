//! `max run` serves; `max check-config` checks a configuration file's
//! structure without reading its secrets, which the NixOS module does when
//! it builds the file; `max vm-check` boots a VM, runs a command in it and
//! a program that calls the MCP service.

use std::collections::{BTreeSet, HashMap};
use std::io::{IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use clap::{Parser, Subcommand};
use color_eyre::config::{HookBuilder, Theme};
use color_eyre::eyre::{Result, WrapErr, bail};
use max_core::ids::{ConversationId, EndpointId, IdentityId, PrincipalId};
use max_core::item::Part;
use max_core::message::Platform;
use max_core::tools::Tool;
use max_db::PgPool;
use max_db::platform::{self, Account, ConversationKind};
use tokio::signal::unix::{SignalKind, signal};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use tracing::{error, info};

use max::config::{self, Config};
use max::conversation::{Place, Shared};
use max::historian::{self, Historian};
use max::llm::Models;
use max::mcp;
use max::media::download::{self, Download};
use max::media::fetch;
use max::media::store::Store;
use max::qq::{listen, send};
use max::scope::Scope;
use max::search::{self, Search};
use max::table::{self, Me, Table};
use max::tools;
use max::vm::Vms;
use max::worker::{self, Rows};

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
    /// Boot a VM on the last slot, run a command as the shell tool does,
    /// and print what the model would be shown.
    VmCheck {
        #[command(flatten)]
        args: Args,
        #[arg(long, default_value = "uname -a")]
        command: String,
    },
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
        Command::VmCheck { args, command } => vm_check(&args.config, command),
    }
}

/// On the last slot, which a running service takes last.
fn vm_check(path: &Path, command: String) -> Result<()> {
    let mut config = Config::load(path)?;
    logging(&config);
    let Some(mut vm) = config.vm.take() else {
        bail!("the configuration has no [vm]");
    };
    vm.slots.drain(..vm.slots.len() - 1);
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    let outs = runtime.block_on(async {
        let mut services = Scope::new();
        let vms = Vms::start(vm, &mut services)?;
        // No conversation has id 0, so the program's context_read finds
        // nothing, from the database.
        let context = || {
            Ok::<_, sqlx::Error>(mcp::Context {
                pool: PgPool::connect_lazy(&config.database.url)?,
                place: Arc::new(Place {
                    conversation: ConversationId(0),
                    kind: ConversationKind::Group,
                    endpoint: EndpointId(0),
                    platform: Platform::Qq,
                    native_id: "vm-check".into(),
                    me: Account {
                        identity: IdentityId(0),
                        principal: PrincipalId(0),
                    },
                    my_name: "maxx".into(),
                }),
                offset: config.utc_offset,
                page_tokens: 2000,
                search: None,
            })
        };
        let shell = Tool::Shell {
            command,
            workdir: None,
            timeout_ms: None,
        };
        let program = Tool::RunCode {
            code: "const read = await max.raw('context_read', {id: 1});\n\
                   return {node: process.version, mcp: read.ok ? 'ok' : read.error.code}"
                .into(),
            args: None,
            timeout_ms: None,
        };
        let mut outs = Vec::new();
        for tool in [shell, program] {
            outs.push(tools::run(tool, Some(&vms), context()?).await);
        }
        drop(vms);
        services.close(Duration::from_secs(5)).await;
        Ok::<_, color_eyre::Report>(outs)
    })?;
    runtime.shutdown_timeout(SHUTDOWN);
    let mut stdout = std::io::stdout();
    for out in &outs {
        for part in &out.parts {
            if let Part::Text { text } = part {
                writeln!(stdout, "{text}")?;
            }
        }
        if out.error {
            bail!("the check didn't run");
        }
    }
    Ok(())
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

    let mut rows = Rows::default();
    let mut historians = Scope::new();
    let historian = match models.historian().transpose()? {
        Some(chosen) => {
            let historian = Historian {
                pool: pool.clone(),
                models: Arc::clone(&models),
                chosen,
                offset: config.utc_offset,
            };
            let (notices, rx) = rows.subscribe();
            historians.spawn(move |stop| historian::run(historian, rx, stop));
            Some(notices)
        }
        None => {
            info!("no historian model: nothing is summarized");
            None
        }
    };
    let mut workers = Scope::new();
    match &config.media {
        Some(media) => {
            let store = Store::open(&media.dir)
                .await
                .wrap_err("opening the content store")?;
            let download = Arc::new(Download {
                pool: pool.clone(),
                http: fetch::client()?,
                store: Arc::new(store),
            });
            let (_, rows) = rows.subscribe();
            workers.spawn(move |stop| worker::drive(download, download::POLICY, rows, stop));
        }
        None => info!("no media directory: media aren't downloaded"),
    }
    let search = match &config.search {
        Some(search) => Some(Arc::new(Search::new(search::EXA, search.api_key()?)?)),
        None => {
            info!("no search: web_search says so");
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
        rows,
        vms,
        search,
        started: tokio::time::Instant::now(),
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
    info!(commit = max::COMMIT, "serving");

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
    // What they were doing is redone on the next start, or given up.
    workers.close(Duration::ZERO).await;
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
