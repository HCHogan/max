//! The conversation's background jobs: agents (`agent#3`), `shell`
//! commands (`shell#4`), and questions put to Max in another conversation
//! (`ask#5`). Started by its turns, outliving the core that started them,
//! and waking Max when they end, and agents when they ask something. See
//! "Background agents", "Background commands" and "Asking another
//! conversation" in docs/rust-rewrite.md.

use std::collections::BTreeMap;
use std::sync::{Mutex, PoisonError};

use max_db::links::Peer;
use tokio::sync::mpsc::unbounded_channel;
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;

use super::*;
use crate::job::{self, Finished, Progress, Status};
use crate::tools::{self, Background, Moved};
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
    shell: u32,
    ask: u32,
}

struct Running {
    title: String,
    started: Instant,
    kind: Kind,
    /// Dropping it stops the job: the agent's unit, the command's, or the
    /// wait for an answer.
    _task: Scope,
}

enum Kind {
    Agent(Agent),
    Command,
    /// A question put to Max in another conversation: which, and what
    /// was asked, for the core that hears the answer.
    Question {
        to: Peer,
        question: String,
    },
}

struct Agent {
    steers: UnboundedSender<String>,
    progress: Arc<Mutex<Progress>>,
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

    /// Stops `handle`: nobody hears of it again.
    pub(super) fn cancel_job(&mut self, handle: Handle) -> Result<(), String> {
        if self.jobs.running.remove(&handle).is_none() {
            return Err(match handle {
                Handle::Ask(number) if self.asked.waits(number) => format!(
                    "{handle} was asked of you, by Max in another conversation: answer it with answer, or leave it unanswered"
                ),
                _ => over(handle),
            });
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
        }));
        let pages = Budgets::for_window(upstream.window).single;
        let services = &self.shared.services;
        let context = mcp::Context::new(services, &self.place, caller, pages, self.call_time());
        let (steers, steered) = unbounded_channel();
        let progress = Arc::<Mutex<Progress>>::default();
        let asking = self.mailbox.clone();
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
            ask: Box::new(move |question| {
                let _ = asking.send(Event::JobAsks {
                    agent: number,
                    question,
                });
            }),
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
                kind: Kind::Agent(Agent { steers, progress }),
                _task: task,
            },
        );
        Ok(number)
    }

    /// Runs a `shell` command in the background, as a job of its own: its
    /// number.
    pub(super) fn start_command(&mut self, shell: Background) -> Result<u32, String> {
        self.room_for_command()?;
        let Some(vms) = self.shared.vms.clone() else {
            return Err("there are no VMs here, so shell can't run".to_owned());
        };
        let conversation = self.place.conversation;
        let command = shell.command.clone();
        let work = tools::background(vms, conversation, shell);
        let number = self.command_job(&command, Instant::now(), work);
        info!(conversation = %conversation, shell = number, "a background command starts");
        Ok(number)
    }

    /// Takes a turn's command someone waits on as a background job of its
    /// own: its number; or, without room for it, gives it back.
    pub(super) fn adopt(&mut self, moved: Box<Moved>) -> Result<u32, (String, Box<Moved>)> {
        if let Err(why) = self.room_for_command() {
            return Err((why, moved));
        }
        let (command, begun) = (moved.command.clone(), moved.begun);
        let number = self.command_job(&command, begun, tools::moved(moved));
        info!(conversation = %self.place.conversation, shell = number, "a command someone waits on moves to the background");
        Ok(number)
    }

    /// Whether another background command may run now.
    fn room_for_command(&self) -> Result<(), String> {
        let most = self.commands_at_once();
        if self.jobs.commands() >= most {
            return Err(format!(
                "{most} background commands run already: wait for one to end, or stop one with cancel"
            ));
        }
        Ok(())
    }

    /// Runs `work`, `command` begun at `started`, as a job: its number.
    fn command_job(
        &mut self,
        command: &str,
        started: Instant,
        work: impl Future<Output = Finished> + Send + 'static,
    ) -> u32 {
        let number = self.jobs.next_shell();
        let mailbox = self.mailbox.clone();
        let mut task = Scope::new();
        task.spawn(move |_| async move {
            let finished = work.await;
            let _ = mailbox.send(Event::JobDone {
                handle: Handle::Shell(number),
                finished,
            });
        });
        let running = Running {
            title: format!("$ {}", headline(command)),
            started,
            kind: Kind::Command,
            _task: task,
        };
        self.jobs.running.insert(Handle::Shell(number), running);
        number
    }

    /// Waits for the answer to `question`, put to Max in `to`, as a job:
    /// its number. The wait ends with the answer, or with why none comes;
    /// withdrawn, nobody is told, and an answer finds nobody waiting.
    pub(super) fn question_job(
        &mut self,
        to: Peer,
        question: &str,
        answered: oneshot::Receiver<Result<String, String>>,
    ) -> u32 {
        let number = self.jobs.next_ask();
        let mailbox = self.mailbox.clone();
        let mut task = Scope::new();
        task.spawn(move |_| async move {
            let answer = match tokio::time::timeout(limits::JOB_TIME, answered).await {
                Ok(Ok(answer)) => answer,
                // The question was dropped on its way, or with the actor
                // that held it.
                Ok(Err(_)) => Err("Max there stopped before answering".to_owned()),
                Err(_) => Err(format!(
                    "no answer in {} hours",
                    limits::JOB_TIME.as_secs() / 3600
                )),
            };
            let _ = mailbox.send(Event::Answered {
                ask: number,
                answer,
            });
        });
        let running = Running {
            title: format!("? {to}: {}", headline(question)),
            started: Instant::now(),
            kind: Kind::Question {
                to,
                question: question.to_owned(),
            },
            _task: task,
        };
        self.jobs.running.insert(Handle::Ask(number), running);
        number
    }

    /// Ends the wait of question `ask`: whom it was put to, and the
    /// question. None if it was withdrawn since.
    pub(super) fn question_over(&mut self, ask: u32) -> Option<(Peer, String)> {
        match self.jobs.running.remove(&Handle::Ask(ask))?.kind {
            Kind::Question { to, question } => Some((to, question)),
            Kind::Agent(_) | Kind::Command => None,
        }
    }

    /// Agent `agent` asks Max: its question wakes Max, who answers with
    /// `agent_steer`.
    pub(super) async fn job_asks(&mut self, agent: u32, question: String) -> Result<()> {
        let handle = Handle::Agent(agent);
        // Cancelled since.
        let Some(running) = self.jobs.running.get(&handle) else {
            return Ok(());
        };
        info!(conversation = %self.place.conversation, %handle, "an agent asks Max");
        let notice = Notice::Asks {
            agent,
            title: &running.title,
            question: &question,
        };
        let item = notice.item(self.single());
        self.wake_with(Reason::Job { job: handle }, item).await
    }

    /// An agent or a command ended: Max hears how, in the running core or
    /// a new one.
    pub(super) async fn job_done(&mut self, handle: Handle, finished: Finished) -> Result<()> {
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
                    Kind::Command | Kind::Question { .. } => String::new(),
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
            }),
            _task: Scope::new(),
        };
        self.running.insert(Handle::Agent(number), running);
        steered
    }
}

#[cfg(test)]
impl Jobs {
    /// A background command as if started, with nothing behind it.
    pub(super) fn pretend_command(&mut self, title: &str) {
        let number = self.next_shell();
        let running = Running {
            title: title.to_owned(),
            started: Instant::now(),
            kind: Kind::Command,
            _task: Scope::new(),
        };
        self.running.insert(Handle::Shell(number), running);
    }
}

impl Jobs {
    fn next_agent(&mut self) -> u32 {
        self.last.agent += 1;
        self.last.agent
    }

    fn next_shell(&mut self) -> u32 {
        self.last.shell += 1;
        self.last.shell
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

    /// The agents running. They and the background commands have a limit
    /// each; the questions waiting have none.
    fn agents(&self) -> usize {
        let jobs = self.running.values();
        jobs.filter(|running| matches!(running.kind, Kind::Agent(_)))
            .count()
    }

    /// The background commands running.
    fn commands(&self) -> usize {
        let jobs = self.running.values();
        jobs.filter(|running| matches!(running.kind, Kind::Command))
            .count()
    }
}

impl Running {
    /// An agent's progress; a background command has none to count, nor
    /// has a question.
    fn progress(&self) -> Progress {
        match &self.kind {
            Kind::Agent(agent) => agent
                .progress
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .clone(),
            Kind::Command | Kind::Question { .. } => Progress::default(),
        }
    }
}

fn over(handle: Handle) -> String {
    match handle {
        Handle::Ask(_) => format!(
            "{handle} isn't waiting for an answer: it was answered, withdrawn or out of time, or never was"
        ),
        Handle::Agent(_) | Handle::Shell(_) => {
            format!("{handle} isn't running: it ended, was cancelled, or never was")
        }
    }
}

/// A title from the task's first line, when none was given.
fn headline(task: &str) -> String {
    let line = task.trim().lines().next().unwrap_or_default();
    let mut title: String = line.chars().take(30).collect();
    if line.chars().count() > 30 {
        title.push('…');
    }
    title
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_title_defaults_to_the_tasks_first_line() {
        assert_eq!(headline("  查一下明天的天气\n背景：……"), "查一下明天的天气");
        let long = "字".repeat(40);
        assert_eq!(headline(&long), format!("{}…", "字".repeat(30)));
    }
}
