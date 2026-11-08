//! A job in the group's VM: its harness's wrapper, max-pi, in a unit of
//! its own, given the job on the first line of stdin; its session of the
//! MCP service, which its plugin calls; its model calls on the record as
//! the forwarder tells them; and its report saved in /work.

use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use chrono::Utc;
use color_eyre::eyre::Result;
use max_core::ids::ConversationId;
use max_core::item::{Protocol, Usage};
use max_db::{PgPool, usage};
use serde_json::json;
use tokio::io::AsyncWriteExt;
use tokio::sync::mpsc::UnboundedReceiver;
use tokio::sync::oneshot;
use tokio::time::{Instant, timeout};
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};

use super::{Called, Ending, Exit, GRACE, Hook, How, Watch, drive};
use crate::llm::Upstream;
use crate::mcp;
use crate::vm::ssh::{Sink, Stream, quote};
use crate::vm::{Vm, Vms};

/// Appended to pi's system prompt.
const SYSTEM: &str = "你是 Max 的后台 agent。Max 是一个群聊里的 AI 成员，它把一件要花时间的事交给你，自己接着在群里聊天。
- 你看不到群里的对话，只有 Max 写给你的任务。要聊天记录时用 mcp__max__history 查，能按内容搜，也能按人、按时间读原文；查网上的用 mcp__max__web_search，读网页用 webread <url>（只留正文，转成 Markdown）。
- 你不能在群里说话。你最后一条消息就是交给 Max 的报告：先说结论，再给要点和出处，写给 Max 看，不用客套，尽量在 2000 字以内。做出来的文件放在 /work 下，报告里写路径。
- 做的过程中 Max 可能补充要求，会出现在对话里。卡在只有 Max 或群友才知道的事上（他们的意思、偏好、没说清的要求），用 ask_max 问 Max，它会等 Max 答复；能自己查到、试出来的别问。
- 环境：NixOS，root，能上公网，/work 是本群的持久目录，也是家目录（~），群里的程序也用；缺什么用 nix shell nixpkgs#包名 -c 命令 临时装。/nix/store 是宿主的整个 store，几百万个文件：要某个包里的文件，用 nix build --no-link --print-out-paths nixpkgs#包名 拿到它的路径再进去找，不在 /nix/store 下 find、ls 或用通配符。
- 在具体项目目录下工作时，先读并按需更新该项目的 AGENTS.md（没有就建，已有 CLAUDE.md 也先读），把构建测试方式、关键架构约定、踩坑结论和当前进度留在项目里，让后续进同一项目的 agent 继承经验；保留已有约定，只记核实过、以后用得上的内容，报告给 Max 留结论和路径，不把项目细节全塞回它的记忆。
- 有时间限制，快到点时会提醒你收尾，到点会被叫停。只做交给你的事。";

/// The version of the contract with the harness; see "Decoupling from the
/// harness" in docs/rust-rewrite.md.
const CONTRACT: u32 = 1;

/// What stderr keeps, for the log when the agent fails.
const ERR_KEPT: usize = 4096;
/// What stdout keeps, the end: the report of a harness with no plugin.
const OUT_KEPT: usize = 256 << 10;

/// What a job is given.
pub struct Start {
    pub number: u32,
    pub title: String,
    pub task: String,
    /// Its startup directory in the guest, already checked by `agent`.
    pub workdir: String,
    pub vms: Vms,
    /// The job's own, for its session of the MCP service.
    pub context: mcp::Context,
    pub upstream: Arc<Upstream>,
    /// How its model calls went, from the forwarder; open while its
    /// session is.
    pub calls: UnboundedReceiver<Called>,
    /// Its harness's calls; open while its session is.
    pub hooks: UnboundedReceiver<Hook>,
    /// Its session's [`super::Link::stop`].
    pub stop: CancellationToken,
    pub deadline: Instant,
    pub progress: Arc<Mutex<Progress>>,
    /// Takes the agent's question to Max.
    pub ask: Asker,
}

/// Where a job's questions go.
pub type Asker = Box<dyn Fn(String) + Send + Sync>;

/// How far a job has got, for `agent_status`.
#[derive(Clone, Debug, Default)]
pub struct Progress {
    pub calls: u32,
    pub tools: u32,
    /// The latest tool called.
    pub tool: Option<String>,
}

/// How a job ended, and where in the VM its report is saved.
#[derive(Debug)]
pub struct Finished {
    pub ending: Ending,
    pub file: Option<String>,
}

/// Runs the job until the agent reports, its harness ends, or it runs
/// out of time.
pub async fn run(start: Start, mut steers: UnboundedReceiver<String>) -> Finished {
    let conversation = start.context.place.conversation;
    let failed = |why: String| Finished {
        ending: Ending {
            how: How::Failed(why),
            text: None,
            unsent: 0,
        },
        file: None,
    };
    let vm = match start.vms.get(conversation).await {
        Ok(vm) => vm,
        Err(why) => return failed(why),
    };
    let ledger = Ledger {
        pool: start.context.services.pool.clone(),
        conversation,
        upstream: Arc::clone(&start.upstream),
        progress: start.progress,
    };
    let mut calls = start.calls;
    let mut hooks = start.hooks;
    let mut watch = Asks(start.ask);
    let grant = start.vms.sessions().open(start.context);
    let unit = Vm::unit();
    // The unit outlives the deadline only by the agent's grace, twice. A
    // login shell, as `shell`'s commands have: the agent's run in the same
    // environment.
    let limit = start.deadline.saturating_duration_since(Instant::now()) + 2 * GRACE;
    let line = unit_line(&unit, limit, &start.workdir);
    info!(%conversation, job = start.number, %unit, model = start.upstream.reference(), "a job starts");
    let (mut command, mut input) = match vm.open(unit, &line).await {
        Ok(opened) => opened,
        Err(error) => return failed(format!("agent 没起来：{error}")),
    };
    let upstream = &start.upstream;
    let api = match upstream.protocol {
        Protocol::Chat => "openai-completions",
        Protocol::Responses => "openai-responses",
    };
    let job = json!({
        "contract": CONTRACT,
        "token": grant.token(),
        "task": start.task,
        "model": upstream.model,
        "api": api,
        "window": upstream.window,
        "max_output": upstream.max_output,
        "effort": upstream.effort,
        "system": SYSTEM,
    });
    // The job is all the harness reads.
    let given = async {
        input.write_all(format!("{job}\n").as_bytes()).await?;
        input.shutdown().await
    };
    if let Err(error) = given.await {
        return failed(format!("agent 没起来：{error}"));
    }
    let mut out = Out::default();
    let (exit, mut exited) = oneshot::channel();
    let recording = async {
        while let Some(called) = calls.recv().await {
            ledger.record(called).await;
        }
    };
    tokio::pin!(recording);
    let mut recorded = false;
    let ending = {
        let reading = async {
            let status = command.wait(&mut out).await.unwrap_or_else(|error| {
                warn!(%error, "lost a job's output");
                None
            });
            let _ = exit.send(Exit {
                status,
                out: String::from_utf8_lossy(&out.out).into_owned(),
                err: String::from_utf8_lossy(&out.err).into_owned(),
            });
        };
        let driving = drive(
            &mut hooks,
            &mut steers,
            &mut exited,
            &start.stop,
            start.deadline,
            &mut watch,
        );
        tokio::pin!(reading, driving);
        let mut read = false;
        let ending = loop {
            tokio::select! {
                ending = &mut driving => break ending,
                () = &mut reading, if !read => read = true,
                () = &mut recording, if !recorded => recorded = true,
            }
        };
        // The harness exits once its agent has reported; if it doesn't,
        // the command's drop stops its unit.
        if !read {
            let _ = timeout(GRACE, reading).await;
        }
        ending
    };
    // Once the session is closed and the agent's calls are over, none is
    // left to tell: record what came.
    drop(grant);
    if !recorded {
        let _ = timeout(GRACE, recording).await;
    }
    if let How::Failed(why) = &ending.how {
        let err = String::from_utf8_lossy(&out.err);
        warn!(%conversation, job = start.number, %why, stderr = %err.trim(), "a job failed");
    }
    let file = match &ending.text {
        Some(text) => save(&vm, start.number, &start.title, text).await,
        None => None,
    };
    Finished { ending, file }
}

/// Starts the harness in `workdir`, one quoted word for the guest's
/// shell, as `shell`'s commands do.
fn unit_line(unit: &str, limit: Duration, workdir: &str) -> String {
    format!(
        "SYSTEMD_ADJUST_TERMINAL_TITLE=0 exec systemd-run --quiet --pipe --wait --collect \
         --unit={unit} --property=RuntimeDirectory={unit} --property=RuntimeMaxSec={} \
         --working-directory={} -- bash -lc 'exec max-pi'",
        limit.as_secs(),
        quote(workdir),
    )
}

/// Saves the report under /work/.max/jobs: its path in the VM.
async fn save(vm: &Vm, number: u32, title: &str, text: &str) -> Option<String> {
    let name = format!("job-{number}-{}.md", Utc::now().format("%Y%m%d-%H%M%S"));
    let report = format!("# job#{number} {title}\n\n{text}\n");
    let (work, file) = (vm.work().to_owned(), name.clone());
    let saved = tokio::task::spawn_blocking(move || {
        mcp::work::write(&work, ".max/jobs", &file, report.as_bytes(), None)
    })
    .await;
    match saved {
        Ok(Ok(())) => Some(format!("/work/.max/jobs/{name}")),
        Ok(Err(failure)) => {
            warn!(error = failure.message, "couldn't save a job's report");
            None
        }
        Err(error) => {
            warn!(%error, "couldn't save a job's report");
            None
        }
    }
}

/// The ends of the harness's stdout and stderr.
#[derive(Default)]
struct Out {
    out: Vec<u8>,
    err: Vec<u8>,
}

impl Sink for Out {
    async fn output(&mut self, stream: Stream, data: &[u8]) -> Result<()> {
        let (kept, most) = match stream {
            Stream::Out => (&mut self.out, OUT_KEPT),
            Stream::Err => (&mut self.err, ERR_KEPT),
        };
        kept.extend_from_slice(data);
        let over = kept.len().saturating_sub(most);
        kept.drain(..over);
        Ok(())
    }
}

/// Records each model call's usage, and keeps the progress.
struct Ledger {
    pool: PgPool,
    conversation: ConversationId,
    upstream: Arc<Upstream>,
    progress: Arc<Mutex<Progress>>,
}

impl Ledger {
    async fn record(&self, called: Called) {
        {
            let mut progress = self.progress.lock().unwrap_or_else(PoisonError::into_inner);
            progress.calls += 1;
            progress.tools += u32::try_from(called.tools.len()).unwrap_or(u32::MAX);
            if let Some(tool) = called.tools.last() {
                progress.tool = Some(tool.clone());
            }
        }
        // A call that failed before the provider counted anything.
        if called.usage == Usage::default() {
            return;
        }
        let call = usage::Call {
            conversation: Some(self.conversation),
            turn: None,
            purpose: usage::Purpose::Job,
            provider: &self.upstream.provider,
            model: &self.upstream.model,
            effort: self.upstream.effort.as_deref(),
            usage: called.usage,
            cost_micros: None,
            timing: Some(called.timing),
            at: Utc::now(),
        };
        crate::llm::record(&self.pool, &call).await;
    }
}

/// Takes the agent's questions on to Max.
struct Asks(Asker);

impl Watch for Asks {
    fn asks(&mut self, question: &str) {
        (self.0)(question.to_owned());
    }
}

#[cfg(test)]
mod tests;
