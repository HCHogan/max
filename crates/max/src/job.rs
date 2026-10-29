//! Background agents: pi in the group's VM, given a task by Max, working
//! while the group talks on, and reporting when it's done. See "后台
//! agent" in docs/rust-rewrite.md.

pub mod pi;
mod run;

use std::future::Future;
use std::time::Duration;

use max_core::item::Usage;
use tokio::io::{AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc::UnboundedReceiver;
use tokio::time::{Instant, sleep_until, timeout};
use tracing::warn;

use pi::{Ask, Record};
pub use run::{Finished, Progress, Start, run};

/// The most jobs a conversation runs at once.
pub const MOST: usize = 3;
/// How long a job may take; then it is aborted, and reports how far it got.
pub const TIME: Duration = Duration::from_secs(30 * 60);

/// What a tool asks of its conversation's background agents.
#[derive(Debug)]
pub enum Request {
    Start {
        task: String,
        title: Option<String>,
    },
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

/// How long pi has to settle once aborted, and to give its last text.
const GRACE: Duration = Duration::from_secs(15);

const GONE: &str = "pi 意外退出了";

/// What a job's driver tells as it goes.
pub trait Watch {
    /// A model call ended.
    fn called(&mut self, usage: Usage) -> impl Future<Output = ()> + Send;
    /// A tool call began.
    fn tool(&mut self, name: &str);
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
/// settles, aborting it at `deadline`. `records` are the lines of pi's
/// stdout, and end when pi does; `input` is its stdin, closed at the end.
pub async fn drive(
    input: impl AsyncWrite + Unpin,
    records: &mut UnboundedReceiver<Vec<u8>>,
    steers: &mut UnboundedReceiver<String>,
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
    loop {
        let give_up = aborted.map(|at| at + GRACE);
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
                    Ok(Record::Called { usage, error: why }) => {
                        watch.called(usage).await;
                        error = why;
                    }
                    Ok(Record::Tool(name)) => watch.tool(&name),
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
            Some(steer) = steers.recv(), if aborted.is_none() => {
                if pi.ask(Ask::Steer(&steer)).await.is_err() {
                    return failed(GONE);
                }
            }
            () = sleep_until(deadline), if aborted.is_none() => {
                aborted = Some(Instant::now());
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
