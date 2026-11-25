//! `max run` serves; `max check-config` checks a configuration file's
//! structure without reading its secrets, which the NixOS module does when
//! it builds the file; `max vm-check` boots a VM and tries what Max does
//! in one: see `vm_check`.

use std::collections::{BTreeSet, HashMap};
use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use clap::{Parser, Subcommand};
use color_eyre::config::{HookBuilder, Theme};
use color_eyre::eyre::{Result, WrapErr, bail};
use max_core::ids::PrincipalId;
use max_db::PgPool;
use max_db::platform;
use tokio::signal::unix::{SignalKind, signal};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use tracing::{error, info};

use max::adapter::{self, Adapter, Adapters};
use max::config::{self, Config};
use max::conversation::Shared;
use max::llm::Models;
use max::media::caption::Captioner;
use max::media::download::Download;
use max::media::fetch;
use max::media::pictures::Pictures;
use max::media::store::Store;
use max::scope::Scope;
use max::search::{self, Search};
use max::service;
use max::table::{self, Me, Table};
use max::vm::Vms;
use max::worker::Rows;
use max_core::message::Platform;
use max_qq::Qq;

mod vm_check;

use self::vm_check::vm_check;

// Stopping, in order, within systemd's TimeoutStopSec of 60 seconds.
/// The platforms stop listening, as QQ's gateway saves its session.
const INTAKE_GRACE: Duration = Duration::from_secs(5);
/// A conversation's core may go on this long, then is interrupted;
const STOP_GRACE: Duration = Duration::from_secs(20);
/// the table waits a little longer for every conversation.
const CONVERSATIONS_GRACE: Duration = Duration::from_secs(25);
/// The platforms' senders send and record what conversations said.
const DRAIN: Duration = Duration::from_secs(15);
/// Tasks still running when the runtime shuts down.
const SHUTDOWN: Duration = Duration::from_secs(10);

#[derive(Parser)]
#[command(name = "max", version = max::VERSION, about)]
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
    /// Boot a VM on the last slot, run a command as the shell tool does
    /// and two programs as run_code does, and print what the model would
    /// be shown.
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
        Command::CheckConfig(args) => load(&args.config).map(drop),
        Command::Run(args) => run(&args.config),
        Command::VmCheck { args, command } => vm_check(&args.config, command),
    }
}

fn run(path: &Path) -> Result<()> {
    let (config, platforms) = load(path)?;
    logging(config.log.level);
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    let served = runtime.block_on(serve(config, platforms));
    // Dropping the runtime would wait on blocking tasks for as long as
    // they take.
    runtime.shutdown_timeout(SHUTDOWN);
    served
}

/// The platforms' sections of the configuration, as their adapters read
/// them.
#[derive(Debug, Default)]
struct Platforms {
    qq: Option<max_qq::Config>,
}

impl Platforms {
    fn platforms(&self) -> Vec<Platform> {
        self.qq.iter().map(|_| Platform::Qq).collect()
    }
}

/// The configuration file, read and checked, with each platform's section
/// read by its adapter; without reading the secrets it names.
fn load(path: &Path) -> Result<(Config, Platforms)> {
    let config = Config::load(path)?;
    let mut platforms = Platforms::default();
    for (name, section) in &config.platforms {
        let within = || format!("in platforms.{name} of {}", path.display());
        let section = toml::Value::Table(section.clone());
        match name.as_str() {
            "qq" => platforms.qq = Some(section.try_into().wrap_err_with(within)?),
            _ => bail!("{}: Max can't be on platforms.{name}", path.display()),
        }
    }
    Ok((config, platforms))
}

fn logging(level: config::Level) {
    let journal = std::env::var_os("JOURNAL_STREAM").is_some();
    let logs = tracing_subscriber::fmt()
        .with_max_level(level)
        .with_ansi(std::io::stdout().is_terminal());
    // journald stamps each line itself.
    if journal {
        logs.without_time().init();
    } else {
        logs.init();
    }
}

async fn serve(config: Config, platforms: Platforms) -> Result<()> {
    let running = start(config, platforms).await?;
    info!(version = max::VERSION, "serving");
    let mut terminate = signal(SignalKind::terminate())?;
    tokio::select! {
        _ = terminate.recv() => {}
        interrupted = tokio::signal::ctrl_c() => interrupted?,
        () = running.failed.cancelled() => {}
    }
    info!("stopping");
    running.stop().await
}

/// Max as it runs: what `start` started, for `stop` to end in order.
struct Running {
    pool: PgPool,
    /// What every conversation shares; the sender drains once it is gone.
    shared: Arc<Shared>,
    intake: Scope,
    conversations: Scope,
    senders: Scope,
    workers: Scope,
    services: Scope,
    /// Set when an adapter stops for good: Max stops too, and fails.
    failed: CancellationToken,
}

/// The database, migrated, with the turns a crash left running closed.
async fn database(url: &str) -> Result<PgPool> {
    let pool = PgPool::connect(url)
        .await
        .wrap_err("connecting to the database")?;
    max_db::MIGRATOR
        .run(&pool)
        .await
        .wrap_err("migrating the database")?;
    info!("migrations applied");
    table::close_unfinished(&pool).await?;
    Ok(pool)
}

/// What the derived-data workers leave for the rest to use.
struct Derived {
    /// Where each committed row goes, for the workers that take rows.
    rows: Rows,
    pictures: Option<Arc<Pictures>>,
}

/// Starts the derived-data workers the configuration has the means for:
/// with a media directory the downloads and, with a model for them, the
/// captions.
async fn derived(
    config: &Config,
    pool: &PgPool,
    models: &Models,
    workers: &mut Scope,
) -> Result<Derived> {
    let mut rows = Rows::default();
    let pictures = match &config.media {
        Some(media) => {
            let store = Arc::new(
                Store::open(&media.dir)
                    .await
                    .wrap_err("opening the content store")?,
            );
            let pictures = Arc::new(Pictures {
                pool: pool.clone(),
                store: Arc::clone(&store),
            });
            let captions = match models.caption().transpose()? {
                Some(chosen) => {
                    let captioner = Captioner {
                        pool: pool.clone(),
                        chosen,
                        pictures: Arc::clone(&pictures),
                    };
                    let (tx, rx) = mpsc::unbounded_channel();
                    workers.spawn(move |stop| captioner.run(rx, stop));
                    Some(tx)
                }
                None => {
                    info!("no caption model: pictures aren't captioned");
                    None
                }
            };
            let download = Download {
                pool: pool.clone(),
                http: fetch::client()?,
                store,
                captions,
            };
            let rows = rows.subscribe();
            workers.spawn(move |stop| download.run(rows, stop));
            Some(pictures)
        }
        None => {
            info!("no media directory: media aren't downloaded, and models see no pictures");
            None
        }
    };
    Ok(Derived { rows, pictures })
}

/// Starts everything, in the order each needs the one before.
async fn start(config: Config, on: Platforms) -> Result<Running> {
    let models = Arc::new(Models::new(&config.llm)?);
    let pool = database(&config.database.url).await?;
    let owners = owners(&pool, &config, &on.platforms()).await?;

    let mut workers = Scope::new();
    let Derived { rows, pictures } = derived(&config, &pool, &models, &mut workers).await?;
    let search = match &config.search {
        Some(search) => Some(Arc::new(Search::new(search::EXA, search.api_key()?)?)),
        None => {
            info!("no search: web_search says so");
            None
        }
    };
    let mut services = Scope::new();
    let vm_dir = config.vm.as_ref().map(|vm| vm.dir.clone());
    // What the VMs have for the conversations, such as a wake, and what
    // one conversation's actor has for another: a question for its Max.
    let (signals, signals_rx) = mpsc::unbounded_channel();
    let asking = signals.clone();
    // What the VMs call besides Max's tools: the APIs the host keeps the
    // keys of, and the models, the background agents' own and any other
    // one is run on.
    let apis = Arc::new(service::api::Apis::load(&config.api)?);
    let agents = models.job().transpose()?.map(Arc::new);
    if agents.is_none() {
        info!("no model for background agents: pi in a VM has none of max's");
    }
    let vms = match config.vm {
        Some(vm) => Some(Vms::start(
            vm,
            &mut services,
            signals,
            pool.clone(),
            agents,
            apis,
        )?),
        None => {
            info!("no VMs: the tools can't run");
            None
        }
    };
    // The pictures Max sends come from the content store.
    let store = pictures
        .as_ref()
        .map(|pictures| Arc::clone(&pictures.store));
    let mut platforms = Adapters::new();
    if let Some(qq) = &on.qq {
        let qq = Qq::connect(qq, pool.clone(), store.clone());
        let qq = qq.await.wrap_err("checking the QQ credentials")?;
        platforms.insert(qq.platform(), Arc::new(qq));
    }
    let tools = Arc::new(service::Services {
        pool: pool.clone(),
        offset: config.utc_offset,
        search,
        store,
        platforms: platforms.clone(),
    });
    let mut outbound = HashMap::new();
    let mut outbound_rx = HashMap::new();
    for &platform in platforms.keys() {
        let (tx, rx) = mpsc::unbounded_channel();
        outbound.insert(platform, tx);
        outbound_rx.insert(platform, rx);
    }
    let shared = Arc::new(Shared {
        services: tools,
        models,
        outbound,
        stop_grace: STOP_GRACE,
        owners,
        binds: Arc::default(),
        links: Arc::default(),
        signals: asking,
        rows,
        vms,
        vm_dir,
        pictures,
        started: tokio::time::Instant::now(),
        limits: config.limits,
    });
    let (intake_tx, intake_rx) = mpsc::unbounded_channel();
    let mut me = HashMap::new();
    let mut intake = Scope::new();
    let mut senders = Scope::new();
    let failed = CancellationToken::new();
    for (platform, adapter) in platforms {
        let bot = adapter.me();
        let mut conn = pool.acquire().await?;
        let account = platform::account(&mut conn, platform, &bot.id, &bot.name).await?;
        drop(conn);
        info!(%platform, bot = %bot.name, "on a platform");
        let name = bot.name.clone();
        me.insert(platform, Me { account, name });
        let unconfirmed = adapter::recover(&pool, platform).await?;
        if unconfirmed > 0 {
            info!(%platform, unconfirmed, "messages the last run never heard back about");
        }
        if let Some(outbound_rx) = outbound_rx.remove(&platform) {
            senders.spawn(|_| adapter.send(outbound_rx, DRAIN));
        }
        let (intake_tx, failed) = (intake_tx.clone(), failed.clone());
        intake.spawn(move |stop| async move {
            if let Err(error) = adapter.listen(intake_tx, stop).await {
                error!(%platform, %error, "stopped listening to a platform");
                failed.cancel();
            }
        });
    }
    drop(intake_tx);
    let mut conversations = Scope::new();
    let table = Table::new(Arc::clone(&shared), me);
    conversations.spawn(move |_| table.run(intake_rx, signals_rx, CONVERSATIONS_GRACE));
    Ok(Running {
        pool,
        shared,
        intake,
        conversations,
        senders,
        workers,
        services,
        failed,
    })
}

impl Running {
    /// Stops what `start` started, in the order of "Shutdown order" in
    /// docs/architecture.md; an error if an adapter had stopped for good.
    async fn stop(self) -> Result<()> {
        // First, no more is taken from the VMs: what they ask from here on
        // waits at the socket for the next max.
        if let Some(vms) = &self.shared.vms {
            vms.stop_listening();
        }
        self.intake.close(INTAKE_GRACE).await;
        // With intake closed, the table stops every conversation.
        self.conversations
            .close(CONVERSATIONS_GRACE + Duration::from_secs(5))
            .await;
        // The sender drains once every handle to it is gone.
        drop(self.shared);
        self.senders.close(DRAIN + Duration::from_secs(5)).await;
        // What they were doing is redone on the next start, or given up.
        self.workers.close(Duration::ZERO).await;
        // The VMs stay, and what runs in them: the next max attaches to them.
        self.services.close(Duration::ZERO).await;
        self.pool.close().await;
        if self.failed.is_cancelled() {
            bail!("a platform's connection stopped for good");
        }
        Ok(())
    }
}

/// The people behind the owners file's accounts, who may run every
/// command.
async fn owners(pool: &PgPool, config: &Config, on: &[Platform]) -> Result<BTreeSet<PrincipalId>> {
    let mut conn = pool.acquire().await?;
    let mut owners = BTreeSet::new();
    for config::Owner {
        platform,
        native_id,
    } in config.owners(on)?
    {
        // A name until they first write.
        let account = platform::account(&mut conn, platform, &native_id, "主人").await?;
        owners.insert(account.principal);
    }
    info!(owners = owners.len(), "owners");
    Ok(owners)
}
