//! What the model's tool calls do; see "Tools and codemode". Both run in the
//! group's VM, each as a unit of the guest's own that `maxx units` starts and
//! sees end (nix/max-jobs.sh): `shell` a command, `run_code` a program in
//! the guest's runner. A call waits for its unit to end, or for the unit's
//! limit to end it; `shell` with `background` starts one and doesn't wait,
//! and the guest tells Max when it ends. A unit is one or the other from
//! its start. See "Lifetimes move to systemd" in docs/rust-rewrite.md.
//!
//! Both call Max's tools through the MCP service, as anything in the VM
//! does: the runner's SDK, and `maxx` from a command. And both can show
//! the model pictures and videos after their result, which the call's
//! line lists and the host reads from /work; see [`show`].

use std::sync::{Arc, LazyLock};
use std::time::Duration;

use color_eyre::eyre::{Result, WrapErr, bail};
use max_core::ids::ConversationId;
use max_core::item::{Part, ToolOutput};
use max_core::project::{PICTURE_TOKENS, VIDEO_TOKENS_PER_SECOND};
use max_core::tools::Tool;
use serde::{Deserialize, Serialize};
use tokio::time::{Instant, sleep};
use tracing::info;

use crate::mcp;
use crate::media::store::Store;
use crate::tokens;
use crate::vm::ssh::{Sink, Stream, Waited, quote};
use crate::vm::{Vm, Vms};
use max_core::limits::{BACKGROUND_TIME, BACKGROUND_TIME_MAX, RUN_TIME, RUN_TIME_MAX, SHOWN_BYTES};

mod run_code;
mod shell;
pub(crate) mod show;

use self::run_code::run_code;
use self::shell::shell;
use self::show::Left;

/// What a tool call is for: the conversation whose VM it runs in, and
/// what showing its model a picture or a video takes.
pub struct Context {
    pub conversation: ConversationId,
    /// Keeps what is shown; None where there is no content store.
    pub store: Option<Arc<Store>>,
    /// Whether the turn's model watches videos.
    pub video: bool,
}

/// What the model is told of a call that ran: whether it failed, and what
/// it left to show.
struct Told {
    text: String,
    error: bool,
    left: Vec<Left>,
}

/// How long past a call's limit max waits for the guest to say how the
/// unit ended: the guest ends it at the limit and kills what is left of
/// it 15 seconds on (nix/max-jobs.sh), and one that says nothing by then
/// has stopped answering.
const GUEST_MARGIN: Duration = Duration::from_secs(30);
/// How much of what `maxx` said is in an error, when it wasn't a call's
/// line.
const SAID_SHOWN: usize = 300;
/// The most of what `maxx units run` writes that is kept: a call's line has
/// what is shown of two outputs, each character of which may be written
/// as six.
const LINE_KEPT: usize = 16 * SHOWN_BYTES;

/// Runs `tool` in the VM of `context`'s conversation, and logs how it
/// went: what a task took in steps, and how many failed.
pub async fn run(tool: Tool, vms: Option<&Vms>, context: &Context) -> ToolOutput {
    let conversation = context.conversation;
    let (name, browser) = match &tool {
        Tool::RunCode { code, .. } => ("run_code", browses(code)),
        Tool::Shell {
            background: true, ..
        } => ("background", false),
        Tool::Shell { .. } => ("shell", false),
    };
    let started = Instant::now();
    let output = call(tool, vms, context).await;
    info!(
        %conversation,
        tool = name,
        browser,
        took_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
        error = output.error,
        tokens = output.tokens,
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

/// Runs `tool`: what the model is shown.
async fn call(tool: Tool, vms: Option<&Vms>, context: &Context) -> ToolOutput {
    let text = |text: String, error| {
        let tokens = tokens::count(&text);
        ToolOutput::text(text, error, tokens)
    };
    let (name, timeout_ms) = match &tool {
        Tool::RunCode { timeout_ms, .. } => ("run_code", *timeout_ms),
        Tool::Shell { timeout_ms, .. } => ("shell", *timeout_ms),
    };
    let Some(vms) = vms else {
        return text(format!("there are no VMs here, so {name} can't run"), true);
    };
    let vm = match vms.get(context.conversation).await {
        Ok(vm) => vm,
        Err(error) => return text(error, true),
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
        let started = shell::start(&vm, &command, workdir.as_deref(), limit).await;
        return match started {
            Ok(shown) => text(shown, false),
            Err(error) => text(format!("the command didn't start: {error:#}"), true),
        };
    }
    let limit = timeout_ms
        .map_or(RUN_TIME, Duration::from_millis)
        .clamp(Duration::from_secs(1), RUN_TIME_MAX);
    let ran = match tool {
        Tool::RunCode { code, args, .. } => run_code(&vm, &code, args, limit).await,
        Tool::Shell {
            command, workdir, ..
        } => shell(&vm, &command, workdir.as_deref(), limit).await,
    };
    let mut told = match ran {
        Ok(told) => told,
        Err(error) => return text(format!("{name} failed: {error:#}"), true),
    };
    // What it left for the model to see, read now that it is over; and
    // what of that can't be shown, said here, the program being gone.
    let shown = show::shown(context, vm.work(), &told.left).await;
    for refused in &shown.refused {
        told.text.push('\n');
        told.text.push_str(refused);
    }
    let mut output = text(told.text, told.error);
    for part in shown.parts {
        output.tokens += match part {
            Part::Video { seconds, .. } => seconds * VIDEO_TOKENS_PER_SECOND,
            _ => PICTURE_TOKENS,
        };
        output.parts.push(part);
    }
    output
}

/// A call's unit, as `maxx units run` is asked for it.
struct Unit<'a> {
    /// What it is, for the guest's list.
    title: &'a str,
    /// Its directory in the guest.
    workdir: &'a str,
    /// The guest ends it then.
    limit: Duration,
    /// Its stderr apart from its stdout.
    split: bool,
}

/// How a call's unit ended, as `maxx units run` says in its one line: what
/// systemd says of the unit, and what the unit wrote.
#[derive(Debug, Deserialize)]
struct Ended {
    /// systemd's result for the unit: `success`, `exit-code`, `timeout`,
    /// `signal`, `oom-kill`...
    result: String,
    /// How its main process ended, `exited` or `killed`...
    code: String,
    /// ...and with what: an exit status, or a signal's name.
    status: String,
    out: Option<Piece>,
    err: Option<Piece>,
    /// What it left for the model to see, in order.
    #[serde(default)]
    shown: Vec<Left>,
    /// Why there was no unit, if there wasn't.
    failed: Option<String>,
}

/// An output: all of it in `head` while it fits in what is shown; past
/// that its head and its tail, the whole in `file`, in the guest.
#[derive(Debug, Deserialize)]
struct Piece {
    bytes: usize,
    head: String,
    tail: String,
    file: Option<String>,
}

/// How a call ended, for what the model is told.
#[derive(Debug, PartialEq, Eq)]
enum Ran {
    Exited(u32),
    /// The guest ended it at its limit.
    OutOfTime,
    /// Something else did, as this says.
    Killed(String),
}

impl Ended {
    fn ran(&self) -> Ran {
        match (self.result.as_str(), self.code.as_str()) {
            ("timeout", _) => Ran::OutOfTime,
            (_, "exited") => match self.status.parse() {
                Ok(status) => Ran::Exited(status),
                Err(_) => Ran::Killed(format!("{} ({})", self.result, self.status)),
            },
            _ => Ran::Killed(format!("{} ({})", self.result, self.status)),
        }
    }
}

impl Piece {
    fn shown(&self) -> String {
        let Some(file) = &self.file else {
            return self.head.clone();
        };
        // The guest cut it by bytes, perhaps inside a character.
        format!(
            "{}\n… ({} bytes left out here; the whole output is in {file}) …\n{}",
            self.head.trim_end_matches('\u{fffd}'),
            self.bytes.saturating_sub(SHOWN_BYTES),
            self.tail.trim_start_matches('\u{fffd}'),
        )
    }
}

/// What an output shows, if there is one.
fn shown(piece: Option<&Piece>) -> String {
    piece.map(Piece::shown).unwrap_or_default()
}

/// What `maxx units run` is asked for: a call's unit (nix/max-jobs.sh).
#[derive(Serialize)]
struct Asked<'a> {
    unit: &'a str,
    /// In seconds.
    limit: u64,
    title: &'a str,
    workdir: &'a str,
    /// How many bytes of an output the line carries.
    shown: usize,
    split: bool,
    /// How many bytes of the channel's input are the command's.
    #[serde(skip_serializing_if = "Option::is_none")]
    input: Option<usize>,
    command: &'a str,
}

/// `maxx` with `words` and `arguments` as JSON: the line that asks the
/// guest for one of its own tools, as anything in the VM asks.
pub(crate) fn maxx(words: &str, arguments: &impl Serialize) -> String {
    let arguments = serde_json::to_string(arguments).expect("a tool's arguments are JSON");
    format!("maxx {words} {}", quote(&arguments))
}

/// Runs `command` in the guest as a call's unit, with `input` if it reads
/// any, and waits for it to end: how it did. Dropped while it waits, as
/// when the turn is killed, the call's channel closes and the guest
/// stops the unit; it does the same when max's connection goes.
async fn wait(vm: &Vm, unit: Unit<'_>, command: &str, input: Option<&[u8]>) -> Result<Ended> {
    let name = Vm::unit();
    let asked = Asked {
        unit: &name,
        limit: unit.limit.as_secs(),
        title: unit.title,
        workdir: unit.workdir,
        shown: SHOWN_BYTES,
        split: unit.split,
        input: input.map(<[u8]>::len),
        command,
    };
    let line = format!("exec {}", maxx("units run", &asked));
    let running = vm.command(&line, input.unwrap_or_default());
    let mut running = running.await.wrap_err("it didn't start")?;
    let mut said = Said::default();
    let waited = running.wait_or(&mut said, sleep(unit.limit + GUEST_MARGIN));
    match waited.await? {
        Waited::Exited(Some(0)) => {
            let line = last_line(&said.out);
            serde_json::from_slice(line)
                .wrap_err_with(|| format!("maxx units run said {:?}", start_of(line)))
        }
        Waited::Exited(Some(status)) => {
            bail!(
                "maxx units run ended with status {status}: {}",
                end_of(&said.err)
            )
        }
        // The connection went, as when the guest's sshd restarts under
        // it: the guest stops a call whose caller is gone.
        Waited::Exited(None) => bail!(
            "the connection to the VM closed before the command ended, which stopped it: it may \
             have done part of its work"
        ),
        Waited::Interrupted(()) => bail!(
            "the VM didn't say how it ended, {} seconds past its limit: it may still run",
            GUEST_MARGIN.as_secs()
        ),
    }
}

/// The line `maxx` printed: the last of what came, since the shell sshd
/// runs it in writes first if the group's /work/.bashrc does.
pub(crate) fn last_line(out: &[u8]) -> &[u8] {
    let out = out.trim_ascii_end();
    out.rsplit(|&byte| byte == b'\n').next().unwrap_or(out)
}

/// The start of what `maxx` said, for an error: a line that isn't a
/// call's may be as long as what is kept of it.
fn start_of(said: &[u8]) -> String {
    let said = String::from_utf8_lossy(said);
    match said.char_indices().nth(SAID_SHOWN) {
        Some((cut, _)) => format!("{}…", &said[..cut]),
        None => said.into_owned(),
    }
}

/// The end of what `maxx` wrote to stderr, where its own words are:
/// the group's .bashrc may have written before them.
fn end_of(said: &[u8]) -> String {
    let said = String::from_utf8_lossy(said);
    let said = said.trim();
    let count = said.chars().count();
    match said.char_indices().nth(count.saturating_sub(SAID_SHOWN)) {
        Some((cut, _)) if cut > 0 => format!("…{}", &said[cut..]),
        _ => said.to_owned(),
    }
}

/// What `maxx` wrote: its line, and why it failed if it did.
#[derive(Default)]
struct Said {
    out: Vec<u8>,
    err: Vec<u8>,
}

impl Sink for Said {
    async fn output(&mut self, stream: Stream, data: &[u8]) -> Result<()> {
        let kept = match stream {
            Stream::Out => &mut self.out,
            Stream::Err => &mut self.err,
        };
        let room = LINE_KEPT.saturating_sub(kept.len());
        kept.extend_from_slice(&data[..data.len().min(room)]);
        Ok(())
    }
}

/// A command's directory in the guest: `dir` if absolute,
/// else under /work. A guest path, left to the guest to resolve: the VM,
/// not the directory, is the boundary.
pub fn guest_dir(dir: Option<&str>) -> String {
    match dir {
        Some(dir) if dir.starts_with('/') => dir.to_owned(),
        Some(dir) => format!("/work/{dir}"),
        None => "/work".to_owned(),
    }
}

/// What a task or a command is, in a line: the first of it, cut short.
pub fn headline(task: &str) -> String {
    let line = task.trim().lines().next().unwrap_or_default();
    let mut title: String = line.chars().take(30).collect();
    if line.chars().count() > 30 {
        title.push('…');
    }
    title
}

fn with(head: String, shown: &str) -> String {
    if shown.is_empty() {
        format!("{head}; no output")
    } else {
        format!("{head}\n{shown}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_title_is_the_first_line_cut_short() {
        assert_eq!(headline("  查一下明天的天气\n背景：……"), "查一下明天的天气");
        let long = "字".repeat(40);
        assert_eq!(headline(&long), format!("{}…", "字".repeat(30)));
    }

    #[test]
    fn a_call_ended_as_systemd_says() {
        let ended = |result: &str, code: &str, status: &str| Ended {
            result: result.to_owned(),
            code: code.to_owned(),
            status: status.to_owned(),
            out: None,
            err: None,
            shown: Vec::new(),
            failed: None,
        };
        assert_eq!(ended("success", "exited", "0").ran(), Ran::Exited(0));
        assert_eq!(ended("exit-code", "exited", "3").ran(), Ran::Exited(3));
        assert_eq!(ended("timeout", "killed", "TERM").ran(), Ran::OutOfTime);
        assert_eq!(
            ended("oom-kill", "killed", "KILL").ran(),
            Ran::Killed("oom-kill (KILL)".to_owned())
        );
    }

    #[test]
    fn a_calls_line_is_the_last_of_what_came() {
        let line = br#"{"result":"success"}"#;
        assert_eq!(last_line(b"{\"result\":\"success\"}\n"), line);
        // What the group's .bashrc wrote first isn't the line.
        assert_eq!(
            last_line(b"Agent pid 4242\nnvm: now using node 24\n{\"result\":\"success\"}\n\n"),
            line
        );
        assert_eq!(last_line(b""), b"");
    }

    #[test]
    fn what_wasnt_a_calls_line_is_shown_in_part() {
        assert_eq!(start_of(b"oops"), "oops");
        assert_eq!(end_of(b"  maxx units: no\n"), "maxx units: no");
        let long = "长".repeat(SAID_SHOWN + 5);
        let start = start_of(long.as_bytes());
        assert_eq!(start, format!("{}…", "长".repeat(SAID_SHOWN)));
        let noise = format!(
            "{}maxx units: limit is a whole number",
            "x".repeat(SAID_SHOWN)
        );
        let end = end_of(noise.as_bytes());
        assert!(end.starts_with('…') && end.ends_with("limit is a whole number"));
        assert_eq!(end.chars().count(), SAID_SHOWN + 1);
    }

    #[test]
    fn a_calls_line_is_read_and_a_long_output_shows_its_ends() {
        let line = r#"{"result":"exit-code","code":"exited","status":"2","seconds":1,
            "out":{"bytes":3,"head":"hi\n","tail":"","file":null},"err":null,
            "shown":[{"kind":"image","path":"/work/a.png"}],"failed":null}"#;
        let ended: Ended = serde_json::from_str(line).unwrap();
        assert_eq!(ended.ran(), Ran::Exited(2));
        assert_eq!(ended.shown.len(), 1);
        assert_eq!(shown(ended.out.as_ref()), "hi\n");
        assert_eq!(shown(ended.err.as_ref()), "");
        let long = Piece {
            bytes: SHOWN_BYTES + 100,
            head: "开头\u{fffd}".to_owned(),
            tail: "\u{fffd}结尾".to_owned(),
            file: Some("/work/.max/out/max-job-1-2.txt".to_owned()),
        };
        assert_eq!(
            long.shown(),
            "开头\n… (100 bytes left out here; the whole output is in /work/.max/out/max-job-1-2.txt) …\n结尾"
        );
        let refused: Ended =
            serde_json::from_str(r#"{"result":"","code":"","status":"","seconds":0,"out":null,"err":null,"failed":"there is no directory /nowhere"}"#).unwrap();
        assert_eq!(
            refused.failed.as_deref(),
            Some("there is no directory /nowhere")
        );
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
