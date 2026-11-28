//! `max vm-check`: boots a VM, runs a command in it, a program that calls
//! max's service, one that opens a tab in the browser and one that finds
//! the tab as the first left it, calls max's service with maxx from a
//! command, keeps a unit of its own in /work/.max/systemd and wakes Max
//! with maxx wake, and runs a background command, whose end the guest
//! tells it of. Part of the binary: it prints what the model would be
//! shown, and fails if a step did.

use std::io::Write;
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use color_eyre::eyre::{Result, bail, eyre};
use max_core::ids::{ConversationId, EndpointId, IdentityId, PrincipalId};
use max_core::item::{Part, ToolOutput};
use max_core::message::Platform;
use max_core::tools::Tool;
use max_db::PgPool;
use max_db::platform::{Account, ConversationKind};
use tokio::sync::mpsc;

use max::config::{self, Config};
use max::conversation::{Place, Signal};
use max::llm::{Models, Upstreams};
use max::media::store::Store;
use max::scope::Scope;
use max::service;
use max::tools;
use max::vm::Vms;

use super::{SHUTDOWN, logging};

/// The models the VMs may call under vm-check: those of `llm`, and for
/// the background agents a provider of vm-check's own at `base_url`.
fn with_provider(mut llm: config::Llm, base_url: &str) -> Result<Upstreams> {
    let provider = toml::toml! {
        base_url = base_url
        protocol = "chat"
        [models.vm-check]
        context_window = 100_000
    };
    llm.providers
        .insert("vm-check".into(), provider.try_into()?);
    llm.job = Some(config::Selection {
        model: "vm-check/vm-check".parse()?,
        effort: None,
    });
    let agents = Models::new(&llm)?.job().transpose()?;
    agents.ok_or_else(|| eyre!("no model for vm-check's agent"))
}

/// On the last slot, which a running service takes last.
pub(crate) fn vm_check(path: &Path, command: String) -> Result<()> {
    let (config, vm) = configured(path)?;
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    let outs = runtime.block_on(checked(config, vm, command))?;
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

/// The configuration, and its VMs as vm-check has them: the last slot, and
/// a directory and units of its own.
fn configured(path: &Path) -> Result<(Config, config::Vm)> {
    let mut config = Config::load(path)?;
    logging(config.log.level);
    let Some(mut vm) = config.vm.take() else {
        bail!("the configuration has no [vm]");
    };
    vm.slots.drain(..vm.slots.len() - 1);
    // A directory of its own. The VM service boots again the VMs it finds
    // there with units, and a second boot of a VM maxx runs would take
    // that VM's sockets from it (2026-11-03).
    vm.dir = vm.dir.join("check");
    // And units of its own, by their instance: max leaves them alone, as
    // vm-check does max's.
    vm.instances = "check-".to_owned();
    Ok((config, vm))
}

/// Boots the VM, takes it through the steps and stops it: what each step
/// showed.
async fn checked(config: Config, vm: config::Vm, command: String) -> Result<Vec<ToolOutput>> {
    let mut services = Scope::new();
    let (signals, heard) = mpsc::unbounded_channel();
    let (base_url, asked) = provider(&mut services).await?;
    let agents = Arc::new(with_provider(config.llm.clone(), &base_url)?);
    let pool = PgPool::connect_lazy(&config.database.url)?;
    let vms = Vms::start(
        vm,
        &mut services,
        signals,
        pool,
        Some(agents),
        Arc::default(),
    )?;
    // A store of vm-check's own, for what calls show the model.
    let stored = std::env::temp_dir().join(format!("maxx-vm-check-{}", std::process::id()));
    let store = Arc::new(Store::open(&stored).await?);
    let called = called(&config, &store)?;
    let (woken, told) = hearing(&mut services, heard, called);
    let mut check = Check {
        vms,
        // A model that watches what the calls show it.
        context: tools::Context {
            conversation: ConversationId::new(0),
            store: Some(store),
            video: true,
        },
        told,
        asked,
        woken,
    };
    let outs = check.steps(command).await;
    // A VM outlives the service that booted it, as it outlives max:
    // vm-check stops its own, and the next run boots afresh.
    check.vms.shut().await;
    drop(check);
    services.close(Duration::from_secs(5)).await;
    let _ = std::fs::remove_dir_all(&stored);
    Ok(outs)
}

/// The background agents' model: a provider of vm-check's own, which says
/// one thing to whatever it is asked, and counts how often. Its base URL,
/// and the count.
async fn provider(services: &mut Scope) -> Result<(String, Arc<AtomicUsize>)> {
    let provider = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let base_url = format!("http://{}/v1", provider.local_addr()?);
    let asked = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&asked);
    services.spawn(move |stop| async move {
        let says = move || {
            counted.fetch_add(1, Ordering::Relaxed);
            async { ([("content-type", "text/event-stream")], AGENT_SAYS) }
        };
        let app = axum::Router::new().route("/v1/chat/completions", axum::routing::post(says));
        let served = axum::serve(provider, app);
        let _ = served.with_graceful_shutdown(stop.cancelled_owned()).await;
    });
    Ok((base_url, asked))
}

/// What something in the VM calls is run in, as a conversation's actor
/// would run it, with nobody to say anything for. No conversation has id
/// 0, so its history finds nothing, from the database.
fn called(config: &Config, store: &Arc<Store>) -> Result<service::Context> {
    Ok(service::Context {
        services: Arc::new(service::Services {
            pool: PgPool::connect_lazy(&config.database.url)?,
            offset: config.utc_offset,
            search: None,
            store: Some(Arc::clone(store)),
            platforms: max::adapter::Adapters::new(),
        }),
        place: Arc::new(Place {
            conversation: ConversationId::new(0),
            kind: ConversationKind::Group,
            endpoint: EndpointId::new(0),
            platform: Platform::Qq,
            native_id: "vm-check".into(),
            me: Account {
                identity: IdentityId::new(0),
                principal: PrincipalId::new(0),
            },
            my_name: "maxx".into(),
        }),
        page_tokens: 2000,
        work: None,
        call_time: Duration::from_secs(config.limits.call_time_secs),
        poster: None,
    })
}

/// Runs what the VM calls in `called`, but for what maxx wake would wake
/// Max with, which is noted. A background command's end comes that way,
/// from the guest. What was noted, and each as it comes.
fn hearing(
    services: &mut Scope,
    mut heard: mpsc::UnboundedReceiver<Signal>,
    called: service::Context,
) -> (Arc<Mutex<Vec<String>>>, mpsc::UnboundedReceiver<String>) {
    let woken = Arc::new(Mutex::new(Vec::new()));
    let noted = Arc::clone(&woken);
    let (tell, told) = mpsc::unbounded_channel::<String>();
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
                    let _ = reply.send(service::call(&tool, &called, args).await);
                    continue;
                }
                Signal::Vm { text, .. } => (text, None),
                // vm-check has no timeline, and one conversation.
                Signal::Subscribe { .. } => continue,
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
    (woken, told)
}

/// A program for the runner.
fn program(code: &str) -> Tool {
    Tool::RunCode {
        code: code.into(),
        timeout_ms: None,
    }
}

/// A command the call waits for.
fn command(command: &str) -> Tool {
    Tool::Shell {
        command: command.into(),
        workdir: None,
        timeout_ms: None,
        background: false,
    }
}

/// The VM under check, and what vm-check watches it by.
struct Check {
    vms: Vms,
    context: tools::Context,
    /// What the guest wakes Max with, each as it comes.
    told: mpsc::UnboundedReceiver<String>,
    /// How often the agents' model was called.
    asked: Arc<AtomicUsize>,
    /// Everything the guest woke Max with.
    woken: Arc<Mutex<Vec<String>>>,
}

impl Check {
    async fn run(&self, tool: Tool) -> ToolOutput {
        tools::run(tool, Some(&self.vms), &self.context).await
    }

    /// Every step, in order: what each showed.
    async fn steps(&mut self, asked: String) -> Vec<ToolOutput> {
        let history = "const read = await max.raw('history', {around: 1});\n\
                       return {node: process.version, history: read.ok ? 'ok' : read.error.code}";
        let calls = [
            command(BASHRC),
            command(&asked),
            program(history),
            program(BROWSE),
            program(BROWSE_AGAIN),
            command(EXTENSION),
            program(EXTENSION_PAGE),
            command(VIDEO),
            command(MAXX),
            command(UNITS),
        ];
        let mut outs = Vec::new();
        for tool in calls {
            outs.push(self.run(tool).await);
        }
        outs.push(about(&self.vms).await);
        outs.push(self.let_go().await);
        outs.extend(self.background().await);
        outs.extend(self.agent().await);
        let woken = self
            .woken
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .join("\n");
        outs.push(ToolOutput::text(
            format!("叫醒：{woken}"),
            woken.is_empty(),
            0,
        ));
        outs
    }

    /// A call max lets go of before its end, as a killed turn's: its
    /// channel closes, and the guest stops its unit. The call after it
    /// counts what runs besides itself.
    async fn let_go(&self) -> ToolOutput {
        let long = command("touch /work/.max/let-go; sleep 300");
        let waited = Duration::from_secs(3);
        let _ = tokio::time::timeout(waited, self.run(long)).await;
        let left = command(
            "for n in $(seq 30); do \
             others=$(($(systemctl list-units --no-legend --plain --state=active,activating,deactivating 'max-call-*.service' | wc -l) - 1)); \
             [ $others = 0 ] && break; sleep 1; done; \
             echo \"放手的调用跑起来过 $(ls /work/.max/let-go | wc -l) 个，还剩 $others 个\"; \
             rm -f /work/.max/let-go",
        );
        self.run(left).await
    }

    /// A background command: a unit of the guest's, which max doesn't
    /// wait for. Its output is in its file before it ends; its maxx calls
    /// as a call's does; and the guest tells of its end with a wake of
    /// its own.
    async fn background(&mut self) -> [ToolOutput; 2] {
        let background = Tool::Shell {
            command: "echo 后台起了; sleep 1; \
                      grep -c 后台起了 \"$(ls -t /work/.max/out/max-job-*.txt | head -1)\"; \
                      maxx wake 'vm-check 叫醒了自己' | jq -r .said"
                .into(),
            workdir: None,
            timeout_ms: Some(60_000),
            background: true,
        };
        let started = self.run(background).await;
        let ended = match told_of(&mut self.told, "[max-job-", 60).await {
            Some(text) => {
                let whole = text.contains("完成] $ echo 后台起了")
                    && text.contains("exit status 0")
                    && text.contains("后台起了\n1\n");
                ToolOutput::text(format!("后台命令结束的通知：{text}"), !whole, 0)
            }
            None => ToolOutput::text("后台命令结束了没人说".to_owned(), true, 0),
        };
        [started, ended]
    }

    /// A background agent: the guest's fx in a background command, whose
    /// model calls come through max to vm-check's provider, and whose last
    /// words the guest wakes Max with.
    async fn agent(&mut self) -> [ToolOutput; 3] {
        let agent = Tool::Shell {
            command: "fx ask <<< '说一句话就行'".into(),
            workdir: None,
            timeout_ms: Some(180_000),
            background: true,
        };
        let started = self.run(agent).await;
        let report = match told_of(&mut self.told, "[max-job-", 180).await {
            Some(text) => {
                let whole = text.contains("完成] $ fx ask <<<")
                    && text.contains("exit status 0")
                    && text.contains("vm-check 的 agent 说完了");
                ToolOutput::text(format!("后台 agent 的报告：{text}"), !whole, 0)
            }
            None => ToolOutput::text("后台 agent 结束了没人说".to_owned(), true, 0),
        };
        let calls = self.asked.load(Ordering::Relaxed);
        let called = ToolOutput::text(format!("后台 agent 的模型调用：{calls} 次"), calls == 0, 0);
        [started, report, called]
    }
}

/// What `/status` asks of a guest: its NixOS, the memory in use there,
/// and how its systemd has Max's units, which here is the one the step
/// before installed.
async fn about(vms: &Vms) -> ToolOutput {
    let Some(vm) = vms.running(ConversationId::new(0)).await else {
        return ToolOutput::text("客户机没在跑".to_owned(), true, 0);
    };
    match vm.about(&max::vm::units(vm.work())).await {
        Ok(about) => {
            let shown =
                |unit: &max::vm::Unit| format!("{} {} {}", unit.name, unit.load, unit.state);
            let units: Vec<String> = about.units.iter().map(shown).collect();
            let text = format!(
                "客户机：NixOS {}，内存 {} MiB 里用了 {} MiB\nunit：{}",
                about.version,
                about.memory >> 20,
                about.used >> 20,
                units.join("、")
            );
            // Since when it has been so, too.
            let whole = units == ["boot-note.service loaded exited"]
                && about.units[0].since.is_some()
                && (1..about.memory).contains(&about.used);
            ToolOutput::text(text, !whole, 0)
        }
        Err(error) => ToolOutput::text(format!("客户机没说自己怎样：{error:#}"), true, 0),
    }
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

/// A ~/.bashrc as a group's Max might leave one. Read by the shell sshd
/// runs max's own commands in, it would end each before it began: they
/// have another home (nix/guest.nix), and every step after this one,
/// and of the next check, runs with it there.
const BASHRC: &str = "echo 'echo 这一行不该出现; exit 7' > /work/.bashrc";

/// maxx from a command: a call the history refuses, as the program's was,
/// and the tools it lists.
const MAXX: &str = r#"maxx history --around 1; echo "maxx 退出码 $?"
maxx | grep -c '^  history  '"#;

/// A unit of vm-check's own in /work/.max/systemd, which notes each boot
/// it starts in: `maxx units apply` starts it now, or the boot already
/// has. The nested test runs vm-check twice: the second boot starts it
/// before that is run, and both boots are noted, with what the boot's own
/// `maxx units apply` said. The unit and the command both have /work for
/// a home.
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
maxx units apply | jq -r '.units[] | "\(.name)：\(.state)"'
echo "开机时：$before"
echo "开机时装的：$(journalctl -b -u max-units.service -t maxx -o cat --no-pager | tail -n 1)"
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
/// in /work, and what the browser tells the page it is. The snapshot it
/// returns is of the page as it leaves it, for the next program's ref.
const BROWSE: &str = r#"const started = Date.now();
const page = await (await max.browser()).newPage();
const connected = Date.now();
await page.goto("data:text/html;charset=utf-8," + encodeURIComponent(
  "<html lang=zh-CN><title>检查</title><h1>你好，浏览器</h1><input name=q placeholder=搜索><button id=go onclick=\"this.dataset.hit = 1\">搜索</button>"));
const loaded = Date.now();
const ref = /textbox "搜索" \[ref=(e\d+)\]/.exec(await max.snapshot(page))[1];
await page.locator(`aria-ref=${ref}`).fill("还在");
const tree = await max.snapshot(page);
await page.screenshot({ path: "/work/.max/browser-check.png" });
const seen = await page.evaluate(() => [navigator.userAgent, navigator.webdriver, navigator.language]);
return { tree, connect_ms: connected - started, page_ms: loaded - connected, seen };"#;

/// The next program finds the tab as the last one left it, and the
/// button by the ref that program's snapshot gave it; and the most memory
/// the browser has used, in MiB.
const BROWSE_AGAIN: &str = r#"const page = await max.page();
const kept = await page.inputValue("input");
await page.locator("aria-ref=e4").click();
const clicked = await page.evaluate(() => document.getElementById("go").dataset.hit ?? null);
await page.close();
const peak = Number(require("node:fs").readFileSync("/sys/fs/cgroup/system.slice/max-browser.service/memory.peak", "utf8"));
return { kept, clicked, peak_mib: Math.round(peak / 2 ** 20) };"#;
