//! A job in the group's VM: max-pi in a unit of its own, its session of
//! the MCP service, its model calls on the record, and its report saved
//! in /work.

use std::sync::{Arc, Mutex, PoisonError};

use chrono::Utc;
use color_eyre::eyre::Result;
use max_core::ids::ConversationId;
use max_core::item::{Protocol, Usage};
use max_db::{PgPool, usage};
use serde_json::json;
use tokio::io::AsyncWriteExt;
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel};
use tokio::time::{Instant, timeout};
use tracing::{info, warn};

use super::pi::Lines;
use super::{Ending, GONE, GRACE, How, Watch, drive};
use crate::llm::Upstream;
use crate::mcp;
use crate::vm::ssh::{Sink, Stream};
use crate::vm::{Vm, Vms};

/// Appended to pi's system prompt.
const SYSTEM: &str = "你是 Max 的后台 agent。Max 是一个群聊里的 AI 成员，它把一件要花时间的事交给你，自己接着在群里聊天。
- 你看不到群里的对话，只有 Max 写给你的任务。要聊天记录时用 mcp__max__history 查，能按内容搜，也能按人、按时间读原文；查网上的用 mcp__max__web_search，读网页用 webread <url>（只留正文，转成 Markdown）。
- 你不能在群里说话。你最后一条消息就是交给 Max 的报告：先说结论，再给要点和出处，写给 Max 看，不用客套，尽量在 2000 字以内。做出来的文件放在 /work 下，报告里写路径。
- 做的过程中 Max 可能补充要求，会出现在对话里。
- 环境：NixOS，root，能上公网，/work 是本群的持久目录，群里的程序也用；缺什么用 nix shell nixpkgs#包名 -c 命令 临时装。
- 有时间限制，快到点时会提醒你收尾，到点会被叫停。只做交给你的事。";

/// What stderr keeps, for the log when pi fails.
const ERR_KEPT: usize = 4096;

/// What a job is given.
pub struct Start {
    pub number: u32,
    pub title: String,
    pub task: String,
    pub vms: Vms,
    /// The job's own, for its session of the MCP service.
    pub context: mcp::Context,
    pub upstream: Arc<Upstream>,
    pub deadline: Instant,
    pub progress: Arc<Mutex<Progress>>,
}

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

/// Runs the job until pi settles, fails, or runs out of time.
pub async fn run(start: Start, mut steers: UnboundedReceiver<String>) -> Finished {
    let conversation = start.context.place.conversation;
    let failed = |why: String| Finished {
        ending: Ending {
            how: How::Failed(why),
            text: None,
        },
        file: None,
    };
    let vm = match start.vms.get(conversation).await {
        Ok(vm) => vm,
        Err(why) => return failed(why),
    };
    let mut watch = Recorder {
        pool: start.context.services.pool.clone(),
        conversation,
        upstream: Arc::clone(&start.upstream),
        progress: start.progress,
    };
    let grant = start.vms.sessions().open(start.context);
    let unit = Vm::unit();
    // The unit outlives the deadline only by pi's grace, twice. A login
    // shell, as `shell`'s commands have: pi's run in the same environment.
    let limit = start.deadline.saturating_duration_since(Instant::now()) + 2 * GRACE;
    let line = format!(
        "SYSTEMD_ADJUST_TERMINAL_TITLE=0 exec systemd-run --quiet --pipe --wait --collect \
         --unit={unit} --property=RuntimeDirectory={unit} --property=RuntimeMaxSec={} \
         --working-directory=/work -- bash -lc 'exec max-pi'",
        limit.as_secs()
    );
    info!(%conversation, job = start.number, %unit, model = start.upstream.reference(), "a job starts");
    let (mut command, mut input) = match vm.open(unit, &line).await {
        Ok(opened) => opened,
        Err(error) => return failed(format!("pi 没起来：{error}")),
    };
    let upstream = &start.upstream;
    let api = match upstream.protocol {
        Protocol::Chat => "openai-completions",
        Protocol::Responses => "openai-responses",
    };
    let job = json!({
        "token": grant.token(),
        "model": upstream.model,
        "api": api,
        "window": upstream.window,
        "max_output": upstream.max_output,
        "effort": upstream.effort,
        "system": SYSTEM,
    });
    if input
        .write_all(format!("{job}\n").as_bytes())
        .await
        .is_err()
    {
        return failed(GONE.to_owned());
    }
    let (records_tx, mut records) = unbounded_channel();
    let mut out = Out {
        lines: Lines::default(),
        records: Some(records_tx),
        err: Vec::new(),
    };
    let ending = {
        let reading = async {
            if let Err(error) = command.wait(&mut out).await {
                warn!(%error, "lost a job's output");
            }
            // pi's records end with it.
            out.records = None;
        };
        let driving = drive(
            input,
            &mut records,
            &mut steers,
            &start.task,
            start.deadline,
            &mut watch,
        );
        tokio::pin!(reading, driving);
        let mut read = false;
        let ending = loop {
            tokio::select! {
                ending = &mut driving => break ending,
                () = &mut reading, if !read => read = true,
            }
        };
        // pi exits once its stdin is closed; if it doesn't, the command's
        // drop stops its unit.
        if !read {
            let _ = timeout(GRACE, reading).await;
        }
        ending
    };
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

/// pi's stdout, as records' lines; the end of its stderr.
struct Out {
    lines: Lines,
    records: Option<UnboundedSender<Vec<u8>>>,
    err: Vec<u8>,
}

impl Sink for Out {
    async fn output(&mut self, stream: Stream, data: &[u8]) -> Result<()> {
        let Out {
            lines,
            records,
            err,
        } = self;
        match stream {
            Stream::Out => {
                if let Some(records) = records {
                    lines.push(data, |line| {
                        let _ = records.send(line.to_vec());
                    });
                }
            }
            Stream::Err => {
                err.extend_from_slice(data);
                let over = err.len().saturating_sub(ERR_KEPT);
                err.drain(..over);
            }
        }
        Ok(())
    }
}

/// Records each model call's usage, and keeps the progress.
struct Recorder {
    pool: PgPool,
    conversation: ConversationId,
    upstream: Arc<Upstream>,
    progress: Arc<Mutex<Progress>>,
}

impl Recorder {
    fn progress(&self) -> std::sync::MutexGuard<'_, Progress> {
        self.progress.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl Watch for Recorder {
    async fn called(&mut self, usage: Usage) {
        self.progress().calls += 1;
        // A call that failed before the provider counted anything.
        if usage == Usage::default() {
            return;
        }
        let call = usage::Call {
            conversation: Some(self.conversation),
            turn: None,
            purpose: usage::Purpose::Job,
            provider: &self.upstream.provider,
            model: &self.upstream.model,
            effort: self.upstream.effort.as_deref(),
            usage,
            cost_micros: None,
            at: Utc::now(),
        };
        let recorded = async {
            let mut conn = self.pool.acquire().await?;
            usage::record(&mut conn, &call).await
        };
        if let Err(error) = recorded.await {
            warn!(%error, "couldn't record a job's model call");
        }
    }

    fn tool(&mut self, name: &str) {
        let mut progress = self.progress();
        progress.tools += 1;
        progress.tool = Some(name.to_owned());
    }
}
