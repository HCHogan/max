//! `agent` and `agent_steer`: the background agents, which the
//! conversation's actor keeps. `cancel` and `status`, in `jobs`, cover
//! them too. See "Background agents" in docs/rust-rewrite.md.

use max_core::ids::Handle;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::tool::Tool;
use super::{Context, Failure};
use crate::conversation::Poster;
use crate::tools::guest_dir;
use max_core::limits;

/// A title's most characters.
const TITLE: usize = 40;

pub struct Agent;
pub struct AgentSteer;

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
    #[schemars(description = "agent#3 or 3")]
    agent: Which,
    #[schemars(length(min = 1))]
    message: String,
}

/// An agent: `agent#3`, `3` or 3.
#[derive(Deserialize, JsonSchema)]
#[serde(untagged)]
enum Which {
    Text(String),
    Number(u32),
}

/// The agent a request was about.
#[derive(Serialize, JsonSchema)]
pub struct Named {
    agent: String,
}

impl Tool for Agent {
    const NAME: &'static str = "agent";
    const DESCRIPTION: &'static str = "Hands a background agent something that takes time, and returns its handle, agent#N, at once; when it is done, its report comes back to you as [agent#N 完成].";
    const JOB: bool = false;

    type Args = Start;
    type Output = Named;

    fn guide() -> String {
        format!(
            "Starts a background agent on something that takes time: looking up a pile of sources, reading many pages or files, writing code and running experiments. It runs in this chat's VM and shares /work with you; it has its own shell, file reading and writing, history and web_search; it can't speak in the chat, nor send pictures or files, recall or mute.\n  \
            It doesn't see the conversation, only task: so put in the background, what to do, how far to take it, and what the report should say. title is a one-line title, shown by status.\n  \
            workdir is the directory it starts in, /work by default: an absolute path, or one relative to /work; made if it isn't there. For work on a project give the project's path: it reads the project's AGENTS.md (or CLAUDE.md) and the notes background agents keep for that directory (under /work/.max/projects/), and updates the notes when done.\n  \
            Returns {{ agent: \"agent#3\" }} at once, and you go on talking. Stuck on something only you or the people here know, it asks you: the question appears as [agent#3 问], it waits, and you answer with agent_steer. When it is done, its report appears among your new messages as [agent#3 完成], the whole of it saved under /work/.max/jobs/, and what to say of it in the chat is yours to decide. At most {} at once, each for at most {} hours; at its time it stops and hands over what it has.",
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
    const DESCRIPTION: &'static str = "Tells a running background agent something more: a change of direction, more information, or the answer to its [agent#N 问].";
    const JOB: bool = false;

    type Args = Steer;
    type Output = Named;

    fn guide() -> String {
        format!(
            "Tells a running background agent something more: a change of direction, more information, what someone here answered. It sees it after the tool call it is on, before it next thinks. agent is \"agent#3\" or 3.\n  \
            While it waits on a question it asked you ([agent#3 问]), your next message is the answer, and it gets it at once. If you can't answer, ask in the chat and pass on what you hear; with no answer in {} minutes it goes on by its own judgement, and what you say later is taken as more information.",
            limits::QUESTION_WAIT.as_secs() / 60,
        )
    }

    async fn run(context: &Context, Steer { agent, message }: Steer) -> Result<Named, Failure> {
        if message.trim().is_empty() {
            return Err(Failure::new("bad_arguments", "message is empty"));
        }
        let agent = agent.number()?;
        let steered = conversation(context)?.steer(agent, message).await;
        steered.map(|()| named(agent)).map_err(failed)
    }
}

impl Which {
    /// The agent's number; another handle isn't an agent's.
    fn number(self) -> Result<u32, Failure> {
        let text = match self {
            Which::Number(number) => return Ok(number),
            Which::Text(text) => text,
        };
        if let Ok(number) = text.trim().parse() {
            return Ok(number);
        }
        match text.parse() {
            Ok(Handle::Agent(number)) => Ok(number),
            Ok(other) => Err(Failure::new(
                "bad_arguments",
                format!("{other} isn't an agent: only an agent can be steered"),
            )),
            Err(_) => Err(Failure::new(
                "bad_arguments",
                format!("{text} isn't an agent: write agent#3 or 3"),
            )),
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

fn named(agent: u32) -> Named {
    Named {
        agent: Handle::Agent(agent).to_string(),
    }
}

/// The conversation whose jobs these are. Only a turn's programs, and
/// those Max keeps in the VM, have one at hand.
pub(super) fn conversation(context: &Context) -> Result<&Poster, Failure> {
    let here = context.caller.poster();
    here.ok_or_else(|| {
        Failure::new(
            "not_here",
            "there are no background jobs to manage from here",
        )
    })
}

pub(super) fn failed(message: String) -> Failure {
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
    fn an_agent_is_named_either_way() {
        let agent = |value: Value| serde_json::from_value::<Which>(value).unwrap().number();
        assert_eq!(agent(json!("agent#3")).unwrap(), 3);
        assert_eq!(agent(json!(" 3 ")).unwrap(), 3);
        assert_eq!(agent(json!(3)).unwrap(), 3);
        assert_eq!(agent(json!("三")).unwrap_err().code, "bad_arguments");
        let shell = agent(json!("shell#4")).unwrap_err();
        assert_eq!(
            shell.message,
            "shell#4 isn't an agent: only an agent can be steered"
        );
    }
}
