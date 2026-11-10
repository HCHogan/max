//! The conversation's background jobs: agents, `shell` commands, and
//! questions put to Max in another conversation. Started by its turns,
//! outliving the core that started them, and waking Max when they end,
//! and agents when they ask something. See "Background agents",
//! "Background commands" and "Asking another conversation" in
//! docs/rust-rewrite.md.

use std::borrow::Cow;
use std::collections::BTreeMap;
use std::fmt::Write;
use std::sync::{Mutex, PoisonError};

use max_core::item::Item;
use max_core::render::EXCERPT_CHARS;
use max_db::links::Peer;
use tokio::sync::mpsc::unbounded_channel;
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;

use super::*;
use crate::job::{self, Finished, How, Progress, Reply, Request, Status, name};
use crate::tools::{self, Background, Moved};
use max_core::limits;

/// The jobs running, by number.
#[derive(Default)]
pub(super) struct Jobs {
    running: BTreeMap<u32, Running>,
    /// Jobs are numbered within the conversation while max runs.
    last: u32,
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
    /// Answers a tool's request: what the program gets, or why not.
    pub(super) fn job_request(&mut self, request: Request) -> Result<Reply, String> {
        match request {
            Request::Start {
                task,
                title,
                workdir,
            } => self.start_job(task, title, workdir),
            Request::Shell(shell) => self.start_command(shell),
            Request::Steer { job, message } => {
                let running = self.jobs.running.get(&job).ok_or_else(|| over(job))?;
                let agent = match &running.kind {
                    Kind::Agent(agent) => agent,
                    Kind::Command => return Err(format!("{} 是后台命令，补不了话", name(job))),
                    Kind::Question { .. } => {
                        return Err(format!("{} 是在等别的会话回答的问题，补不了话", name(job)));
                    }
                };
                agent.steers.send(message).map_err(|_| over(job))?;
                Ok(Reply::Job(job))
            }
            Request::Cancel { job } => {
                self.jobs.running.remove(&job).ok_or_else(|| over(job))?;
                info!(conversation = %self.place.conversation, job, "a job is cancelled");
                Ok(Reply::Job(job))
            }
            Request::Status { job } => {
                let jobs: Vec<Status> = self
                    .jobs
                    .running
                    .iter()
                    .filter(|(number, _)| job.is_none_or(|job| job == **number))
                    .map(|(number, running)| {
                        let progress = running.progress();
                        Status {
                            job: name(*number),
                            title: running.title.clone(),
                            minutes: running.started.elapsed().as_secs() / 60,
                            calls: progress.calls,
                            tools: progress.tools,
                            tool: progress.tool,
                        }
                    })
                    .collect();
                if let Some(job) = job
                    && jobs.is_empty()
                {
                    return Err(over(job));
                }
                Ok(Reply::Running(jobs))
            }
        }
    }

    fn start_job(
        &mut self,
        task: String,
        title: Option<String>,
        workdir: String,
    ) -> Result<Reply, String> {
        if self.stopping.is_some() {
            return Err("Max 正在重启，起不了新的后台 agent".to_owned());
        }
        if self.jobs.agents() >= limits::JOBS_AT_ONCE {
            return Err(format!(
                "已经有 {} 个后台 agent 在跑了，等一个做完，或者停掉一个",
                limits::JOBS_AT_ONCE
            ));
        }
        let upstream = match self.shared.models.job() {
            None => return Err("没配后台 agent 用的模型".to_owned()),
            Some(Err(error)) => {
                warn!(%error, "no model for jobs");
                return Err("后台 agent 的模型配置有问题".to_owned());
            }
            Some(Ok(upstream)) => Arc::new(upstream),
        };
        let Some(vms) = self.shared.vms.clone() else {
            return Err("这里没有 VM，后台 agent 没地方跑".to_owned());
        };
        self.jobs.last += 1;
        let number = self.jobs.last;
        let title = title
            .map(|title| title.trim().to_owned())
            .filter(|title| !title.is_empty())
            .unwrap_or_else(|| headline(&task));
        let (called, calls) = unbounded_channel();
        let (hooks, hooked) = unbounded_channel();
        let stop = CancellationToken::new();
        let context = mcp::Context {
            services: Arc::clone(&self.shared.services),
            place: Arc::clone(&self.place),
            page_tokens: Budgets::for_window(upstream.window).single,
            video: false,
            work: None,
            call_time: self.call_time(),
            caller: mcp::Caller::Job(Arc::new(job::Link {
                upstream: Arc::clone(&upstream),
                called,
                hooks,
                stop: stop.clone(),
            })),
        };
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
                    job: number,
                    question,
                });
            }),
        };
        let mailbox = self.mailbox.clone();
        let mut task = Scope::new();
        task.spawn(move |_| async move {
            let finished = job::run(start, steered).await;
            let _ = mailbox.send(Event::JobDone {
                job: number,
                finished,
            });
        });
        self.jobs.running.insert(
            number,
            Running {
                title,
                started: Instant::now(),
                kind: Kind::Agent(Agent { steers, progress }),
                _task: task,
            },
        );
        Ok(Reply::Job(number))
    }

    /// Runs a `shell` command in the background, as a job of its own.
    fn start_command(&mut self, shell: Background) -> Result<Reply, String> {
        self.room_for_command()?;
        let Some(vms) = self.shared.vms.clone() else {
            return Err("这里没有配 VM，shell 用不了。".to_owned());
        };
        let conversation = self.place.conversation;
        let command = shell.command.clone();
        let work = tools::background(vms, conversation, shell);
        let number = self.command_job(&command, Instant::now(), work);
        info!(conversation = %conversation, job = number, "a background command starts");
        Ok(Reply::Job(number))
    }

    /// Takes a turn's command someone waits on as a background job of its
    /// own: its number; or, without room for it, gives it back.
    pub(super) fn adopt(&mut self, moved: Box<Moved>) -> Result<u32, (String, Box<Moved>)> {
        if let Err(why) = self.room_for_command() {
            return Err((why, moved));
        }
        let (command, begun) = (moved.command.clone(), moved.begun);
        let number = self.command_job(&command, begun, tools::moved(moved));
        info!(conversation = %self.place.conversation, job = number, "a command someone waits on moves to the background");
        Ok(number)
    }

    /// Whether another background command may run now.
    fn room_for_command(&self) -> Result<(), String> {
        if self.stopping.is_some() {
            return Err("Max 正在重启，起不了后台命令".to_owned());
        }
        let most = self.commands_at_once();
        if self.jobs.commands() >= most {
            return Err(format!(
                "已经有 {most} 个后台命令在跑了，等一个跑完，或者用 agent_cancel 停掉一个"
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
        self.jobs.last += 1;
        let number = self.jobs.last;
        let mailbox = self.mailbox.clone();
        let mut task = Scope::new();
        task.spawn(move |_| async move {
            let finished = work.await;
            let _ = mailbox.send(Event::JobDone {
                job: number,
                finished,
            });
        });
        let running = Running {
            title: format!("$ {}", headline(command)),
            started,
            kind: Kind::Command,
            _task: task,
        };
        self.jobs.running.insert(number, running);
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
        self.jobs.last += 1;
        let number = self.jobs.last;
        let mailbox = self.mailbox.clone();
        let mut task = Scope::new();
        task.spawn(move |_| async move {
            let answer = match tokio::time::timeout(limits::JOB_TIME, answered).await {
                Ok(Ok(answer)) => answer,
                // The question was dropped on its way, or with the actor
                // that held it.
                Ok(Err(_)) => Err("那边的 Max 没回答就停了".to_owned()),
                Err(_) => Err(format!(
                    "等了 {} 小时没有回答",
                    limits::JOB_TIME.as_secs() / 3600
                )),
            };
            let _ = mailbox.send(Event::Answered {
                job: number,
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
        self.jobs.running.insert(number, running);
        number
    }

    /// Ends the wait of question job `job`: whom it was put to, and the
    /// question. None if it was withdrawn since.
    pub(super) fn question_over(&mut self, job: u32) -> Option<(Peer, String)> {
        let running = self.jobs.running.get(&job)?;
        if !matches!(running.kind, Kind::Question { .. }) {
            return None;
        }
        match self.jobs.running.remove(&job)?.kind {
            Kind::Question { to, question } => Some((to, question)),
            Kind::Agent(_) | Kind::Command => None,
        }
    }

    /// A job asks Max: its question wakes Max, who answers with
    /// `agent_steer`.
    pub(super) async fn job_asks(&mut self, job: u32, question: String) -> Result<()> {
        // Cancelled since.
        let Some(running) = self.jobs.running.get(&job) else {
            return Ok(());
        };
        info!(conversation = %self.place.conversation, job, "a job asks Max");
        let item = asked(job, &running.title, &question, self.single());
        self.wake_for(job, item).await
    }

    /// A job ended: Max hears how, in the running core or a new one.
    pub(super) async fn job_done(&mut self, job: u32, finished: Finished) -> Result<()> {
        // Cancelled since.
        let Some(running) = self.jobs.running.remove(&job) else {
            return Ok(());
        };
        info!(conversation = %self.place.conversation, job, how = ?finished.ending.how, "a job ends");
        let item = report(job, &running.title, &finished, self.single());
        self.wake_for(job, item).await
    }

    /// Wakes Max with what job `job` says: in the running core, or a new
    /// one.
    async fn wake_for(&mut self, job: u32, item: Item) -> Result<()> {
        self.wake_with(Reason::Job { job }, item).await
    }

    /// Stops every job, for `/kill`: their numbers.
    pub(super) fn cancel_jobs(&mut self) -> Vec<u32> {
        let jobs = std::mem::take(&mut self.jobs.running);
        jobs.into_keys().collect()
    }

    /// A line a job, for `/status`.
    pub(super) fn job_lines(&self) -> Vec<String> {
        self.jobs
            .running
            .iter()
            .map(|(number, running)| {
                let what = match &running.kind {
                    Kind::Agent(_) => format!("{} calls", running.progress().calls),
                    Kind::Command => "shell".to_owned(),
                    Kind::Question { .. } => "ask".to_owned(),
                };
                format!(
                    "{} · {}m · {what} · {}",
                    name(*number),
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
        self.last += 1;
        let running = Running {
            title: title.to_owned(),
            started: Instant::now(),
            kind: Kind::Agent(Agent {
                steers,
                progress: Arc::default(),
            }),
            _task: Scope::new(),
        };
        self.running.insert(self.last, running);
        steered
    }
}

#[cfg(test)]
impl Jobs {
    /// A background command as if started, with nothing behind it.
    pub(super) fn pretend_command(&mut self, title: &str) {
        self.last += 1;
        let running = Running {
            title: title.to_owned(),
            started: Instant::now(),
            kind: Kind::Command,
            _task: Scope::new(),
        };
        self.running.insert(self.last, running);
    }
}

impl Jobs {
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

fn over(job: u32) -> String {
    format!("{} 不在跑了：做完了、停掉了，或者没有这个", name(job))
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

/// What Max is shown when job `job` ends: how, and the agent's last words,
/// cut to an excerpt over `single` tokens; the full text is in the file.
fn report(job: u32, title: &str, finished: &Finished, single: u32) -> Item {
    let mut text = match &finished.ending.how {
        How::Done => format!("[{} 完成] {title}", name(job)),
        // Whether a command stopped is in its text: the guest may not have
        // said so.
        How::OutOfTime => format!("[{} 到点了，下面是做到一半的] {title}", name(job)),
        How::Failed(why) => format!("[{} 失败] {title}：{why}", name(job)),
    };
    let words = finished
        .ending
        .text
        .as_deref()
        .map(str::trim)
        .filter(|words| !words.is_empty());
    match words {
        Some(words) => {
            text.push('\n');
            text.push_str(&fitted(words, single));
        }
        // pi's session is there too, as JSONL.
        None if !matches!(finished.ending.how, How::Failed(_)) => {
            text += "\n（它没留下报告；做的过程在 /work/.max/jobs 里它的会话记录）";
        }
        None => {}
    }
    if let Some(file) = &finished.file {
        let _ = write!(text, "\n（全文在 {file}）");
    }
    match finished.ending.unsent {
        0 => {}
        1 => text += "\n（你最后补充的那条它没收到）",
        unsent => {
            let _ = write!(text, "\n（你最后补充的 {unsent} 条它没收到）");
        }
    }
    let tokens = tokens::count(&text);
    Item::new(ItemKind::user(text), tokens)
}

/// What Max is shown when job `job` asks `question`, cut to an excerpt
/// over `single` tokens.
fn asked(job: u32, title: &str, question: &str, single: u32) -> Item {
    let text = format!(
        "[{} 问] {title}\n{}\n（它在等你答复：用 agent_steer 回答它，{} 分钟内没答复它就自己判断）",
        name(job),
        fitted(question.trim(), single),
        limits::QUESTION_WAIT.as_secs() / 60,
    );
    let tokens = tokens::count(&text);
    Item::new(ItemKind::user(text), tokens)
}

/// `words`, or their beginning if they take over `single` tokens.
pub(super) fn fitted(words: &str, single: u32) -> Cow<'_, str> {
    if tokens::count(words) > single {
        excerpt(words).into()
    } else {
        words.into()
    }
}

/// The beginning of `words`, saying so.
pub(super) fn excerpt(words: &str) -> String {
    let end = words
        .char_indices()
        .nth(EXCERPT_CHARS)
        .map_or(words.len(), |(at, _)| at);
    format!("{}…（太长，只有开头）", &words[..end])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::job::Ending;

    fn finished(how: How, text: Option<&str>, file: Option<&str>) -> Finished {
        Finished {
            ending: Ending {
                how,
                text: text.map(str::to_owned),
                unsent: 0,
            },
            file: file.map(str::to_owned),
        }
    }

    fn shown(item: &Item) -> &str {
        match &item.kind {
            ItemKind::User { text, .. } => text,
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_report_says_how_the_job_ended() {
        let done = finished(
            How::Done,
            Some("结论：能。\n"),
            Some("/work/.max/jobs/job-3.md"),
        );
        assert_eq!(
            shown(&report(3, "查票价", &done, 2000)),
            "[job#3 完成] 查票价\n结论：能。\n（全文在 /work/.max/jobs/job-3.md）"
        );
        let half = finished(How::OutOfTime, Some("查了一半"), None);
        assert_eq!(
            shown(&report(3, "查票价", &half, 2000)),
            "[job#3 到点了，下面是做到一半的] 查票价\n查了一半"
        );
        let failed = finished(How::Failed("429".into()), None, None);
        assert_eq!(
            shown(&report(3, "查票价", &failed, 2000)),
            "[job#3 失败] 查票价：429"
        );
        let silent = finished(How::Done, Some("  "), None);
        assert_eq!(
            shown(&report(3, "查票价", &silent, 2000)),
            "[job#3 完成] 查票价\n（它没留下报告；做的过程在 /work/.max/jobs 里它的会话记录）"
        );
        let cut = finished(How::OutOfTime, None, None);
        assert!(shown(&report(3, "查票价", &cut, 2000)).ends_with("它的会话记录）"));
        let mut late = finished(How::Done, Some("好了"), None);
        late.ending.unsent = 2;
        assert_eq!(
            shown(&report(3, "查票价", &late, 2000)),
            "[job#3 完成] 查票价\n好了\n（你最后补充的 2 条它没收到）"
        );
    }

    #[test]
    fn a_long_report_shows_its_beginning() {
        let long = "长".repeat(EXCERPT_CHARS * 3);
        let done = finished(How::Done, Some(&long), Some("/work/.max/jobs/job-3.md"));
        let text = shown(&report(3, "查票价", &done, 2000)).to_owned();
        assert!(text.contains("长…（太长，只有开头）\n（全文在 /work/.max/jobs/job-3.md）"));
        let (excerpt, _) = text.split_once('…').unwrap();
        assert_eq!(
            excerpt.chars().filter(|c| *c == '长').count(),
            EXCERPT_CHARS
        );
    }

    #[test]
    fn a_title_defaults_to_the_tasks_first_line() {
        assert_eq!(headline("  查一下明天的天气\n背景：……"), "查一下明天的天气");
        let long = "字".repeat(40);
        assert_eq!(headline(&long), format!("{}…", "字".repeat(30)));
    }
}
