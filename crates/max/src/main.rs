//! `max run` serves; `max check-config` checks a configuration file's
//! structure without reading its secrets, which the NixOS module does when
//! it builds the file; `max vm-check` boots a VM, runs a command in it, a
//! program that calls the MCP service, one that opens a tab in the browser
//! and one that finds the tab as the first left it, calls the MCP service
//! with maxx from a command, keeps a unit of its own in /work/.max/systemd
//! and wakes Max with max-wake, and runs a background command, whose end
//! the guest tells it of.

use std::collections::{BTreeSet, HashMap};
use std::io::{IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use clap::{Parser, Subcommand};
use color_eyre::config::{HookBuilder, Theme};
use color_eyre::eyre::{Result, WrapErr, bail};
use max_core::ids::{ConversationId, EndpointId, IdentityId, PrincipalId};
use max_core::item::{Part, ToolOutput};
use max_core::message::Platform;
use max_core::tools::Tool;
use max_db::PgPool;
use max_db::platform::{self, Account, ConversationKind};
use tokio::signal::unix::{SignalKind, signal};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use tracing::{error, info};

use max::config::{self, Config};
use max::conversation::{Place, Shared, Signal};
use max::dreamer::Dreamer;
use max::embedding::Embedder;
use max::llm::{Models, Upstream};
use max::mcp;
use max::media::caption::Captioner;
use max::media::download::Download;
use max::media::fetch;
use max::media::pictures::Pictures;
use max::media::stickers::Stickers;
use max::media::store::Store;
use max::qq::groups::Groups;
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
        /// On the operations network's last slot instead, as a group of
        /// `vm.operations` would be: `--command "ssh <host> hostname"`
        /// checks the way to the fleet.
        #[arg(long)]
        operations: bool,
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
        Command::VmCheck {
            args,
            command,
            operations,
        } => vm_check(&args.config, command, operations),
    }
}

/// On the last slot, which a running service takes last; or the
/// operations network's last.
fn vm_check(path: &Path, command: String, operations: bool) -> Result<()> {
    let mut config = Config::load(path)?;
    logging(&config);
    let Some(mut vm) = config.vm.take() else {
        bail!("the configuration has no [vm]");
    };
    vm.slots.drain(..vm.slots.len() - 1);
    match vm.operations.as_mut() {
        // vm-check's conversation, 0, is one of its groups.
        Some(ops) if operations => {
            ops.slots.drain(..ops.slots.len() - 1);
            ops.conversations = vec![0];
        }
        Some(ops) => ops.conversations.clear(),
        None if operations => bail!("the configuration has no [vm.operations]"),
        None => {}
    }
    // A directory of its own. The VM service boots again the VMs it finds
    // there with units, and a second boot of a VM maxx runs would take
    // that VM's sockets from it (2026-11-03).
    vm.dir = vm.dir.join("check");
    // And units of its own, by their instance: max leaves them alone, as
    // vm-check does max's.
    vm.instances = "check-".to_owned();
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    let outs = runtime.block_on(async {
        let mut services = Scope::new();
        let (signals, mut heard) = mpsc::unbounded_channel();
        // The background agents' model: a provider of vm-check's own,
        // which says one thing to whatever it is asked.
        let provider = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let base_url = format!("http://{}/v1", provider.local_addr()?);
        services.spawn(move |stop| async move {
            let says = || async { ([("content-type", "text/event-stream")], AGENT_SAYS) };
            let app = axum::Router::new().route("/v1/chat/completions", axum::routing::post(says));
            let served = axum::serve(provider, app);
            let _ = served.with_graceful_shutdown(stop.cancelled_owned()).await;
        });
        let (agents, mut used) = mcp::Model::heard(Upstream {
            provider: "vm-check".into(),
            protocol: max_core::item::Protocol::Chat,
            base_url,
            api_key: None,
            headers: Vec::new(),
            model: "vm-check".into(),
            window: 100_000,
            max_output: None,
            effort: None,
            idle: Duration::from_secs(60),
        });
        let vms = Vms::start(vm, &mut services, signals, Arc::default(), Some(agents))?;
        // A store of vm-check's own, for what calls show the model.
        let stored = std::env::temp_dir().join(format!("maxx-vm-check-{}", std::process::id()));
        let store = Arc::new(Store::open(&stored).await?);
        // What something in the VM calls is run here, as a conversation's
        // actor would run it, with nobody to say anything for. No
        // conversation has id 0, so its history finds nothing, from the
        // database.
        let called = mcp::Context {
            services: Arc::new(mcp::Services {
                pool: PgPool::connect_lazy(&config.database.url)?,
                offset: config.utc_offset,
                search: None,
                store: Some(Arc::clone(&store)),
                embedder: None,
                groups: None,
            }),
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
            call_time: Duration::from_secs(config.limits.call_time_secs),
            poster: None,
        };
        // But what maxx wake would wake Max with, which is noted. A
        // background command's end comes that way, from the guest: `told`
        // has each as it comes.
        let woken = Arc::new(Mutex::new(Vec::new()));
        let noted = Arc::clone(&woken);
        let (tell, mut told) = mpsc::unbounded_channel::<String>();
        services.spawn(move |_| async move {
            while let Some(signal) = heard.recv().await {
                let (text, reply) = match signal {
                    Signal::Call {
                        tool, args, reply, ..
                    } if tool == "wake" => {
                        let text = args["text"].as_str().unwrap_or_default().to_owned();
                        (text, Some(reply))
                    }
                    Signal::Call {
                        tool, args, reply, ..
                    } => {
                        let _ = reply.send(mcp::call(&tool, &called, args).await);
                        continue;
                    }
                    Signal::Notice { text, .. } => (text, None),
                    // vm-check has no timeline, and one conversation.
                    Signal::Subscribe { .. } | Signal::Ask { .. } => continue,
                };
                // Noted before maxx wake hears back, and vm-check goes on.
                noted
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .push(text.clone());
                let _ = tell.send(text);
                if let Some(reply) = reply {
                    let _ = reply.send(Ok(serde_json::json!({ "said": "vm-check 收到了" })));
                }
            }
        });
        // A model that watches what the calls show it.
        let context = tools::Context {
            conversation: ConversationId(0),
            store: Some(store),
            video: true,
        };
        let shell = Tool::Shell {
            command,
            workdir: None,
            timeout_ms: None,
            background: false,
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
        let command = |command: &str| Tool::Shell {
            command: command.into(),
            workdir: None,
            timeout_ms: None,
            background: false,
        };
        let steps = [
            shell,
            program,
            browse(BROWSE),
            browse(BROWSE_AGAIN),
            command(EXTENSION),
            browse(EXTENSION_PAGE),
            command(VIDEO),
            command(MAXX),
            command(UNITS),
        ];
        let mut outs = Vec::new();
        for tool in steps {
            outs.push(tools::run(tool, Some(&vms), &context).await);
        }
        // A background command: a unit of the guest's, which max doesn't
        // wait for. Its output is in its file before it ends; its maxx
        // calls as a call's does; and the guest tells of its end with a
        // wake of its own.
        let background = Tool::Shell {
            command: "echo 后台起了; sleep 1; \
                      grep -c 后台起了 \"$(ls -t /work/.max/out/max-job-*.txt | head -1)\"; \
                      max-wake 'vm-check 叫醒了自己'"
                .into(),
            workdir: None,
            timeout_ms: Some(60_000),
            background: true,
        };
        outs.push(tools::run(background, Some(&vms), &context).await);
        outs.push(match told_of(&mut told, "[max-job-", 60).await {
            Some(text) => {
                let whole = text.contains("完成] $ echo 后台起了")
                    && text.contains("exit status 0")
                    && text.contains("后台起了\n1\n");
                ToolOutput::text(format!("后台命令结束的通知：{text}"), !whole, 0)
            }
            None => ToolOutput::text("后台命令结束了没人说".to_owned(), true, 0),
        });
        // A background agent: a unit of the guest's too, pi itself, whose
        // model calls come through max to vm-check's provider, and whose
        // report the guest wakes Max with.
        let agent = command("max-agent start --title 检查 <<< '说一句话就行'");
        outs.push(tools::run(agent, Some(&vms), &context).await);
        outs.push(match told_of(&mut told, "[max-agent-", 180).await {
            Some(text) => {
                let whole = text.contains("完成] 检查\nvm-check 的 agent 说完了");
                ToolOutput::text(format!("后台 agent 的报告：{text}"), !whole, 0)
            }
            None => ToolOutput::text("后台 agent 结束了没人说".to_owned(), true, 0),
        });
        let mut calls = 0;
        let mut output = 0;
        while let Ok((_, called)) = used.try_recv() {
            calls += 1;
            output += called.usage.output;
        }
        outs.push(ToolOutput::text(
            format!("后台 agent 的模型调用：{calls} 次，写了 {output} tokens"),
            calls == 0,
            0,
        ));
        let woken = woken
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .join("\n");
        outs.push(ToolOutput::text(
            format!("叫醒：{woken}"),
            woken.is_empty(),
            0,
        ));
        // A VM outlives the service that booted it, as it outlives max:
        // vm-check stops its own, and the next run boots afresh.
        vms.shut().await;
        drop(vms);
        services.close(Duration::from_secs(5)).await;
        let _ = std::fs::remove_dir_all(&stored);
        Ok::<_, color_eyre::Report>(outs)
    })?;
    runtime.shutdown_timeout(SHUTDOWN);
    let mut stdout = std::io::stdout();
    for out in &outs {
        for part in &out.parts {
            match part {
                Part::Text { text } => writeln!(stdout, "{text}")?,
                // What the host read of what a call left to show.
                Part::Video { seconds, .. } => writeln!(stdout, "给模型看的视频：{seconds} 秒")?,
                Part::Media { .. } => writeln!(stdout, "给模型看的图片")?,
            }
        }
        if out.error {
            bail!("the check didn't run");
        }
    }
    Ok(())
}

/// The next thing the guest wakes Max with that begins with `prefix`, if
/// it comes within `secs` seconds.
async fn told_of(
    told: &mut mpsc::UnboundedReceiver<String>,
    prefix: &str,
    secs: u64,
) -> Option<String> {
    let next = async {
        while let Some(text) = told.recv().await {
            if text.starts_with(prefix) {
                return Some(text);
            }
        }
        None
    };
    let waited = tokio::time::timeout(Duration::from_secs(secs), next).await;
    waited.ok().flatten()
}

/// What vm-check's provider answers a background agent's model call with:
/// its report, and what the call used.
const AGENT_SAYS: &str = "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"vm-check 的 agent 说完了\"}}]}\n\n\
     data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":7}}\n\n\
     data: [DONE]\n\n";

/// maxx from a command: a call the history refuses, as the program's was,
/// and the tools it lists.
const MAXX: &str = r#"maxx history --around 1; echo "maxx 退出码 $?"
maxx | grep -c '^  history  '"#;

/// A unit of vm-check's own in /work/.max/systemd, which notes each boot
/// it starts in: max-units starts it now, or the boot already has. The
/// nested test runs vm-check twice: the second boot starts it before
/// max-units is run, and both boots are noted. The unit and the command
/// both have /work for a home.
const UNITS: &str = r#"before=$(systemctl is-active boot-note.service || true)
mkdir -p /work/.max/systemd
cat > /work/.max/systemd/boot-note.service <<'EOF'
[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/bin/sh -c 'cat /proc/sys/kernel/random/boot_id >> /work/.max/boot-notes; echo "$$HOME" > /work/.max/unit-home'
[Install]
WantedBy=multi-user.target
EOF
max-units
echo "开机时：$before"
echo "记下了 $(sort -u /work/.max/boot-notes | wc -l) 次开机"
echo "家：$HOME，unit 的家：$(cat /work/.max/unit-home)"
case ":$PATH:" in *:/work/.nix-profile/bin:*) echo "PATH 里有家里的 profile" ;; esac"#;

/// An extension of vm-check's own, which the browser loads by Max's flags
/// once it starts again: its script marks each page it runs on.
const EXTENSION: &str = r#"mkdir -p /work/.max/ext/hello
cat > /work/.max/ext/hello/manifest.json <<'EOF'
{"manifest_version": 3, "name": "hello", "version": "1",
 "content_scripts": [{"matches": ["<all_urls>"], "js": ["hello.js"]}]}
EOF
echo 'document.documentElement.dataset.hello = "扩展在";' > /work/.max/ext/hello/hello.js
echo '--load-extension=/work/.max/ext/hello' > /work/.max/chromium-flags
systemctl restart max-browser.service && echo "浏览器重启了""#;

/// A page the extension's script ran on: one Playwright makes up, as the
/// VM has no site of its own.
const EXTENSION_PAGE: &str = r#"const page = await (await max.browser()).newPage();
await page.route("http://hello.test/", route => route.fulfill({ contentType: "text/html", body: "<title>扩展</title><p>你好</p>" }));
await page.goto("http://hello.test/");
await page.waitForFunction(() => document.documentElement.dataset.hello, null, { timeout: 10000 });
const hello = await page.evaluate(() => document.documentElement.dataset.hello);
await page.close();
return { hello };"#;

/// A video and a picture for the model, from a command: ffmpeg in the VM
/// makes a clip and the copy for the model, the call's line says where
/// they are, and the host reads the copy's length and the picture. A file
/// that isn't a picture is said so in the result.
const VIDEO: &str = r#"ffmpeg -v error -y -f lavfi -i testsrc2=s=1280x720:r=30:d=3 -f lavfi -i sine=d=3 -shortest /work/.max/check.mkv
ffmpeg -v error -y -f lavfi -i testsrc2=s=64x64 -frames:v 1 /work/.max/check.png
maxx video /work/.max/check.mkv | jq -c .
maxx show /work/.max/check.png | jq -c .
echo 不是图 > /work/.max/check.txt
maxx show /work/.max/check.txt > /dev/null"#;

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
    let client = match qq {
        Some(credentials) => Some(Arc::new(qqbot::Client::new(credentials)?)),
        None => None,
    };
    // A tool mutes through QQ's client directly; see qq::groups.
    let groups = client
        .as_ref()
        .map(|client| Arc::clone(client) as Arc<dyn Groups>);
    let mut services = Scope::new();
    let vm_dir = config.vm.as_ref().map(|vm| vm.dir.clone());
    match (&vm_dir, models.dreamer().transpose()?) {
        (Some(dir), Some(chosen)) => {
            let dreamer = Dreamer {
                pool: pool.clone(),
                chosen,
                dir: dir.clone(),
                offset: config.utc_offset,
            };
            workers.spawn(move |stop| dreamer.run(stop));
        }
        (Some(_), None) => info!("no dreamer model: memory files aren't tidied"),
        (None, _) => {}
    }
    // What the VMs have for the conversations, such as max-wake, and what
    // one conversation's actor has for another: a question for its Max.
    let (signals, signals_rx) = mpsc::unbounded_channel();
    let asking = signals.clone();
    // Their secrets are read now, so a missing one stops max here.
    let apis = Arc::new(mcp::api::Apis::load(&config.api)?);
    // The background agents' model, whose key is read now as well. The
    // agents are units in the VMs: max forwards their model calls, and
    // counts what they use.
    let agents = match models.job().transpose()? {
        Some(upstream) => Some(mcp::Model::start(upstream, pool.clone(), &mut services)),
        None => {
            info!("no model for background agents: max-agent starts none");
            None
        }
    };
    let vms = match config.vm {
        Some(vm) => Some(Vms::start(vm, &mut services, signals, apis, agents)?),
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
        groups,
    });
    let (outbound, outbound_rx) = mpsc::unbounded_channel();
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
    // Set when an adapter stops for good: Max stops too, and fails.
    let failed = CancellationToken::new();
    if let Some(client) = client {
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
    conversations.spawn(move |_| table.run(intake_rx, signals_rx, CONVERSATIONS_GRACE));
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
