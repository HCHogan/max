//! What the model's tool calls do; see "Tools and codemode". Both run in the
//! group's VM: `shell` a command, `run_code` a program in the guest's
//! runner. Both call Max's tools through the MCP service as the run, and
//! can show the model pictures and videos after their result: the runner's
//! SDK, and `maxx` from a command, with the token in MAXX_TOKEN.
//!
//! A turn's command that someone waits on moves to the background; see
//! "Background commands" in docs/rust-rewrite.md.

use std::collections::{BTreeMap, VecDeque};
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use std::time::Duration;

use color_eyre::eyre::{Result, eyre};
use max_core::ids::ConversationId;
use max_core::item::{Part, ToolOutput};
use max_core::project::{PICTURE_TOKENS, VIDEO_TOKENS_PER_SECOND};
use max_core::tools::Tool;
use serde::Serialize;
use tokio::fs;
use tokio::io::AsyncWriteExt;
use tokio::sync::watch;
use tokio::time::error::Elapsed;
use tokio::time::{Instant, sleep_until, timeout, timeout_at};
use tracing::info;

use crate::conversation::Poster;
use crate::job::{self, Ending, Finished, How, Reply, Request};
use crate::mcp::{self, Grant};
use crate::tokens;
use crate::vm::ssh::{Command, Sink, Stream, quote};
use crate::vm::{Vm, Vms};
use max_core::limits::{
    BACKGROUND_TIME, BACKGROUND_TIME_MAX, MOVE_AFTER, RUN_TIME, RUN_TIME_MAX, SHOWN_BYTES,
};

/// The guest stops the unit itself a little after max would have.
const GUEST_MARGIN: Duration = Duration::from_secs(30);

/// Whether someone waits on the turn a tool call is in: they addressed
/// Max since its last model call. A command they wait on moves to the
/// background.
pub type Waiting = watch::Receiver<bool>;

/// Runs `tool` for a call from `context`'s conversation, and logs how it
/// went: what a task took in steps, and how many failed. A turn's call
/// has `waiting`.
pub async fn run(
    tool: Tool,
    vms: Option<&Vms>,
    context: mcp::Context,
    waiting: Option<Waiting>,
) -> ToolOutput {
    let conversation = context.place.conversation;
    let (name, browser) = match &tool {
        Tool::RunCode { code, .. } => ("run_code", browses(code)),
        Tool::Shell {
            background: true, ..
        } => ("background", false),
        Tool::Shell { .. } => ("shell", false),
    };
    let started = Instant::now();
    let (output, calls) = call(tool, vms, context, waiting).await;
    info!(
        %conversation,
        tool = name,
        browser,
        took_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
        error = output.error,
        tokens = output.tokens,
        calls = tally(&calls),
        "a tool call ends"
    );
    output
}

/// Whether a program drives the VM's browser, as far as its code says.
fn browses(code: &str) -> bool {
    ["max.browser(", "max.page(", "max.snapshot("]
        .iter()
        .any(|call| code.contains(call))
}

/// The Max tools a program called, for the log: `history 2, send 1/1`
/// with the failures after the slash.
fn tally(calls: &BTreeMap<String, (u32, u32)>) -> String {
    let each: Vec<String> = calls
        .iter()
        .map(|(tool, (succeeded, failed))| match failed {
            0 => format!("{tool} {succeeded}"),
            _ => format!("{tool} {succeeded}/{failed}"),
        })
        .collect();
    each.join(", ")
}

/// Runs `tool`: what the model is shown, and the Max tools it called.
async fn call(
    tool: Tool,
    vms: Option<&Vms>,
    context: mcp::Context,
    waiting: Option<Waiting>,
) -> (ToolOutput, BTreeMap<String, (u32, u32)>) {
    let text = |text: String, error| {
        let tokens = tokens::count(&text);
        ToolOutput::text(text, error, tokens)
    };
    let (name, timeout_ms) = match &tool {
        Tool::RunCode { timeout_ms, .. } => ("run_code", *timeout_ms),
        Tool::Shell { timeout_ms, .. } => ("shell", *timeout_ms),
    };
    if let Tool::Shell {
        command,
        workdir,
        background: true,
        ..
    } = tool
    {
        let limit = timeout_ms
            .map_or(BACKGROUND_TIME, Duration::from_millis)
            .clamp(Duration::from_secs(1), BACKGROUND_TIME_MAX);
        let (shown, error) = started(&context, command, workdir, limit).await;
        return (text(shown, error), BTreeMap::new());
    }
    let Some(vms) = vms else {
        let shown = text(format!("这里没有配 VM，{name} 用不了。"), true);
        return (shown, BTreeMap::new());
    };
    let vm = match vms.get(context.place.conversation).await {
        Ok(vm) => vm,
        Err(error) => return (text(error, true), BTreeMap::new()),
    };
    let limit = timeout_ms
        .map_or(RUN_TIME, Duration::from_millis)
        .clamp(Duration::from_secs(1), RUN_TIME_MAX);
    let movable = waiting
        .zip(context.caller.poster().cloned())
        .map(|(waiting, poster)| Movable { waiting, poster });
    let context = mcp::Context {
        work: Some(vm.work().to_owned()),
        ..context
    };
    let grant = vms.sessions().open(context);
    let ran = match tool {
        Tool::RunCode { code, args, .. } => run_code(&vm, &grant, &code, args, limit).await,
        Tool::Shell {
            command, workdir, ..
        } => {
            let workdir = workdir.as_deref();
            shell(&vm, &grant, &command, workdir, limit, movable).await
        }
    };
    let mut output = match ran {
        Ok((shown, error)) => text(shown, error),
        Err(error) => text(format!("{name} 没跑成：{error:#}"), true),
    };
    for part in grant.shown() {
        output.tokens += match part {
            Part::Video { seconds, .. } => seconds * VIDEO_TOKENS_PER_SECOND,
            _ => PICTURE_TOKENS,
        };
        output.parts.push(part);
    }
    (output, grant.calls())
}

/// The systemd-run line that runs `command` as the unit `unit`, at most
/// `limit`, with the run's `token` for maxx; the guest stops it itself a
/// little after max would have. systemd-run would also set the terminal's
/// title.
fn unit_line(
    unit: &str,
    limit: Duration,
    workdir: &str,
    command: &str,
    token: Option<&str>,
) -> String {
    let token = token
        .map(|token| format!(" --setenv=MAXX_TOKEN={}", quote(token)))
        .unwrap_or_default();
    format!(
        "SYSTEMD_ADJUST_TERMINAL_TITLE=0 exec systemd-run --quiet --pipe --wait --collect \
         --unit={unit} --property=RuntimeMaxSec={} --working-directory={}{token} \
         -- bash -lc {}",
        (limit + GUEST_MARGIN).as_secs(),
        quote(workdir),
        quote(command),
    )
}

/// What the runner reads on its stdin: the program, its arguments, the
/// token it calls Max's tools with, and their names.
#[derive(Serialize)]
struct RunnerInput<'a> {
    code: &'a str,
    args: Option<serde_json::Value>,
    token: &'a str,
    tools: &'static [&'static str],
}

/// The tools a program in a turn may call.
static TURN_TOOLS: LazyLock<Vec<&'static str>> = LazyLock::new(|| {
    mcp::tool::TOOLS
        .iter()
        .filter(|tool| tool.turn)
        .map(|tool| tool.name)
        .collect()
});

/// What the model is shown, and whether the program failed. The result
/// and the console are cut as `shell`'s output is.
async fn run_code(
    vm: &Vm,
    grant: &Grant,
    code: &str,
    args: Option<serde_json::Value>,
    limit: Duration,
) -> Result<(String, bool)> {
    let unit = Vm::unit();
    // The runner has the token from its input.
    let line = unit_line(&unit, limit, "/work", "exec node /run/max/runner.js", None);
    let input = RunnerInput {
        code,
        args,
        token: grant.token(),
        tools: &TURN_TOOLS,
    };
    let input = serde_json::to_vec(&input).expect("the runner's input is JSON");
    let mut split = Split {
        out: Output::new(vm.work(), format!("{unit}.txt")),
        err: Output::new(vm.work(), format!("{unit}.log")),
    };
    let mut running = vm.command(unit, &line, &input).await?;
    let waited = timeout(limit, running.wait(&mut split)).await;
    split.out.finish().await?;
    split.err.finish().await?;
    let result = split.out.shown();
    let (head, error) = match waited {
        Ok(status) => match status? {
            Some(0) if result.is_empty() => ("程序跑完了，没有返回值。".to_owned(), false),
            Some(0) => (format!("返回值：\n{result}"), false),
            Some(1) => (format!("程序出错了：\n{result}"), true),
            Some(code) => (with(format!("runner 的退出码 {code}"), &result), true),
            None => (with("runner 没有退出码，可能被杀了".into(), &result), true),
        },
        Err(_) => {
            running.stop(vm.connection()).await;
            let head = format!("{} 秒内没跑完，已经停了", limit.as_secs());
            (with(head, &result), true)
        }
    };
    let mut shown = head;
    let console = split.err.shown();
    if !console.is_empty() {
        shown.push_str("\nconsole 输出：\n");
        shown.push_str(&console);
    }
    shown.push_str(&called(&grant.calls()));
    Ok((shown, error))
}

/// The Max tools a program called, for the model to see what happened.
fn called(calls: &BTreeMap<String, (u32, u32)>) -> String {
    let each: Vec<String> = calls
        .iter()
        .map(|(tool, (succeeded, failed))| match failed {
            0 => format!("{tool} {succeeded} 次"),
            _ => format!("{tool} {} 次（失败 {failed} 次）", succeeded + failed),
        })
        .collect();
    if each.is_empty() {
        String::new()
    } else {
        format!("\n调了 Max 的工具：{}", each.join("，"))
    }
}

/// A program's result and console, apart.
struct Split {
    out: Output,
    err: Output,
}

impl Sink for Split {
    async fn output(&mut self, stream: Stream, data: &[u8]) -> Result<()> {
        match stream {
            Stream::Out => self.out.output(stream, data).await,
            Stream::Err => self.err.output(stream, data).await,
        }
    }
}

/// What the model is shown, and whether the command failed to finish. A
/// turn's command, `movable`, may move to the background instead.
async fn shell(
    vm: &Vm,
    grant: &Grant,
    command: &str,
    workdir: Option<&str>,
    limit: Duration,
    movable: Option<Movable>,
) -> Result<(String, bool)> {
    let unit = Vm::unit();
    let mut output = Output::new(vm.work(), format!("{unit}.txt"));
    let token = Some(grant.token());
    let running = start_in(vm, unit, command, workdir, token, limit).await?;
    let (begun, deadline) = (Instant::now(), Instant::now() + limit);
    let ran = match movable {
        None => wait_until(vm, running, &mut output, deadline).await?,
        Some(movable) => {
            let started = Started {
                running,
                begun,
                deadline,
            };
            match wait_or_move(vm, started, output, command, movable).await? {
                Kept::Here(ran, kept) => {
                    output = *kept;
                    ran
                }
                Kept::Moved(mut shown) => {
                    shown.push_str(&called(&grant.calls()));
                    return Ok((shown, false));
                }
            }
        }
    };
    let shown = output.shown();
    let (mut shown, error) = match ran {
        Ran::Exited(status) => (with(exited(status), &shown), false),
        Ran::OutOfTime => {
            let head = format!("{} 秒内没跑完，已经停了", limit.as_secs());
            (with(head, &shown), true)
        }
    };
    shown.push_str(&called(&grant.calls()));
    Ok((shown, error))
}

/// How a command in the guest ended.
enum Ran {
    /// With its exit status, if the guest sent one.
    Exited(Option<u32>),
    /// Stopped at its limit.
    OutOfTime,
}

/// Starts `command` as the unit `unit`, for at most `limit`, which the
/// guest enforces too; maxx calls as the run whose `token` it has.
async fn start_in(
    vm: &Vm,
    unit: String,
    command: &str,
    workdir: Option<&str>,
    token: Option<&str>,
    limit: Duration,
) -> Result<Command> {
    let workdir = guest_dir(workdir);
    // systemd-run hands the unit its own output, so 2>&1 merges the
    // command's.
    let line = unit_line(&unit, limit, &workdir, command, token) + " 2>&1";
    vm.command(unit, &line, &[]).await
}

/// A command's or an agent's directory in the guest: `dir` if absolute,
/// else under /work. A guest path, left to the guest to resolve: the VM,
/// not the directory, is the boundary.
pub fn guest_dir(dir: Option<&str>) -> String {
    match dir {
        Some(dir) if dir.starts_with('/') => dir.to_owned(),
        Some(dir) => format!("/work/{dir}"),
        None => "/work".to_owned(),
    }
}

/// Waits for `running` until `deadline`, its output into `output`; then
/// it is stopped.
async fn wait_until(
    vm: &Vm,
    mut running: Command,
    output: &mut Output,
    deadline: Instant,
) -> Result<Ran> {
    let waited = timeout_at(deadline, running.wait(output)).await;
    ended(vm, running, output, waited).await
}

/// How a command waited for ended, as `waited` says: stopped, if its time
/// ran out.
async fn ended(
    vm: &Vm,
    running: Command,
    output: &mut Output,
    waited: Result<Result<Option<u32>>, Elapsed>,
) -> Result<Ran> {
    output.finish().await?;
    match waited {
        Ok(status) => Ok(Ran::Exited(status?)),
        Err(_) => {
            running.stop(vm.connection()).await;
            Ok(Ran::OutOfTime)
        }
    }
}

/// What lets a turn's command move to the background: whether someone
/// waits on the turn, and its conversation, which takes the command.
struct Movable {
    waiting: Waiting,
    poster: Poster,
}

/// A command that has started, and when it must end.
struct Started {
    running: Command,
    begun: Instant,
    deadline: Instant,
}

/// Where a command that could move ended up.
enum Kept {
    /// Here, as it ran, with its output.
    Here(Ran, Box<Output>),
    /// In the background: what the model is shown.
    Moved(String),
}

/// Waits for the command as [`wait_until`] does; but once someone waits
/// on the turn and it has run [`MOVE_AFTER`], it goes to the conversation
/// as a background job, if the conversation takes it.
async fn wait_or_move(
    vm: &Vm,
    started: Started,
    mut output: Output,
    command: &str,
    movable: Movable,
) -> Result<Kept> {
    let Started {
        mut running,
        begun,
        deadline,
    } = started;
    tokio::select! {
        waited = timeout_at(deadline, running.wait(&mut output)) => {
            let ran = ended(vm, running, &mut output, waited).await?;
            return Ok(Kept::Here(ran, Box::new(output)));
        }
        () = due(movable.waiting, begun) => {}
    }
    let shown = output.shown();
    let file = format!("/work/{OUT}/{}", output.name);
    let (ran, left) = (
        begun.elapsed(),
        deadline.saturating_duration_since(Instant::now()),
    );
    let moved = Box::new(Moved {
        vm: vm.clone(),
        running,
        output,
        deadline,
        begun,
        command: command.to_owned(),
    });
    match movable.poster.adopt(moved).await {
        Ok(job) => Ok(Kept::Moved(moved_away(job, ran, left, &file, &shown))),
        Err((why, Some(moved))) => {
            info!(why, "a command someone waits on stays in the foreground");
            let Moved {
                running,
                mut output,
                ..
            } = *moved;
            let ran = wait_until(vm, running, &mut output, deadline).await?;
            Ok(Kept::Here(ran, Box::new(output)))
        }
        // Dropped with the conversation, it went to the stopper.
        Err((why, None)) => Err(eyre!(why)),
    }
}

/// Once someone waits on the turn and the command begun at `begun` has
/// run [`MOVE_AFTER`]; never, if the turn ends first.
async fn due(mut waiting: Waiting, begun: Instant) {
    if waiting.wait_for(|waiting| *waiting).await.is_err() {
        std::future::pending::<()>().await;
    }
    sleep_until(begun + MOVE_AFTER).await;
}

/// What the model is shown of a command that moved to the background as
/// job `job`: it had run `ran`, has `left`, and printed `shown` so far.
fn moved_away(job: u32, ran: Duration, left: Duration, file: &str, shown: &str) -> String {
    let job = job::name(job);
    let mut text = format!(
        "有人在等你回话：这条命令跑了 {} 秒还没完，转到后台接着跑了，是 {job}，还剩 {} 秒。{}",
        ran.as_secs(),
        left.as_secs(),
        follow(&job, file),
    );
    if shown.is_empty() {
        text.push_str("到现在还没有输出。");
    } else {
        text.push_str("到现在的输出：\n");
        text.push_str(shown);
    }
    text
}

/// How the model hears of a background command, `job`, writing to `file`.
fn follow(job: &str, file: &str) -> String {
    format!(
        "跑完了，退出码和输出作为 [{job} 完成] 回到你这里：别 sleep 等它，也别反复查。\
         输出一边跑一边写进 {file}，要看进度就读它的末尾；不要了用 agent_cancel 停掉。"
    )
}

/// A turn's command handed to its conversation as a background job, as
/// someone addressed Max while it ran. It keeps its unit, its output and
/// its deadline, and loses the run's token once the call returns.
pub struct Moved {
    vm: Vm,
    running: Command,
    output: Output,
    deadline: Instant,
    /// When it started, for the job's age...
    pub begun: Instant,
    /// ...and what it is, for its title.
    pub command: String,
}

impl fmt::Debug for Moved {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Moved")
            .field("command", &self.command)
            .finish_non_exhaustive()
    }
}

/// Runs a moved command on until it ends or its time is up: how it went,
/// as for [`background`].
pub async fn moved(moved: Box<Moved>) -> Finished {
    let Moved {
        vm,
        running,
        mut output,
        deadline,
        begun,
        ..
    } = *moved;
    // Whole from now on, for the model to follow along.
    if output.file.is_none()
        && let Err(error) = output.create().await
    {
        return failed(format!("{error:#}"));
    }
    let ran = wait_until(&vm, running, &mut output, deadline).await;
    finished(ran, &output, begun, deadline - begun)
}

fn exited(status: Option<u32>) -> String {
    match status {
        Some(code) => format!("退出码 {code}"),
        None => "没有退出码，命令可能被杀了".to_owned(),
    }
}

/// A `shell` call to run in the background, as its conversation's actor
/// gets it: the actor runs it with [`background`] and wakes Max when it
/// ends. See "Background commands" in docs/rust-rewrite.md.
#[derive(Debug)]
pub struct Background {
    pub command: String,
    pub workdir: Option<String>,
    pub limit: Duration,
    /// Its unit in the guest, and so its output file's name.
    pub unit: String,
}

/// Has the conversation start `command` as a background job: what the
/// model is shown, and whether it couldn't.
async fn started(
    context: &mcp::Context,
    command: String,
    workdir: Option<String>,
    limit: Duration,
) -> (String, bool) {
    let Some(poster) = context.caller.poster() else {
        return ("这里不能在后台跑命令。".to_owned(), true);
    };
    let unit = Vm::unit();
    let file = format!("/work/{OUT}/{unit}.txt");
    let request = Request::Shell(Background {
        command,
        workdir,
        limit,
        unit,
    });
    match poster.jobs(request).await {
        Ok(Reply::Job(number)) => {
            let job = job::name(number);
            let shown = format!(
                "在后台跑了，是 {job}，限时 {} 分钟。{}",
                limit.as_secs().div_ceil(60),
                follow(&job, &file),
            );
            (shown, false)
        }
        Ok(Reply::Running(_)) => ("后台命令没起来。".to_owned(), true),
        Err(why) => (why, true),
    }
}

/// Runs a background command in `conversation`'s VM until it ends or
/// runs out of time: how it went, its exit status and its output.
pub async fn background(vms: Vms, conversation: ConversationId, shell: Background) -> Finished {
    let begun = Instant::now();
    // Held until the command ends, the VM isn't idle meanwhile.
    let vm = match vms.get(conversation).await {
        Ok(vm) => vm,
        Err(why) => return failed(why),
    };
    let mut output = Output::new(vm.work(), format!("{}.txt", shell.unit));
    // Whole from the start, for the model to follow along.
    if let Err(error) = output.create().await {
        return failed(format!("{error:#}"));
    }
    // It outlives the turn, and so any run's token.
    let workdir = shell.workdir.as_deref();
    let started = start_in(&vm, shell.unit, &shell.command, workdir, None, shell.limit).await;
    let ran = match started {
        Ok(running) => {
            let deadline = Instant::now() + shell.limit;
            wait_until(&vm, running, &mut output, deadline).await
        }
        Err(error) => Err(error),
    };
    finished(ran, &output, begun, shell.limit)
}

/// A background command's end, as `ran` says: it began at `begun`, had
/// `limit`, and printed `output`.
fn finished(ran: Result<Ran>, output: &Output, begun: Instant, limit: Duration) -> Finished {
    let (how, head) = match ran {
        Err(error) => return failed(format!("{error:#}")),
        Ok(Ran::Exited(status)) => (
            How::Done,
            format!("{}，跑了 {}", exited(status), took(begun.elapsed())),
        ),
        Ok(Ran::OutOfTime) => (
            How::OutOfTime,
            format!("{} 分钟内没跑完，已经停了", limit.as_secs().div_ceil(60)),
        ),
    };
    Finished {
        ending: Ending {
            how,
            text: Some(with(head, &output.shown())),
            unsent: 0,
        },
        file: None,
    }
}

/// A background command that couldn't run, and `why`.
fn failed(why: String) -> Finished {
    Finished {
        ending: Ending {
            how: How::Failed(why),
            text: None,
            unsent: 0,
        },
        file: None,
    }
}

/// A command's run time, as the model is told it.
fn took(elapsed: Duration) -> String {
    let seconds = elapsed.as_secs();
    match seconds {
        0..60 => format!("{seconds} 秒"),
        _ => format!("{} 分 {} 秒", seconds / 60, seconds % 60),
    }
}

fn with(head: String, shown: &str) -> String {
    if shown.is_empty() {
        format!("{head}，没有输出。")
    } else {
        format!("{head}\n{shown}")
    }
}

/// Where a long output goes, under /work.
const OUT: &str = ".max/out";

/// A command's output: all of it while short; past `SHOWN_BYTES`, its head and
/// tail, and the whole in a file, `name` in the guest's /work/.max/out,
/// or from the start once [`Output::create`] makes it.
struct Output {
    name: String,
    /// The host's side of /work.
    work: PathBuf,
    head: Vec<u8>,
    tail: VecDeque<u8>,
    total: usize,
    file: Option<fs::File>,
}

impl Output {
    fn new(work: &Path, name: String) -> Self {
        Self {
            work: work.to_owned(),
            name,
            head: Vec::new(),
            tail: VecDeque::new(),
            total: 0,
            file: None,
        }
    }

    fn shown(&self) -> String {
        let head = String::from_utf8_lossy(&self.head);
        if self.total <= SHOWN_BYTES {
            return head.into_owned();
        }
        let tail: Vec<u8> = self.tail.iter().copied().collect();
        let left_out = self.total - self.head.len() - tail.len();
        format!(
            "{}\n…（中间省略 {left_out} 字节，全部输出在 /work/.max/out/{}）…\n{}",
            head.trim_end_matches('\u{fffd}'),
            self.name,
            String::from_utf8_lossy(&tail).trim_start_matches('\u{fffd}'),
        )
    }
}

impl Sink for Output {
    async fn output(&mut self, _: Stream, data: &[u8]) -> Result<()> {
        let before = self.total;
        self.total += data.len();
        if self.file.is_none() && self.total > SHOWN_BYTES {
            self.create().await?;
        }
        if let Some(file) = &mut self.file {
            // Read while the command runs, for a background one.
            file.write_all(data).await?;
            file.flush().await?;
        }
        if self.total <= SHOWN_BYTES {
            self.head.extend_from_slice(data);
        } else if before <= SHOWN_BYTES {
            // Long with this piece: only its ends are kept.
            let mut all = std::mem::take(&mut self.head);
            all.extend_from_slice(data);
            self.head = all[..SHOWN_BYTES / 2].to_vec();
            self.tail = all[all.len() - SHOWN_BYTES / 2..].iter().copied().collect();
        } else {
            self.tail.extend(data);
            let over = self.tail.len().saturating_sub(SHOWN_BYTES / 2);
            self.tail.drain(..over);
        }
        Ok(())
    }
}

impl Output {
    /// Makes the file now, with the output so far: all of it, since that
    /// is short.
    async fn create(&mut self) -> Result<()> {
        let (work, name) = (self.work.clone(), self.name.clone());
        let file = tokio::task::spawn_blocking(move || mcp::work::create(&work, OUT, &name))
            .await?
            .map_err(|failure| eyre!(failure.message))?;
        let mut file = fs::File::from_std(file);
        file.write_all(&self.head).await?;
        file.flush().await?;
        self.file = Some(file);
        Ok(())
    }

    /// Writes out what the file has yet to get.
    async fn finish(&mut self) -> Result<()> {
        if let Some(file) = &mut self.file {
            file.flush().await?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::pin::pin;

    use super::*;

    /// A command moves once someone waits and it has run `MOVE_AFTER`:
    /// never while nobody waits, nor once the turn has ended.
    #[tokio::test(start_paused = true)]
    async fn a_command_moves_once_someone_waits_and_it_has_run_a_while() {
        let begun = Instant::now();
        let (someone, waiting) = watch::channel(false);
        let mut moves = pin!(due(waiting, begun));
        assert!(timeout(MOVE_AFTER * 2, &mut moves).await.is_err());
        someone.send_replace(true);
        assert!(timeout(Duration::ZERO, &mut moves).await.is_ok(), "at once");

        let begun = Instant::now();
        let (someone, waiting) = watch::channel(false);
        let mut moves = pin!(due(waiting, begun));
        let early = Duration::from_secs(3);
        assert!(timeout(early, &mut moves).await.is_err());
        someone.send_replace(true);
        moves.await;
        assert_eq!(begun.elapsed(), MOVE_AFTER, "not before its time");

        let (someone, waiting) = watch::channel(false);
        drop(someone);
        let ended = due(waiting, Instant::now());
        assert!(timeout(MOVE_AFTER * 2, ended).await.is_err());
    }

    #[test]
    fn a_moved_command_says_where_it_went() {
        let (ran, left) = (Duration::from_secs(15), Duration::from_secs(105));
        let file = "/work/.max/out/max-1.txt";
        let text = moved_away(4, ran, left, file, "编译中\n");
        assert!(
            text.starts_with(
                "有人在等你回话：这条命令跑了 15 秒还没完，转到后台接着跑了，是 job#4，还剩 105 秒。\
                 跑完了，退出码和输出作为 [job#4 完成] 回到你这里"
            ),
            "{text}"
        );
        assert!(text.contains("写进 /work/.max/out/max-1.txt，"), "{text}");
        assert!(text.ends_with("停掉。到现在的输出：\n编译中\n"), "{text}");
        let quiet = moved_away(4, ran, left, file, "");
        assert!(quiet.ends_with("停掉。到现在还没有输出。"), "{quiet}");
    }

    #[tokio::test]
    async fn short_output_is_shown_whole() {
        let work = std::env::temp_dir().join(format!("max-output-{}", std::process::id()));
        std::fs::create_dir_all(&work).unwrap();
        let mut output = Output::new(&work, "short.txt".into());
        output.output(Stream::Out, b"hello\n").await.unwrap();
        output.output(Stream::Out, b"world").await.unwrap();
        assert_eq!(output.shown(), "hello\nworld");
        assert!(!work.join(".max/out/short.txt").exists());
        let _ = std::fs::remove_dir_all(work);
    }

    #[tokio::test]
    async fn long_output_keeps_its_ends_and_goes_whole_to_a_file() {
        let work = std::env::temp_dir().join(format!("max-output-long-{}", std::process::id()));
        std::fs::create_dir_all(&work).unwrap();
        let path = work.join(".max/out/max-2.txt");
        let mut output = Output::new(&work, "max-2.txt".into());
        let mut all = Vec::new();
        for n in 0..5000 {
            let line = format!("{n:05}\n");
            all.extend_from_slice(line.as_bytes());
            output.output(Stream::Out, line.as_bytes()).await.unwrap();
        }
        output.finish().await.unwrap();
        let shown = output.shown();
        assert!(shown.starts_with("00000\n"), "{shown}");
        assert!(shown.ends_with("04999\n"), "{shown}");
        assert!(shown.contains("/work/.max/out/max-2.txt"), "{shown}");
        assert_eq!(output.head.len() + output.tail.len(), SHOWN_BYTES);
        assert_eq!(std::fs::read(&path).unwrap(), all);
        let _ = std::fs::remove_dir_all(work);
    }

    /// The guest's link at /work/.max: a long output isn't written through
    /// it.
    #[tokio::test]
    async fn long_output_follows_no_link() {
        let scratch = std::env::temp_dir().join(format!("max-output-link-{}", std::process::id()));
        let (work, host) = (scratch.join("work"), scratch.join("host"));
        std::fs::create_dir_all(&work).unwrap();
        std::fs::create_dir_all(host.join("out")).unwrap();
        std::os::unix::fs::symlink(&host, work.join(".max")).unwrap();
        let mut output = Output::new(&work, "max-3.txt".into());
        let long = vec![b'x'; SHOWN_BYTES + 1];
        assert!(output.output(Stream::Out, &long).await.is_err());
        assert!(!host.join("out/max-3.txt").exists());
        let _ = std::fs::remove_dir_all(scratch);
    }

    /// A background command's: the model reads it while the command runs.
    #[tokio::test]
    async fn a_created_file_has_the_output_from_the_start() {
        let work = std::env::temp_dir().join(format!("max-output-kept-{}", std::process::id()));
        std::fs::create_dir_all(&work).unwrap();
        let path = work.join(".max/out/max-4.txt");
        let mut output = Output::new(&work, "max-4.txt".into());
        output.create().await.unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"");
        output.output(Stream::Out, b"building\n").await.unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"building\n");
        output.output(Stream::Out, b"done").await.unwrap();
        assert_eq!(output.shown(), "building\ndone");
        let long = vec![b'x'; SHOWN_BYTES];
        output.output(Stream::Out, &long).await.unwrap();
        assert_eq!(std::fs::read(&path).unwrap().len(), SHOWN_BYTES + 13);
        let shown = output.shown();
        assert!(shown.starts_with("building\ndonex"), "{shown}");
        assert!(shown.contains("/work/.max/out/max-4.txt"), "{shown}");
        let _ = std::fs::remove_dir_all(work);
    }

    #[test]
    fn a_run_time_is_in_seconds_or_minutes() {
        assert_eq!(took(Duration::from_millis(5400)), "5 秒");
        assert_eq!(took(Duration::from_secs(192)), "3 分 12 秒");
    }

    #[test]
    fn calls_are_summed_up_per_tool() {
        assert_eq!(called(&BTreeMap::new()), "");
        let calls = BTreeMap::from([
            ("history".to_owned(), (3, 1)),
            ("memory_list".to_owned(), (1, 0)),
        ]);
        assert_eq!(
            called(&calls),
            "\n调了 Max 的工具：history 4 次（失败 1 次），memory_list 1 次"
        );
        assert_eq!(tally(&calls), "history 3/1, memory_list 1");
    }

    #[test]
    fn a_program_browses_if_it_asks_for_the_browser() {
        assert!(browses(
            "const page = await max.page();\nawait page.click('a');"
        ));
        assert!(browses("return await max.snapshot(await max.page())"));
        assert!(!browses("return fs.readdirSync('/work')"));
    }
}
