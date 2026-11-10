//! `agent`, `agent_steer`, `agent_cancel` and `agent_status`: the
//! background agents, which the conversation's actor keeps. See "Background
//! agents" in docs/rust-rewrite.md.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::tool::Tool;
use super::{Context, Failure};
use crate::conversation::Poster;
use crate::job;
use crate::tools::guest_dir;
use max_core::limits;

/// A title's most characters.
const TITLE: usize = 40;

pub struct Agent;
pub struct AgentSteer;
pub struct AgentCancel;
pub struct AgentStatus;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Start {
    #[schemars(
        length(min = 1),
        description = "what it is to do, with the background, in full"
    )]
    task: String,
    #[schemars(length(max = TITLE), description = "a title in one line")]
    title: Option<String>,
    #[schemars(
        length(min = 1),
        description = "the directory it starts in, /work by default: an absolute path, or one relative to /work; made if it isn't there"
    )]
    workdir: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Steer {
    #[schemars(description = "job#3 or 3")]
    job: Job,
    #[schemars(length(min = 1))]
    message: String,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Which {
    #[schemars(description = "job#3 or 3")]
    job: Job,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Status {
    #[schemars(description = "job#3 or 3; left out, every job")]
    job: Option<Job>,
}

/// `job#3`, `3` or 3.
#[derive(Deserialize, JsonSchema)]
#[serde(untagged)]
enum Job {
    Text(String),
    Number(u32),
}

/// The job a request was about.
#[derive(Serialize, JsonSchema)]
pub struct Named {
    job: String,
}

#[derive(Serialize, JsonSchema)]
pub struct Running {
    jobs: Vec<job::Status>,
}

impl Tool for Agent {
    const NAME: &'static str = "agent";
    const DESCRIPTION: &'static str = "Hands a background agent something that takes time, and returns its job number at once; when it is done, its report comes back to you as [job#N 完成].";
    const JOB: bool = false;

    type Args = Start;
    type Output = Named;

    fn guide() -> String {
        format!(
            "Starts a background agent on something that takes time: looking up a pile of sources, reading many pages or files, writing code and running experiments. It runs in this chat's VM and shares /work with you; it has its own shell, file reading and writing, history and web_search; it can't speak in the chat, nor send pictures or files, recall or mute.\n  \
            It doesn't see the conversation, only task: so put in the background, what to do, how far to take it, and what the report should say. title is a one-line title, shown by agent_status.\n  \
            workdir is the directory it starts in, /work by default: an absolute path, or one relative to /work; made if it isn't there. For work on a project give the project's path: it reads the project's AGENTS.md (or CLAUDE.md) and the notes background agents keep for that directory (under /work/.max/projects/), and updates the notes when done.\n  \
            Returns {{ job: \"job#3\" }} at once, and you go on talking. Stuck on something only you or the people here know, it asks you: the question appears as [job#3 问], it waits, and you answer with agent_steer. When it is done, its report appears among your new messages as [job#3 完成], the whole of it saved under /work/.max/jobs/, and what to say of it in the chat is yours to decide. At most {} at once, each for at most {} hours; at its time it stops and hands over what it has.",
            limits::JOBS_AT_ONCE,
            limits::JOB_TIME.as_secs() / 3600,
        )
    }

    async fn run(
        context: &Context,
        Start {
            task,
            title,
            workdir: dir,
        }: Start,
    ) -> Result<Named, Failure> {
        if task.trim().is_empty() {
            return Err(Failure::new("bad_arguments", "task is empty"));
        }
        let workdir = workdir(dir.as_deref())?;
        let started = conversation(context)?.agent(task, title, workdir).await;
        started.map(named).map_err(failed)
    }
}

impl Tool for AgentSteer {
    const NAME: &'static str = "agent_steer";
    const DESCRIPTION: &'static str = "Tells a running background agent something more: a change of direction, more information, or the answer to its [job#N 问].";
    const JOB: bool = false;

    type Args = Steer;
    type Output = Named;

    fn guide() -> String {
        format!(
            "Tells a running background agent something more: a change of direction, more information, what someone here answered. It sees it after the tool call it is on, before it next thinks. job is \"job#3\" or 3.\n  \
            While it waits on a question it asked you ([job#3 问]), your next message is the answer, and it gets it at once. If you can't answer, ask in the chat and pass on what you hear; with no answer in {} minutes it goes on by its own judgement, and what you say later is taken as more information.",
            limits::QUESTION_WAIT.as_secs() / 60,
        )
    }

    async fn run(context: &Context, Steer { job, message }: Steer) -> Result<Named, Failure> {
        if message.trim().is_empty() {
            return Err(Failure::new("bad_arguments", "message is empty"));
        }
        let job = job.number()?;
        let steered = conversation(context)?.steer(job, message).await;
        steered.map(|()| named(job)).map_err(failed)
    }
}

impl Tool for AgentCancel {
    const NAME: &'static str = "agent_cancel";
    const DESCRIPTION: &'static str = "Stops a background agent or command whose result isn't wanted any more; or withdraws an ask that hasn't been answered.";
    const JOB: bool = false;

    type Args = Which;
    type Output = Named;

    fn guide() -> String {
        "Stops a background agent, or a background command of shell's, whose result isn't wanted any more; what it left in /work stays. Also withdraws an ask still waiting for its answer: an answer given there afterwards finds nobody."
            .into()
    }

    async fn run(context: &Context, Which { job }: Which) -> Result<Named, Failure> {
        let job = job.number()?;
        let cancelled = conversation(context)?.cancel(job).await;
        cancelled.map(|()| named(job)).map_err(failed)
    }
}

impl Tool for AgentStatus {
    const NAME: &'static str = "agent_status";
    const DESCRIPTION: &'static str = "Shows the background agents and commands that run and the asks still waiting: title, minutes run, model and tool calls made, and the tool last used.";
    const JOB: bool = false;

    type Args = Status;
    type Output = Running;

    fn guide() -> String {
        "Shows the background agents and commands that run: title, minutes run, model calls (calls) and tool calls (tools) made, and the tool last used. A background command's title is $ and the command, with both counts 0; an ask still waiting for another conversation's answer is there too, its title ? with the conversation and the question, counts 0 as well. Without job, all of them; those done or stopped aren't listed.".into()
    }

    async fn run(context: &Context, Status { job }: Status) -> Result<Running, Failure> {
        let job = job.map(Job::number).transpose()?;
        let running = conversation(context)?.status(job).await;
        running.map(|jobs| Running { jobs }).map_err(failed)
    }
}

impl Job {
    fn number(self) -> Result<u32, Failure> {
        match self {
            Job::Number(number) => Ok(number),
            Job::Text(text) => {
                let digits = text.trim().trim_start_matches("job#");
                digits.parse().map_err(|_| {
                    Failure::new(
                        "bad_arguments",
                        format!("{text} isn't a job's number: write job#3 or 3"),
                    )
                })
            }
        }
    }
}

/// The agent's directory in the guest, as `shell` reads it; it names the
/// agent's notes too, so not blank, nor with control characters.
fn workdir(dir: Option<&str>) -> Result<String, Failure> {
    if dir.is_some_and(|dir| dir.trim().is_empty() || dir.chars().any(char::is_control)) {
        return Err(Failure::new(
            "bad_arguments",
            "workdir can't be empty, nor have control characters",
        ));
    }
    Ok(guest_dir(dir))
}

fn named(job: u32) -> Named {
    Named {
        job: job::name(job),
    }
}

/// The conversation whose jobs these are. Only a turn's programs, and
/// those Max keeps in the VM, have one at hand.
fn conversation(context: &Context) -> Result<&Poster, Failure> {
    let here = context.caller.poster();
    here.ok_or_else(|| {
        Failure::new(
            "not_here",
            "there are no background jobs to manage from here",
        )
    })
}

fn failed(message: String) -> Failure {
    Failure::new("job", message)
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::*;

    #[test]
    fn a_start_may_name_its_directory() {
        let dir = |value: Value| {
            let start: Start = serde_json::from_value(value).unwrap();
            workdir(start.workdir.as_deref()).unwrap()
        };
        assert_eq!(dir(json!({ "task": "查票价" })), "/work");
        assert_eq!(dir(json!({ "task": "查票价", "workdir": null })), "/work");
        assert_eq!(
            dir(json!({ "task": "跑测试", "workdir": "max" })),
            "/work/max"
        );
        assert_eq!(
            dir(json!({ "task": "跑测试", "workdir": "/tmp/x" })),
            "/tmp/x"
        );
        assert!(
            serde_json::from_value::<Start>(json!({ "task": "跑测试", "workdir": 3 })).is_err()
        );
        for dir in ["", "  ", "/work/\0max", "max\nother", "max\r", "max\t"] {
            assert_eq!(
                workdir(Some(dir)).unwrap_err().code,
                "bad_arguments",
                "{dir:?}"
            );
        }
    }

    #[test]
    fn a_job_is_named_either_way() {
        let job = |value: Value| serde_json::from_value::<Job>(value).unwrap().number();
        assert_eq!(job(json!("job#3")).unwrap(), 3);
        assert_eq!(job(json!(" 3 ")).unwrap(), 3);
        assert_eq!(job(json!(3)).unwrap(), 3);
        assert_eq!(job(json!("三")).unwrap_err().code, "bad_arguments");
    }
}
