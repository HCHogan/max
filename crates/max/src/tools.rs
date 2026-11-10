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
use tokio::time::{Instant, sleep, sleep_until};
use tracing::info;

use crate::conversation::Poster;
use crate::job::{self, Ending, Finished, How};
use crate::mcp::{self, Grant};
use crate::tokens;
use crate::vm::ssh::{Command, Sink, Stopped, Stream, Waited, quote};
use crate::vm::{Vm, Vms};
use max_core::limits::{
    BACKGROUND_TIME, BACKGROUND_TIME_MAX, MOVE_AFTER, RUN_TIME, RUN_TIME_MAX, SHOWN_BYTES,
};

mod background;
mod output;
mod run_code;
mod shell;

use self::background::started;
pub use self::background::{Background, background};
use self::output::Output;
use self::run_code::run_code;
use self::shell::{Movable, shell};
pub use self::shell::{Moved, moved};

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
        let shown = text(format!("there are no VMs here, so {name} can't run"), true);
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
        Err(error) => text(format!("{name} didn't run: {error:#}"), true),
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

/// The Max tools a program called, for the model to see what happened.
fn called(calls: &BTreeMap<String, (u32, u32)>) -> String {
    let each: Vec<String> = calls
        .iter()
        .map(|(tool, (succeeded, failed))| match failed {
            0 => format!("{tool} {succeeded}"),
            _ => format!("{tool} {} ({failed} failed)", succeeded + failed),
        })
        .collect();
    if each.is_empty() {
        String::new()
    } else {
        format!("\nMax tools called: {}", each.join(", "))
    }
}

/// How a command in the guest ended.
enum Ran {
    /// With its exit status, if the guest sent one.
    Exited(Option<u32>),
    /// At its limit, when it was stopped, as this says.
    OutOfTime(Stopped),
}

/// What the model is told of a command stopped at its limit: that it
/// stopped only if the guest said so.
fn stopping(stopped: &Stopped) -> String {
    match stopped {
        Stopped::Confirmed => "it was stopped".to_owned(),
        Stopped::Unconfirmed(why) => {
            format!("it was told to stop, but the VM didn't confirm ({why}): it may still run")
        }
    }
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
    let waited = running.wait_or(output, sleep_until(deadline)).await;
    ended(vm, running, output, waited).await
}

/// How a command waited for ended, as `waited` says: stopped, if its time
/// ran out, the only thing besides that a wait ends on here.
async fn ended<T>(
    vm: &Vm,
    running: Command,
    output: &mut Output,
    waited: Result<Waited<T>>,
) -> Result<Ran> {
    output.finish().await?;
    match waited? {
        Waited::Exited(status) => Ok(Ran::Exited(status)),
        Waited::Interrupted(_) => Ok(Ran::OutOfTime(running.stop(vm.connection()).await)),
    }
}

/// How the model hears of a background command, `job`, writing to `file`.
fn follow(job: &str, file: &str) -> String {
    format!(
        "When it ends, its exit status and output come back to you as [{job} 完成]: don't sleep \
         waiting for it, and don't keep checking. Its output is written to {file} as it runs: to \
         see how far it is, read the end of that; if it isn't wanted any more, stop it with \
         agent_cancel."
    )
}

fn exited(status: Option<u32>) -> String {
    match status {
        Some(code) => format!("exit status {code}"),
        None => "no exit status: the command may have been killed".to_owned(),
    }
}

/// A command's run time, as the model is told it.
fn took(elapsed: Duration) -> String {
    let seconds = elapsed.as_secs();
    match seconds {
        0..60 => format!("{seconds} seconds"),
        _ => format!("{} minutes {} seconds", seconds / 60, seconds % 60),
    }
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
    fn a_run_time_is_in_seconds_or_minutes() {
        assert_eq!(took(Duration::from_millis(5400)), "5 seconds");
        assert_eq!(took(Duration::from_secs(192)), "3 minutes 12 seconds");
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
            "\nMax tools called: history 4 (1 failed), memory_list 1"
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
