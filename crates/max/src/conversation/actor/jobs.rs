//! The conversation's background agents: started by its turns' programs,
//! outliving the core that started them, and waking Max when they end.
//! See "后台 agent" in docs/rust-rewrite.md.

use std::collections::BTreeMap;
use std::sync::{Mutex, PoisonError};

use max_core::item::Item;
use max_core::render::EXCERPT_CHARS;
use tokio::sync::mpsc::unbounded_channel;

use super::*;
use crate::job::{self, Finished, How, Progress, Reply, Request, Status, name};

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
    steers: UnboundedSender<String>,
    progress: Arc<Mutex<Progress>>,
    /// Dropping it stops the job, and pi with it.
    _task: Scope,
}

impl Conversation {
    /// Answers a tool's request: what the program gets, or why not.
    pub(super) fn job_request(&mut self, request: Request) -> Result<Reply, String> {
        match request {
            Request::Start { task, title } => self.start_job(task, title),
            Request::Steer { job, message } => {
                let running = self.jobs.running.get(&job).ok_or_else(|| over(job))?;
                running.steers.send(message).map_err(|_| over(job))?;
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
                            tool: progress.tool.clone(),
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

    fn start_job(&mut self, task: String, title: Option<String>) -> Result<Reply, String> {
        if self.stopping.is_some() {
            return Err("Max 正在重启，起不了新的后台 agent".to_owned());
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
        if self.jobs.running.len() >= job::MOST {
            return Err(format!(
                "已经有 {} 个后台 agent 在跑了，等一个做完，或者停掉一个",
                job::MOST
            ));
        }
        self.jobs.last += 1;
        let number = self.jobs.last;
        let title = title
            .map(|title| title.trim().to_owned())
            .filter(|title| !title.is_empty())
            .unwrap_or_else(|| headline(&task));
        let context = mcp::Context {
            services: Arc::clone(&self.shared.services),
            place: Arc::clone(&self.place),
            page_tokens: Budgets::for_window(upstream.window).single,
            work: None,
            caller: mcp::Caller::Job(Arc::clone(&upstream)),
        };
        let (steers, steered) = unbounded_channel();
        let progress = Arc::<Mutex<Progress>>::default();
        let start = job::Start {
            number,
            title: title.clone(),
            task,
            vms,
            context,
            upstream,
            deadline: Instant::now() + job::TIME,
            progress: Arc::clone(&progress),
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
                steers,
                progress,
                _task: task,
            },
        );
        Ok(Reply::Job(number))
    }

    /// A job ended: Max hears how, in the running core or a new one.
    pub(super) async fn job_done(&mut self, job: u32, finished: Finished) -> Result<()> {
        // Cancelled since.
        let Some(running) = self.jobs.running.remove(&job) else {
            return Ok(());
        };
        info!(conversation = %self.place.conversation, job, how = ?finished.ending.how, "a job ends");
        let wake = Wake {
            ids: Vec::new(),
            reason: Reason::Job { job },
            item: Some(report(job, &running.title, &finished, self.single())),
        };
        match self.core.as_mut() {
            Some(a) => {
                if let Err(rejected) = a.run.input(Input::Wake(wake)) {
                    warn!(turn = %a.turn, %rejected, "a job's report didn't fit the core");
                }
            }
            None => self.start_core(wake).await?,
        }
        Ok(())
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
                let progress = running.progress();
                format!(
                    "{} · {}m · {} calls · {}",
                    name(*number),
                    running.started.elapsed().as_secs() / 60,
                    progress.calls,
                    running.title
                )
            })
            .collect()
    }

    /// The most tokens one item may take: the running core's, or the
    /// next one's.
    fn single(&self) -> u32 {
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
            steers,
            progress: Arc::default(),
            _task: Scope::new(),
        };
        self.running.insert(self.last, running);
        steered
    }
}

impl Running {
    fn progress(&self) -> std::sync::MutexGuard<'_, Progress> {
        self.progress.lock().unwrap_or_else(PoisonError::into_inner)
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
        How::OutOfTime => format!("[{} 到点停了，下面是做到一半的] {title}", name(job)),
        How::Failed(why) => format!("[{} 失败] {title}：{why}", name(job)),
    };
    let words = finished
        .ending
        .text
        .as_deref()
        .map(str::trim)
        .filter(|words| !words.is_empty());
    match words {
        Some(words) if tokens::count(words) > single => {
            let excerpt: String = words.chars().take(EXCERPT_CHARS).collect();
            text += &format!("\n{excerpt}…（太长，只有开头）");
        }
        Some(words) => text += &format!("\n{words}"),
        // pi's session is there too, as JSONL.
        None if !matches!(finished.ending.how, How::Failed(_)) => {
            text += "\n（它没留下报告；做的过程在 /work/.max/jobs 里它的会话记录）";
        }
        None => {}
    }
    if let Some(file) = &finished.file {
        text += &format!("\n（全文在 {file}）");
    }
    let tokens = tokens::count(&text);
    Item::new(ItemKind::user(text), tokens)
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
            "[job#3 到点停了，下面是做到一半的] 查票价\n查了一半"
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
