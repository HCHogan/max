//! `max run` serves; `max check-config` checks a configuration file's
//! structure without reading its secrets, which the NixOS module does when
//! it builds the file; `max vm-check` boots a VM, runs a command in it, a
//! program that calls the MCP service, one that opens a tab in the browser
//! and one that finds the tab as the first left it.

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
use max::embedding::Embedder;
use max::llm::Models;
use max::mcp;
use max::media::caption::Captioner;
use max::media::download::Download;
use max::media::fetch;
use max::media::pictures::Pictures;
use max::media::stickers::Stickers;
use max::media::store::Store;
use max::qq::admin::Admin;
use max::qq::avatar::Avatars;
use max::qq::link::Linker;
use max::qq::{listen, send};
use max::recall::Vectors;
use max::scope::Scope;
use max::search::{self, Search};
use max::table::{self, Me, Table};
use max::tools;
use max::vm::Vms;
use max::worker::Rows;

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
        // No conversation has id 0, so the program's history finds nothing,
        // from the database.
        let context = || {
            let services = mcp::Services {
                pool: PgPool::connect_lazy(&config.database.url)?,
                offset: config.utc_offset,
                search: None,
                store: None,
                embedder: None,
                admin: None,
            };
            Ok::<_, sqlx::Error>(mcp::Context {
                services: Arc::new(services),
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
                page_tokens: 2000,
                work: None,
                caller: mcp::Caller::Check,
            })
        };
        let shell = Tool::Shell {
            command,
            workdir: None,
            timeout_ms: None,
        };
        let program = Tool::RunCode {
            code: "const read = await max.raw('history', {around: 1});\n\
                   return {node: process.version, mcp: read.ok ? 'ok' : read.error.code}"
                .into(),
            args: None,
            timeout_ms: None,
        };
        let browse = |code: &str| Tool::RunCode {
            code: code.into(),
            args: None,
            timeout_ms: None,
        };
        let mut outs = Vec::new();
        for tool in [shell, program, browse(BROWSE), browse(BROWSE_AGAIN)] {
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

/// vm-check's tab in the browser: how long the browser took to start and
/// the page to load, the snapshot, a field filled by its ref, a screenshot
/// in /work, and what the browser tells the page it is.
const BROWSE: &str = r#"const started = Date.now();
const page = await (await max.browser()).newPage();
const connected = Date.now();
await page.goto("data:text/html;charset=utf-8," + encodeURIComponent(
  "<html lang=zh-CN><title>检查</title><h1>你好，浏览器</h1><input name=q placeholder=搜索><button id=go>搜索</button>"));
const loaded = Date.now();
const tree = await max.snapshot(page);
const ref = /textbox "搜索" \[ref=(e\d+)\]/.exec(tree)[1];
await page.locator(`aria-ref=${ref}`).fill("还在");
await page.screenshot({ path: "/work/.max/browser-check.png" });
const seen = await page.evaluate(() => [navigator.userAgent, navigator.webdriver, navigator.language]);
return { tree, connect_ms: connected - started, page_ms: loaded - connected, seen };"#;

/// The next program finds the tab as the last one left it; and the most
/// memory the browser has used, in MiB.
const BROWSE_AGAIN: &str = r#"const page = await max.page();
const kept = await page.inputValue("input");
await page.close();
const fs = await import("node:fs");
const peak = Number(fs.readFileSync("/sys/fs/cgroup/system.slice/max-browser.service/memory.peak", "utf8"));
return { kept, peak_mib: Math.round(peak / 2 ** 20) };"#;

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

    let mut workers = Scope::new();
    let embedder = match &config.embedding {
        Some(embedding) => {
            let key = embedding.api_key()?;
            let model = embedding.model.clone();
            Some(Arc::new(Embedder::new(&embedding.base_url, model, key)?))
        }
        None => {
            info!("no embedding model: find_stickers says so, and history matches words only");
            None
        }
    };
    // Each committed row comes to the recall vector worker.
    let mut rows = Rows::default();
    if let Some(embedder) = &embedder {
        let worker = Vectors {
            pool: pool.clone(),
            embedder: Arc::clone(embedder),
        };
        let rx = rows.subscribe();
        workers.spawn(move |stop| worker.run(rx, stop));
    }
    let stickers = embedder.as_ref().map(|embedder| {
        let worker = Stickers {
            pool: pool.clone(),
            embedder: Arc::clone(embedder),
        };
        let (tx, rx) = mpsc::unbounded_channel();
        workers.spawn(move |stop| worker.run(rx, stop));
        tx
    });
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
                        stickers,
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
    let search = match &config.search {
        Some(search) => Some(Arc::new(Search::new(search::EXA, search.api_key()?)?)),
        None => {
            info!("no search: web_search says so");
            None
        }
    };
    // Accounts are linked to old QQ numbers by their avatars, once Max's
    // own account is known.
    let linking = match &qq {
        Some(credentials) => {
            let avatars = Arc::new(Avatars::qq(&credentials.app_id)?);
            Some((avatars, rows.subscribe()))
        }
        None => None,
    };
    let client = match qq {
        Some(credentials) => Some(Arc::new(qqbot::Client::new(credentials)?)),
        None => None,
    };
    // A tool mutes through QQ's client directly; see qq::admin.
    let admin = client
        .as_ref()
        .map(|client| Arc::clone(client) as Arc<dyn Admin>);
    let mut services = Scope::new();
    let vm_dir = config.vm.as_ref().map(|vm| vm.dir.clone());
    let vms = match config.vm {
        Some(vm) => Some(Vms::start(vm, &mut services)?),
        None => {
            info!("no VMs: the tools can't run");
            None
        }
    };
    // The pictures Max sends come from the content store.
    let store = pictures
        .as_ref()
        .map(|pictures| Arc::clone(&pictures.store));
    let tools = Arc::new(mcp::Services {
        pool: pool.clone(),
        offset: config.utc_offset,
        search,
        store: store.clone(),
        embedder,
        admin,
    });
    let (outbound, outbound_rx) = mpsc::unbounded_channel();
    let shared = Arc::new(Shared {
        services: tools,
        models,
        outbound,
        stop_grace: STOP_GRACE,
        owners,
        binds: Arc::default(),
        rows,
        vms,
        vm_dir,
        pictures,
        started: tokio::time::Instant::now(),
    });
    let (intake_tx, intake_rx) = mpsc::unbounded_channel();
    let mut me = HashMap::new();
    let mut intake = Scope::new();
    let mut senders = Scope::new();
    // Set when an adapter stops for good: Max stops too, and fails.
    let failed = CancellationToken::new();
    if let Some(client) = client {
        let bot = client.me().await.wrap_err("checking the QQ credentials")?;
        let mut conn = pool.acquire().await?;
        let account = platform::account(&mut conn, Platform::Qq, &bot.id, &bot.username).await?;
        drop(conn);
        info!(bot = %bot.username, "QQ credentials work");
        if let Some((avatars, rows)) = linking {
            let mut barred = shared.owners.clone();
            barred.insert(account.principal);
            let linker = Linker {
                pool: pool.clone(),
                avatars,
                barred,
            };
            workers.spawn(move |stop| linker.run(rows, stop));
        }
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
        senders.spawn(move |_| send::run(api, sending, store, outbound_rx, DRAIN));
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
    // The sender drains once every handle to it is gone.
    drop(shared);
    senders.close(DRAIN + Duration::from_secs(5)).await;
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
