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
use tokio::sync::{oneshot, watch};
use tokio::time::{Instant, sleep_until};
use tokio_util::sync::CancellationToken;

use crate::conversation::Poster;
use crate::llm::Upstream;
use max_core::limits::QUESTION_WAIT;
pub use run::{Finished, Progress, Start, run};

/// What a job's session knows of it: the model its calls go to, who
/// hears how each went, where its harness's calls go, when it is to
/// stop, and the conversation its `ask` and `answer` go to.
#[derive(Debug)]
pub struct Link {
    pub upstream: Arc<Upstream>,
    pub called: UnboundedSender<Called>,
    /// `/job/turn`'s and `/job/report`'s.
    pub hooks: UnboundedSender<Hook>,
    /// Cancelled at the deadline, for `/job/stop`.
    pub stop: CancellationToken,
    pub poster: Poster,
}

/// What the harness calls for, at one of its hooks.
#[derive(Debug)]
pub enum Hook {
    /// A turn has ended, or the agent is about to settle: the steers
    /// since the last, and whether to stop. Dropped unanswered, it took
    /// none of them.
    Turn {
        settling: bool,
        reply: oneshot::Sender<Turn>,
    },
    /// The agent has settled: the job ends.
    Report(Report),
}

/// The questions an agent asked with `ask` that still wait for their
/// answers, which come to it as steers. While there are any, an agent
/// about to settle waits for one, for [`QUESTION_WAIT`] at most.
#[derive(Clone, Debug, Default)]
pub struct Open(Arc<watch::Sender<usize>>);

/// One of an agent's open questions: dropped, answered or not, it is no
/// longer open.
#[derive(Debug)]
pub struct Asking(Open);

impl Open {
    pub fn asking(&self) -> Asking {
        self.0.send_modify(|open| *open += 1);
        Asking(self.clone())
    }

    fn any(&self) -> bool {
        *self.0.borrow() > 0
    }

    /// Done once none is open.
    async fn none(&self) {
        let mut open = self.0.subscribe();
        let _ = open.wait_for(|open| *open == 0).await;
    }
}

impl Drop for Asking {
    fn drop(&mut self) {
        self.0.0.send_modify(|open| *open -= 1);
    }
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

/// How the harness's process ended: its exit status, if the guest sent
/// one; what it wrote, for one with no plugin to report; and the end of
/// its stderr.
#[derive(Debug, Default)]
pub struct Exit {
    pub status: Option<u32>,
    pub out: String,
    pub err: String,
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

/// What runs or waits in the background, as `status` shows it: an agent,
/// or a question asked from here, by Max or an agent.
#[derive(Debug, PartialEq, Eq, Serialize, JsonSchema)]
pub struct Status {
    pub handle: String,
    pub title: String,
    pub minutes: u64,
    pub calls: u32,
    pub tools: u32,
    pub tool: Option<String>,
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
/// reports, or its process ends: holds Max's `steers`, the answers to the
/// agent's questions among them, until the next turn's end takes them,
/// tells the agent to wrap up shortly before `deadline`, and cancels
/// `stop` then. An agent about to settle with questions still `open` is
/// held there until something comes for it, for [`QUESTION_WAIT`] at
/// most. A harness with no plugin only ends: `exited` tells how, and its
/// output is the report.
pub async fn drive(
    hooks: &mut UnboundedReceiver<Hook>,
    steers: &mut UnboundedReceiver<String>,
    exited: &mut oneshot::Receiver<Exit>,
    stop: &CancellationToken,
    deadline: Instant,
    open: &Open,
) -> Ending {
    // The steers not yet taken in, and Max's dropped at the deadline;
    // whether the queue holds the wrap-up, which isn't Max's.
    let mut queue = Vec::new();
    let mut dropped = 0;
    let mut wrapping = false;
    let mut stopped: Option<Instant> = None;
    // The settling agent's turn, held for an answer, and until when.
    let mut held: Option<(oneshot::Sender<Turn>, Instant)> = None;
    // Only a job that has the time is told.
    let mut wrap_up = deadline
        .checked_sub(WARNING)
        .filter(|at| *at > Instant::now());
    let (how, text) = loop {
        let give_up = stopped.map(|at| at + GRACE);
        let hold_until = held.as_ref().map(|(_, until)| *until);
        tokio::select! {
            // The report comes before the process ends, and a steer before
            // the end of the wait it answers.
            biased;
            Some(hook) = hooks.recv() => match hook {
                Hook::Turn { settling, reply } => {
                    // Every steer sent before the turn ended.
                    while stopped.is_none() && let Ok(steer) = steers.try_recv() {
                        queue.push(steer);
                    }
                    // Another turn's end: the one held is gone.
                    held = None;
                    if settling && queue.is_empty() && stopped.is_none() && open.any() {
                        held = Some((reply, Instant::now() + QUESTION_WAIT));
                    } else {
                        hand(reply, &mut queue, &mut wrapping, stopped.is_some());
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
                queue.push(steer);
                release(&mut held, &mut queue, &mut wrapping, false);
            }
            // Withdrawn, or answered: then its answer came first.
            () = open.none(), if held.is_some() => {
                release(&mut held, &mut queue, &mut wrapping, false);
            }
            () = sleep_until(hold_until.unwrap_or(deadline)), if hold_until.is_some() => {
                release(&mut held, &mut queue, &mut wrapping, false);
            }
            () = sleep_until(wrap_up.unwrap_or(deadline)), if wrap_up.is_some() => {
                wrap_up = None;
                queue.push(wrap_up_message());
                wrapping = true;
                release(&mut held, &mut queue, &mut wrapping, false);
            }
            () = sleep_until(deadline), if stopped.is_none() => {
                stopped = Some(Instant::now());
                dropped += mem::take(&mut queue).len() - usize::from(mem::take(&mut wrapping));
                stop.cancel();
                release(&mut held, &mut queue, &mut wrapping, true);
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

/// Hands a turn's end the steers queued, and whether to stop; one whose
/// call is gone took none of them.
fn hand(reply: oneshot::Sender<Turn>, queue: &mut Vec<String>, wrapping: &mut bool, stop: bool) {
    let turn = Turn {
        steers: mem::take(queue),
        stop,
    };
    let took = mem::take(wrapping);
    if let Err(turn) = reply.send(turn) {
        *queue = turn.steers;
        *wrapping = took;
    }
}

/// Lets the turn held for an answer go, with what came meanwhile.
fn release(
    held: &mut Option<(oneshot::Sender<Turn>, Instant)>,
    queue: &mut Vec<String>,
    wrapping: &mut bool,
    stop: bool,
) {
    if let Some((reply, _)) = held.take() {
        hand(reply, queue, wrapping, stop);
    }
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
