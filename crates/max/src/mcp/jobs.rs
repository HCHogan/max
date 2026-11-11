//! `cancel` and `status`: what runs or waits in the conversation's
//! background, by handle: agents (`agent#3`), `shell`'s commands
//! (`shell#4`) and the questions asked from here (`ask#5`). `cancel` also
//! declines a question asked of Max here.
//! See "Background agents", "Background commands" and "Asking another
//! conversation" in docs/rust-rewrite.md.

use max_core::ids::Handle;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::agent::{conversation, failed};
use super::tool::Tool;
use super::{Context, Failure};
use crate::job;

pub struct Cancel;
pub struct Status;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Which {
    #[schemars(description = "agent#3, shell#4 or ask#5")]
    handle: String,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Any {
    #[schemars(description = "agent#3, shell#4 or ask#5; left out, all of them")]
    handle: Option<String>,
}

/// What was cancelled.
#[derive(Serialize, JsonSchema)]
pub struct Cancelled {
    cancelled: String,
}

#[derive(Serialize, JsonSchema)]
pub struct Running {
    running: Vec<job::Status>,
}

impl Tool for Cancel {
    const NAME: &'static str = "cancel";
    const DESCRIPTION: &'static str = "Stops a background agent or command whose result isn't wanted any more, withdraws a question you asked that hasn't been answered, or declines one asked of you.";
    const JOB: bool = false;

    type Args = Which;
    type Output = Cancelled;

    fn guide() -> String {
        "Stops a background agent (agent#3) or a background command of shell's (shell#4) whose result isn't wanted any more: nothing comes back from it, and what it left in /work stays. Also withdraws a question you asked another conversation (ask#5) that still waits for its answer: an answer given there afterwards finds nobody. And it declines a question asked of you (ask#5, by Max in another conversation or by one of your agents) that you won't answer: whoever asked hears at once that no answer comes, as [ask#5 没答成], and an agent goes on by its own judgement."
            .into()
    }

    async fn run(context: &Context, Which { handle }: Which) -> Result<Cancelled, Failure> {
        let handle = handle_of(&handle)?;
        let cancelled = conversation(context)?.cancel(handle).await;
        cancelled.map_err(failed)?;
        Ok(Cancelled {
            cancelled: handle.to_string(),
        })
    }
}

impl Tool for Status {
    const NAME: &'static str = "status";
    const DESCRIPTION: &'static str = "Shows the background agents and commands that run, and the questions you asked that still wait: handle, title, minutes, and an agent's model and tool calls and the tool it last used.";
    const JOB: bool = false;

    type Args = Any;
    type Output = Running;

    fn guide() -> String {
        "Shows what runs in the background: agents (agent#3); commands of shell's (shell#4), titled $ and the command; and questions you asked another conversation that still wait for the answer (ask#5), titled ? with the conversation and the question. Each with its handle, title and minutes run; an agent with its model calls (calls), its tool calls (tools) and the tool it last used, the others with 0 and none. Without handle, all of them; those done, cancelled or answered aren't listed, nor are the questions asked of you."
            .into()
    }

    async fn run(context: &Context, Any { handle }: Any) -> Result<Running, Failure> {
        let handle = handle.as_deref().map(handle_of).transpose()?;
        let running = conversation(context)?.status(handle).await;
        running.map(|running| Running { running }).map_err(failed)
    }
}

fn handle_of(text: &str) -> Result<Handle, Failure> {
    text.parse().map_err(|error: max_core::ids::NotAHandle| {
        Failure::new("bad_arguments", error.to_string())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_handle_names_its_kind() {
        assert_eq!(handle_of(" shell#4").unwrap(), Handle::Shell(4));
        let bare = handle_of("3").unwrap_err();
        assert_eq!(bare.code, "bad_arguments");
        assert_eq!(
            bare.message,
            "3 isn't a handle: write agent#3, shell#4 or ask#5"
        );
    }
}
