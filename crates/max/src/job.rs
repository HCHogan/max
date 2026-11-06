//! Background agents: pi in the group's VM, given a task by Max, working
//! while the group talks on, and reporting when it's done. See "后台
//! agent" in docs/rust-rewrite.md.

pub mod pi;
mod run;

use std::sync::Arc;
use std::time::Duration;

use max_core::item::{Timing, Usage};
use schemars::JsonSchema;
use serde::Serialize;
use tokio::io::{AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};
use tokio::sync::oneshot;
use tokio::time::{Instant, sleep_until, timeout};
use tracing::warn;

use crate::llm::Upstream;
use max_core::limits::QUESTION_WAIT;
use pi::{Ask, Record};
pub use run::{Asker, Finished, Progress, Start, run};

/// What a job's session knows of it: the model its calls go to, who
/// hears how each went, and where its questions go.
#[derive(Debug)]
pub struct Link {
    pub upstream: Arc<Upstream>,
    pub called: UnboundedSender<Called>,
    pub asks: UnboundedSender<Question>,
}

/// The agent's question to Max, from `ask_max` through `/job/ask`, and
/// where the answer goes: None if there is none.
#[derive(Debug)]
pub struct Question {
    pub text: String,
    pub answer: oneshot::Sender<Option<String>>,
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

/// What a tool asks of its conversation's background jobs: its agents,
/// and its `shell` commands run in the background.
#[derive(Debug)]
pub enum Request {
    Start {
        task: String,
        title: Option<String>,
    },
    Shell(crate::tools::Background),
    Steer {
        job: u32,
        message: String,
    },
    Cancel {
        job: u32,
    },
    /// One job's, or every running one's.
    Status {
        job: Option<u32>,
    },
}

/// What a request gets: the job it was about, or the jobs running.
#[derive(Debug, PartialEq, Eq)]
pub enum Reply {
    Job(u32),
    Running(Vec<Status>),
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

/// How long pi has to settle once aborted, and to give its last text.
const GRACE: Duration = Duration::from_secs(15);

/// How long before its deadline pi is told to stop and write its report:
/// aborted with a tool call under way, it has none to give.
const WARNING: Duration = Duration::from_secs(5 * 60);
/// What pi is told at [`WARNING`].
fn wrap_up_message() -> String {
    format!(
        "还剩 {} 分钟就到点了。别再查新的，现在就把已经查到的写成报告交给 Max，没做完的写明做到哪了。",
        WARNING.as_secs() / 60
    )
}

const GONE: &str = "pi 意外退出了";

/// What a job's driver tells as it goes. Its model calls and their tools
/// the forwarder tells, as [`Called`].
pub trait Watch {
    /// The agent asks Max `question`, and waits for the answer.
    fn asks(&mut self, question: &str);
}

/// How a job ended, and the agent's last text: its report, or how far it
/// got.
#[derive(Debug, PartialEq, Eq)]
pub struct Ending {
    pub how: How,
    pub text: Option<String>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum How {
    Done,
    /// Aborted at its deadline.
    OutOfTime,
    Failed(String),
}

/// Gives pi `task`, passes on the steers that come, and waits until pi
/// settles, telling it to wrap up shortly before `deadline` and aborting it
/// then. While the agent waits on one of its `questions`, the next steer
/// is its answer; none within [`QUESTION_WAIT`], and it is told none is
/// coming. `records` are the lines of pi's stdout, and end when pi does;
/// `input` is its stdin, closed at the end.
pub async fn drive(
    input: impl AsyncWrite + Unpin,
    records: &mut UnboundedReceiver<Vec<u8>>,
    steers: &mut UnboundedReceiver<String>,
    questions: &mut UnboundedReceiver<Question>,
    task: &str,
    deadline: Instant,
    watch: &mut impl Watch,
) -> Ending {
    let failed = |why: &str| Ending {
        how: How::Failed(why.to_owned()),
        text: None,
    };
    let mut pi = Pi { input, next: 0 };
    if pi.ask(Ask::SteerAll).await.is_err() {
        return failed(GONE);
    }
    let Ok(prompt) = pi.ask(Ask::Prompt(task)).await else {
        return failed(GONE);
    };
    // The last model call's error: none once a retry got through.
    let mut error = None;
    let mut aborted: Option<Instant> = None;
    let mut question: Option<Waiting> = None;
    // Only a job that has the time is told.
    let mut wrap_up = deadline
        .checked_sub(WARNING)
        .filter(|at| *at > Instant::now());
    loop {
        let give_up = aborted.map(|at| at + GRACE);
        let given_up_on = question
            .as_ref()
            .map(|waiting| waiting.since + QUESTION_WAIT);
        tokio::select! {
            line = records.recv() => {
                let Some(line) = line else {
                    return failed(GONE);
                };
                match pi::parse(&line) {
                    Ok(Record::Response { id, error: Some(why), .. }) => {
                        if id == Some(prompt) {
                            return failed(&why);
                        }
                        warn!(%why, "pi refused a command");
                    }
                    Ok(Record::Called { error: why }) => error = why,
                    Ok(Record::Settled { .. }) => break,
                    Ok(Record::Dialog(dialog)) => {
                        if pi.ask(Ask::Dismiss(&dialog)).await.is_err() {
                            return failed(GONE);
                        }
                    }
                    Ok(Record::Notice(notice)) => warn!(%notice, "pi says"),
                    Ok(Record::Response { .. } | Record::Other) => {}
                    Err(why) => warn!(%why, "a record of pi's isn't JSON"),
                }
            }
            Some(asked) = questions.recv() => {
                // ask_max runs one at a time; nobody answers once it's over.
                let open = question.as_ref().is_some_and(|waiting| !waiting.answer.is_closed());
                if aborted.is_some() || open {
                    let _ = asked.answer.send(None);
                } else {
                    watch.asks(&asked.text);
                    question = Some(Waiting { answer: asked.answer, since: Instant::now() });
                }
            }
            Some(steer) = steers.recv(), if aborted.is_none() => {
                // An answer whose question went in the meantime is a steer.
                let steer = match waiting(&mut question) {
                    Some(waiting) => waiting.answer.send(Some(steer)).err().flatten(),
                    None => Some(steer),
                };
                if let Some(steer) = steer
                    && pi.ask(Ask::Steer(&steer)).await.is_err()
                {
                    return failed(GONE);
                }
            }
            () = sleep_until(given_up_on.unwrap_or(deadline)), if given_up_on.is_some() => {
                unanswered(&mut question);
            }
            () = sleep_until(wrap_up.unwrap_or(deadline)), if wrap_up.is_some() => {
                wrap_up = None;
                // The agent waiting on Max couldn't take the steer in.
                unanswered(&mut question);
                if pi.ask(Ask::Steer(&wrap_up_message())).await.is_err() {
                    return failed(GONE);
                }
            }
            () = sleep_until(deadline), if aborted.is_none() => {
                aborted = Some(Instant::now());
                unanswered(&mut question);
                let stopped = async {
                    pi.ask(Ask::ClearQueue).await?;
                    pi.ask(Ask::Abort).await
                };
                if stopped.await.is_err() {
                    return failed(GONE);
                }
            }
            () = sleep_until(give_up.unwrap_or(deadline)), if give_up.is_some() => {
                return Ending { how: How::OutOfTime, text: None };
            }
        }
    }
    let text = pi.last_text(records).await;
    let _ = pi.input.shutdown().await;
    let how = match (aborted, error) {
        (Some(_), _) => How::OutOfTime,
        (None, Some(why)) => How::Failed(why),
        (None, None) => How::Done,
    };
    Ending { how, text }
}

/// pi's stdin, and the next command's id.
struct Pi<W> {
    input: W,
    next: u64,
}

impl<W: AsyncWrite + Unpin> Pi<W> {
    /// Sends `ask`: its id.
    async fn ask(&mut self, ask: Ask<'_>) -> std::io::Result<u64> {
        self.next += 1;
        self.input.write_all(ask.line(self.next).as_bytes()).await?;
        self.input.flush().await?;
        Ok(self.next)
    }

    /// The text of pi's last assistant message, if it has one and says so
    /// in time.
    async fn last_text(&mut self, records: &mut UnboundedReceiver<Vec<u8>>) -> Option<String> {
        let id = self.ask(Ask::LastText).await.ok()?;
        let answer = async {
            while let Some(line) = records.recv().await {
                if let Ok(Record::Response {
                    id: Some(answered),
                    data,
                    ..
                }) = pi::parse(&line)
                    && answered == id
                {
                    return data["text"].as_str().map(str::to_owned);
                }
            }
            None
        };
        timeout(GRACE, answer).await.ok().flatten()
    }
}

#[cfg(test)]
mod tests;
