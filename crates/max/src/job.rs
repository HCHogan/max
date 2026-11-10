//! Background agents: an agent harness in the group's VM, pi so far,
//! given a task by Max, working while the group talks on, and reporting
//! when it's done. The host holds a contract with the harness's plugin,
//! not with the harness: see "Background agents" and "Decoupling from the
//! harness" in docs/rust-rewrite.md.

mod run;

use std::mem;
use std::sync::Arc;
use std::time::Duration;

use max_core::item::{Timing, Usage};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};
use tokio::sync::oneshot;
use tokio::time::{Instant, sleep_until};
use tokio_util::sync::CancellationToken;

use crate::llm::Upstream;
use max_core::limits::QUESTION_WAIT;
pub use run::{Asker, Finished, Progress, Start, run};

/// What a job's session knows of it: the model its calls go to, who
/// hears how each went, where its harness's calls go, and when it is to
/// stop.
#[derive(Debug)]
pub struct Link {
    pub upstream: Arc<Upstream>,
    pub called: UnboundedSender<Called>,
    /// `/job/turn`'s, `/job/ask`'s and `/job/report`'s.
    pub hooks: UnboundedSender<Hook>,
    /// Cancelled at the deadline, for `/job/stop`.
    pub stop: CancellationToken,
}

/// What the harness calls for, at one of its hooks.
#[derive(Debug)]
pub enum Hook {
    /// A turn has ended: the steers since the last, and whether to stop.
    /// Dropped unanswered, it took none of them.
    Turn(oneshot::Sender<Turn>),
    Ask(Question),
    /// The agent has settled: the job ends.
    Report(Report),
}

/// What a turn's end is told.
#[derive(Debug, Default, PartialEq, Eq, Serialize)]
pub struct Turn {
    pub steers: Vec<String>,
    pub stop: bool,
}

/// What the agent settled with: its last text, and its last model
/// call's error.
#[derive(Debug, Default, PartialEq, Eq, Deserialize)]
pub struct Report {
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
}

/// The agent's question to Max, from `ask_max` through `/job/ask`, and
/// where the answer goes: None if there is none.
#[derive(Debug)]
pub struct Question {
    pub text: String,
    pub answer: oneshot::Sender<Option<String>>,
}

/// How the harness's process ended: its exit status, if the guest sent
/// one; what it wrote, for one with no plugin to report; and the end of
/// its stderr.
#[derive(Debug, Default)]
pub struct Exit {
    pub status: Option<u32>,
    pub out: String,
    pub err: String,
}

/// The question the agent waits on, and since when.
struct Waiting {
    answer: oneshot::Sender<Option<String>>,
    since: Instant,
}

/// The question the agent still waits on, taken: one whose `ask_max`
/// call is gone waits no more.
fn waiting(question: &mut Option<Waiting>) -> Option<Waiting> {
    question
        .take()
        .filter(|waiting| !waiting.answer.is_closed())
}

/// Tells the agent waiting on `question`, if any, that no answer is
/// coming.
fn unanswered(question: &mut Option<Waiting>) {
    if let Some(waiting) = question.take() {
        let _ = waiting.answer.send(None);
    }
}

/// One of the agent's model calls, as the forwarder read it on its way
/// back; told however the call ended.
#[derive(Debug, PartialEq, Eq)]
pub struct Called {
    pub usage: Usage,
    pub timing: Timing,
    /// The tools the model called, in order.
    pub tools: Vec<String>,
}

/// A job running, as `agent_status` shows it.
#[derive(Debug, PartialEq, Eq, Serialize, JsonSchema)]
pub struct Status {
    pub job: String,
    pub title: String,
    pub minutes: u64,
    pub calls: u32,
    pub tools: u32,
    pub tool: Option<String>,
}

/// How a job is named to Max.
pub fn name(job: u32) -> String {
    format!("job#{job}")
}

/// How long the agent has to settle and report once told to stop.
const GRACE: Duration = Duration::from_secs(15);

/// How long before its deadline the agent is told to stop and write its
/// report: stopped with a tool call under way, it has none to give.
const WARNING: Duration = Duration::from_secs(5 * 60);
/// What the agent is told at [`WARNING`].
fn wrap_up_message() -> String {
    format!(
        "还剩 {} 分钟就到点了。别再查新的：现在先更新笔记，再把已经查到的写成报告交给 Max，没做完的写明做到哪了。",
        WARNING.as_secs() / 60
    )
}

/// How much of stderr's end a failure's reason carries.
const WHY_KEPT: usize = 300;

/// What a job's driver tells as it goes. Its model calls and their tools
/// the forwarder tells, as [`Called`].
pub trait Watch {
    /// The agent asks Max `question`, and waits for the answer.
    fn asks(&mut self, question: &str);
}

/// How a job ended, the agent's last text, its report or how far it got,
/// and how many of Max's steers it never took in.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Ending {
    pub how: How,
    pub text: Option<String>,
    pub unsent: usize,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub enum How {
    #[default]
    Done,
    /// Stopped at its deadline.
    OutOfTime,
    Failed(String),
}

/// Keeps the job's side of the contract with its harness until the agent
/// reports, or its process ends: holds Max's `steers` until the next
/// turn's end takes them, tells the agent to wrap up shortly before
/// `deadline`, and cancels `stop` then. While the agent waits on a
/// question, the next steer is its answer; none within
/// [`QUESTION_WAIT`], and it is told none is coming. A harness with no
/// plugin only ends: `exited` tells how, and its output is the report.
pub async fn drive(
    hooks: &mut UnboundedReceiver<Hook>,
    steers: &mut UnboundedReceiver<String>,
    exited: &mut oneshot::Receiver<Exit>,
    stop: &CancellationToken,
    deadline: Instant,
    watch: &mut impl Watch,
) -> Ending {
    // The steers not yet taken in, and Max's dropped at the deadline;
    // whether the queue holds the wrap-up, which isn't Max's.
    let mut queue = Vec::new();
    let mut dropped = 0;
    let mut wrapping = false;
    let mut stopped: Option<Instant> = None;
    let mut question: Option<Waiting> = None;
    // Only a job that has the time is told.
    let mut wrap_up = deadline
        .checked_sub(WARNING)
        .filter(|at| *at > Instant::now());
    let (how, text) = loop {
        let give_up = stopped.map(|at| at + GRACE);
        let given_up_on = question
            .as_ref()
            .map(|waiting| waiting.since + QUESTION_WAIT);
        tokio::select! {
            // The report comes before the process ends.
            biased;
            Some(hook) = hooks.recv() => match hook {
                Hook::Turn(reply) => {
                    // Every steer sent before the turn ended.
                    while stopped.is_none() && let Ok(steer) = steers.try_recv() {
                        take(steer, &mut question, &mut queue);
                    }
                    let turn = Turn { steers: mem::take(&mut queue), stop: stopped.is_some() };
                    let took = mem::take(&mut wrapping);
                    if let Err(turn) = reply.send(turn) {
                        queue = turn.steers;
                        wrapping = took;
                    }
                }
                Hook::Ask(asked) => {
                    // ask_max runs one at a time; nobody answers once it's over.
                    let open = question.as_ref().is_some_and(|waiting| !waiting.answer.is_closed());
                    if stopped.is_some() || open {
                        let _ = asked.answer.send(None);
                    } else {
                        watch.asks(&asked.text);
                        question = Some(Waiting { answer: asked.answer, since: Instant::now() });
                    }
                }
                Hook::Report(Report { text, error }) => {
                    let how = match (stopped, error) {
                        (Some(_), _) => How::OutOfTime,
                        (None, Some(why)) => How::Failed(why),
                        (None, None) => How::Done,
                    };
                    break (how, text);
                }
            },
            exit = &mut *exited => {
                let Exit { status, out, err } = exit.unwrap_or_default();
                let text = Some(out.trim().to_owned()).filter(|out| !out.is_empty());
                let how = match status {
                    _ if stopped.is_some() => How::OutOfTime,
                    Some(0) => How::Done,
                    status => How::Failed(failure(status, &err)),
                };
                break (how, text);
            }
            Some(steer) = steers.recv(), if stopped.is_none() => {
                take(steer, &mut question, &mut queue);
            }
            () = sleep_until(given_up_on.unwrap_or(deadline)), if given_up_on.is_some() => {
                unanswered(&mut question);
            }
            () = sleep_until(wrap_up.unwrap_or(deadline)), if wrap_up.is_some() => {
                wrap_up = None;
                // The agent waiting on Max couldn't take the steer in.
                unanswered(&mut question);
                queue.push(wrap_up_message());
                wrapping = true;
            }
            () = sleep_until(deadline), if stopped.is_none() => {
                stopped = Some(Instant::now());
                unanswered(&mut question);
                dropped += mem::take(&mut queue).len() - usize::from(mem::take(&mut wrapping));
                stop.cancel();
            }
            () = sleep_until(give_up.unwrap_or(deadline)), if give_up.is_some() => {
                break (How::OutOfTime, None);
            }
        }
    };
    // Those that came after the deadline too.
    let mut unsent = dropped + queue.len() - usize::from(wrapping);
    while steers.try_recv().is_ok() {
        unsent += 1;
    }
    Ending { how, text, unsent }
}

/// Takes in Max's `steer`: the answer to the question the agent waits
/// on, if any, else the next turn's end's.
fn take(steer: String, question: &mut Option<Waiting>, queue: &mut Vec<String>) {
    // An answer whose question went in the meantime is a steer.
    let steer = match waiting(question) {
        Some(waiting) => waiting.answer.send(Some(steer)).err().flatten(),
        None => Some(steer),
    };
    queue.extend(steer);
}

/// Why a harness that ended with `status` and didn't report failed: the
/// end of what it wrote on stderr says.
fn failure(status: Option<u32>, err: &str) -> String {
    let mut why = match status {
        Some(code) => format!("the agent exited with status {code}"),
        None => "the agent exited unexpectedly".to_owned(),
    };
    let last = err
        .lines()
        .rev()
        .map(str::trim)
        .find(|line| !line.is_empty());
    if let Some(last) = last {
        let cut = last
            .char_indices()
            .nth(WHY_KEPT)
            .map_or(last.len(), |(at, _)| at);
        why = format!("{why}: {}", &last[..cut]);
    }
    why
}

#[cfg(test)]
mod tests;
