//! The conversation's background jobs: agents (`agent#3`), and questions
//! put to Max in another conversation (`ask#5`), Max's or an agent's.
//! Started by its turns, outliving the core that started them, and waking
//! Max when they end. A background command of `shell`'s is not one: it is
//! a unit of the guest's, which tells Max of its end itself. See
//! "Background agents", "Asking another conversation" and "Lifetimes move
//! to systemd" in docs/rust-rewrite.md.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::sync::{Mutex, PoisonError};

use max_db::links::Peer;
use tokio::sync::mpsc::unbounded_channel;
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;

use super::*;
use crate::job::{self, Asking, Finished, Open, Progress, Status};
use crate::tools::headline;
use max_core::limits;

/// The jobs running, by handle.
#[derive(Default)]
pub(super) struct Jobs {
    running: BTreeMap<Handle, Running>,
    last: Last,
}

/// The last number of each kind: each is numbered on its own, within the
/// conversation while max runs. Questions count together whichever way
/// they go, so that `ask#5` is one question here.
#[derive(Default)]
struct Last {
    agent: u32,
    ask: u32,
}

struct Running {
    title: String,
    started: Instant,
    kind: Kind,
    /// Dropping it stops the job: the agent's unit, or the wait for an
    /// answer.
    _task: Scope,
}

enum Kind {
    Agent(Agent),
    /// A question put to Max in another conversation: which, and what
    /// was asked, for the core that hears the answer; or for the agent
    /// that asked it, which hears it instead.
    Question {
        to: Peer,
        question: String,
        by: Option<AgentWaits>,
    },
}

struct Agent {
    steers: UnboundedSender<String>,
    progress: Arc<Mutex<Progress>>,
    /// Its questions that wait for their answers.
    open: Open,
}

/// An agent that asked something and waits: where the answer goes, as a
/// steer, and the question, kept open until then.
pub(super) struct AgentWaits {
    pub(super) agent: u32,
    steers: UnboundedSender<String>,
    _open: Asking,
}

impl AgentWaits {
    /// Hands the agent `text`: false if it's gone.
    pub(super) fn tell(&self, text: String) -> bool {
        self.steers.send(text).is_ok()
    }

    pub(super) fn gone(&self) -> bool {
        self.steers.is_closed()
    }
}

impl Conversation {
    /// Tells agent `agent` something more.
    pub(super) fn steer_job(&mut self, agent: u32, message: String) -> Result<(), String> {
        let handle = Handle::Agent(agent);
        let Some(Running {
            kind: Kind::Agent(agent),
            ..
        }) = self.jobs.running.get(&handle)
        else {
            return Err(over(handle));
        };
        agent.steers.send(message).map_err(|_| over(handle))
    }

    /// Agent `agent`, from now on waiting for an answer, and its title;
    /// None if it doesn't run.
    pub(super) fn agent_waits(&self, agent: u32) -> Option<(AgentWaits, String)> {
        let Some(Running {
            kind: Kind::Agent(running),
            title,
            ..
        }) = self.jobs.running.get(&Handle::Agent(agent))
        else {
            return None;
        };
        let waits = AgentWaits {
            agent,
            steers: running.steers.clone(),
            _open: running.open.asking(),
        };
        Some((waits, title.clone()))
    }

    /// Agent `agent` is over: nobody waits for the answers to its
    /// questions any more.
    fn agent_over(&mut self, agent: u32) {
        self.jobs.running.retain(|_, running| match &running.kind {
            Kind::Question { by: Some(by), .. } => by.agent != agent,
            _ => true,
        });
        self.asked.forget(agent);
    }

    /// Stops `handle`: nobody hears of it again. A question asked of
    /// Max here is declined: whoever asked hears so.
    pub(super) fn cancel_job(&mut self, handle: Handle) -> Result<(), String> {
        if let Handle::Agent(agent) = handle {
            self.agent_over(agent);
        }
        if let Handle::Ask(number) = handle
            && self.decline(number)
        {
            info!(conversation = %self.place.conversation, %handle, "a question is declined");
            return Ok(());
        }
        if self.jobs.running.remove(&handle).is_none() {
            return Err(over(handle));
        }
        info!(conversation = %self.place.conversation, %handle, "a job is cancelled");
        Ok(())
    }

    /// `handle` as it runs, or every running job.
    pub(super) fn jobs_running(&self, handle: Option<Handle>) -> Result<Vec<Status>, String> {
        let jobs: Vec<Status> = self
            .jobs
            .running
            .iter()
            .filter(|(running, _)| handle.is_none_or(|handle| handle == **running))
            .map(|(handle, running)| {
                let progress = running.progress();
                Status {
                    handle: handle.to_string(),
                    title: running.title.clone(),
                    minutes: running.started.elapsed().as_secs() / 60,
                    calls: progress.calls,
                    tools: progress.tools,
                    tool: progress.tool,
                }
            })
            .collect();
        match handle {
            Some(handle) if jobs.is_empty() => Err(over(handle)),
            _ => Ok(jobs),
        }
    }

    pub(super) fn start_job(
        &mut self,
        task: String,
        title: Option<String>,
        workdir: String,
    ) -> Result<u32, String> {
        if self.jobs.agents() >= limits::JOBS_AT_ONCE {
            return Err(format!(
                "{} background agents run already: wait for one to end, or cancel one",
                limits::JOBS_AT_ONCE
            ));
        }
        let upstream = match self.shared.models.job() {
            None => return Err("no model is configured for background agents".to_owned()),
            Some(Err(error)) => {
                warn!(%error, "no model for jobs");
                return Err("the model configured for background agents can't be used".to_owned());
            }
            Some(Ok(upstream)) => Arc::new(upstream),
        };
        let Some(vms) = self.shared.vms.clone() else {
            return Err("there are no VMs here for a background agent to run in".to_owned());
        };
        let number = self.jobs.next_agent();
        let title = title
            .map(|title| title.trim().to_owned())
            .filter(|title| !title.is_empty())
            .unwrap_or_else(|| headline(&task));
        let (called, calls) = unbounded_channel();
        let (hooks, hooked) = unbounded_channel();
        let stop = CancellationToken::new();
        let caller = mcp::Caller::Job(Arc::new(job::Link {
            upstream: Arc::clone(&upstream),
            called,
            hooks,
            stop: stop.clone(),
            poster: Poster::for_agent(self.mailbox.clone(), number),
        }));
        let pages = Budgets::for_window(upstream.window).single;
        let services = &self.shared.services;
        let context = mcp::Context::new(services, &self.place, caller, pages, self.call_time());
        let (steers, steered) = unbounded_channel();
        let progress = Arc::<Mutex<Progress>>::default();
        let open = Open::default();
        let start = job::Start {
            number,
            title: title.clone(),
            task,
            workdir,
            vms,
            context,
            upstream,
            calls,
            hooks: hooked,
            stop,
            deadline: Instant::now() + limits::JOB_TIME,
            progress: Arc::clone(&progress),
            open: open.clone(),
        };
        let mailbox = self.mailbox.clone();
        let mut task = Scope::new();
        task.spawn(move |_| async move {
            let finished = job::run(start, steered).await;
            let _ = mailbox.send(Event::JobDone {
                handle: Handle::Agent(number),
                finished,
            });
        });
        self.jobs.running.insert(
            Handle::Agent(number),
            Running {
                title,
                started: Instant::now(),
                kind: Kind::Agent(Agent {
                    steers,
                    progress,
                    open,
                }),
                _task: task,
            },
        );
        Ok(number)
    }

    /// Waits for the answer to `question`, put to Max in `to` by Max
    /// here or by agent `by`, as a job: its number. The wait ends with the
    /// answer, or with why none comes; withdrawn, nobody is told, and an
    /// answer finds nobody waiting.
    pub(super) fn question_job(
        &mut self,
        to: Peer,
        question: &str,
        answered: oneshot::Receiver<Result<String, String>>,
        by: Option<AgentWaits>,
    ) -> u32 {
        let number = self.jobs.next_ask();
        let mailbox = self.mailbox.clone();
        let mut task = Scope::new();
        task.spawn(move |_| async move {
            let answer = match tokio::time::timeout(limits::ASK_WAIT, answered).await {
                Ok(Ok(answer)) => answer,
                // The question was dropped on its way, or with the actor
                // that held it.
                Ok(Err(_)) => Err("Max there stopped before answering".to_owned()),
                Err(_) => Err(format!(
                    "no answer in {} hours",
                    limits::ASK_WAIT.as_secs() / 3600
                )),
            };
            let _ = mailbox.send(Event::Answered {
                ask: number,
                answer,
            });
        });
        let mut title = format!("? {to}: {}", headline(question));
        if let Some(by) = &by {
            let _ = write!(title, " ({})", Handle::Agent(by.agent));
        }
        let running = Running {
            title,
            started: Instant::now(),
            kind: Kind::Question {
                to,
                question: question.to_owned(),
                by,
            },
            _task: task,
        };
        self.jobs.running.insert(Handle::Ask(number), running);
        number
    }

    /// Ends the wait of question `ask`: whom it was put to, the
    /// question, and the agent that asked it, if one did. None if it was
    /// withdrawn since.
    pub(super) fn question_over(&mut self, ask: u32) -> Option<(Peer, String, Option<AgentWaits>)> {
        match self.jobs.running.remove(&Handle::Ask(ask))?.kind {
            Kind::Question { to, question, by } => Some((to, question, by)),
            Kind::Agent(_) => None,
        }
    }

    /// An agent ended: Max hears how, in the running core or a new one.
    pub(super) async fn job_done(&mut self, handle: Handle, finished: Finished) -> Result<()> {
        if let Handle::Agent(agent) = handle {
            self.agent_over(agent);
        }
        // Cancelled since.
        let Some(running) = self.jobs.running.remove(&handle) else {
            return Ok(());
        };
        info!(conversation = %self.place.conversation, %handle, how = ?finished.ending.how, "a job ends");
        let notice = Notice::Ended {
            handle,
            title: &running.title,
            finished: &finished,
        };
        let item = notice.item(self.single());
        self.wake_with(Reason::Job { job: handle }, item).await
    }

    /// Stops every job, for `/kill`: their handles.
    pub(super) fn cancel_jobs(&mut self) -> Vec<Handle> {
        let jobs = std::mem::take(&mut self.jobs.running);
        jobs.into_keys().collect()
    }

    /// A line a job, for `/status`.
    pub(super) fn job_lines(&self) -> Vec<String> {
        self.jobs
            .running
            .iter()
            .map(|(handle, running)| {
                let calls = match &running.kind {
                    Kind::Agent(_) => format!(" · {} calls", running.progress().calls),
                    Kind::Question { .. } => String::new(),
                };
                format!(
                    "{handle} · {}m{calls} · {}",
                    running.started.elapsed().as_secs() / 60,
                    running.title
                )
            })
            .collect()
    }

    /// The most tokens one item may take: the running core's, or the
    /// next one's.
    pub(super) fn single(&self) -> u32 {
        let settings = &self.settings;
        let window = match &self.core {
            Some(a) => Some(a.chosen.window),
            None => self
                .shared
                .models
                .turn(settings.model.as_deref(), settings.effort.as_deref())
                .ok()
                .map(|chosen| chosen.window),
        };
        Budgets::for_window(window.unwrap_or(0)).single
    }
}

#[cfg(test)]
impl Jobs {
    /// A job as if started, with nothing behind it: where its steers go.
    pub(super) fn pretend(&mut self, title: &str) -> tokio::sync::mpsc::UnboundedReceiver<String> {
        let (steers, steered) = unbounded_channel();
        let number = self.next_agent();
        let running = Running {
            title: title.to_owned(),
            started: Instant::now(),
            kind: Kind::Agent(Agent {
                steers,
                progress: Arc::default(),
                open: Open::default(),
            }),
            _task: Scope::new(),
        };
        self.running.insert(Handle::Agent(number), running);
        steered
    }
}

impl Jobs {
    fn next_agent(&mut self) -> u32 {
        self.last.agent += 1;
        self.last.agent
    }

    /// Whether `handle` runs, or waits for its answer.
    pub(super) fn has(&self, handle: Handle) -> bool {
        self.running.contains_key(&handle)
    }

    /// The next question's number, whichever way it goes.
    pub(super) fn next_ask(&mut self) -> u32 {
        self.last.ask += 1;
        self.last.ask
    }

    /// The agents running. They have a limit; the questions waiting have
    /// none.
    fn agents(&self) -> usize {
        let jobs = self.running.values();
        jobs.filter(|running| matches!(running.kind, Kind::Agent(_)))
            .count()
    }
}

impl Running {
    /// An agent's progress; a question has none to count.
    fn progress(&self) -> Progress {
        match &self.kind {
            Kind::Agent(agent) => agent
                .progress
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone(),
            Kind::Question { .. } => Progress::default(),
        }
    }
}

fn over(handle: Handle) -> String {
    match handle {
        Handle::Ask(_) => format!(
            "{handle} isn't waiting for an answer: it was answered, withdrawn or out of time, or never was"
        ),
        Handle::Agent(_) => {
            format!("{handle} isn't running: it ended, was cancelled, or never was")
        }
    }
}
