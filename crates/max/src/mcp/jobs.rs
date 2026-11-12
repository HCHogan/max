//! `cancel` and `status`: the questions asked from here that wait for
//! their answers, by handle (`ask#5`). `cancel` also declines a question
//! asked of Max here. What runs in the VM, a background command or a
//! background agent, is a unit there, which Max lists and stops there.
//! See "Asking another conversation" in docs/rust-rewrite.md.

use max_core::ids::Handle;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::tool::Tool;
use super::{Context, Failure};
use crate::conversation::{Poster, Waits};

pub struct Cancel;
pub struct Status;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Which {
    #[schemars(description = "ask#5")]
    handle: String,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Any {
    #[schemars(description = "ask#5; left out, all of them")]
    handle: Option<String>,
}

/// What was cancelled.
#[derive(Serialize, JsonSchema)]
pub struct Cancelled {
    cancelled: String,
}

#[derive(Serialize, JsonSchema)]
pub struct Running {
    running: Vec<Waits>,
}

impl Tool for Cancel {
    const NAME: &'static str = "cancel";
    const DESCRIPTION: &'static str = "Withdraws a question you asked another conversation that hasn't been answered, or declines one asked of you.";

    type Args = Which;
    type Output = Cancelled;

    fn guide() -> String {
        "Withdraws a question you asked another conversation (ask#5) that still waits for its answer: an answer given there afterwards finds nobody. And it declines a question Max in another conversation asked of you (ask#5) that you won't answer: it hears at once that no answer comes, as [ask#5 没答成]. What runs in the VM isn't stopped with this: a background command or a background agent is a unit there, stopped with systemctl stop and its name."
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
    const DESCRIPTION: &'static str = "Shows the questions you asked another conversation that still wait for their answers: handle, title, minutes.";

    type Args = Any;
    type Output = Running;

    fn guide() -> String {
        "Shows the questions you asked another conversation that still wait for the answer (ask#5), titled ? with the conversation and the question, each with its handle, title and minutes waited. Without handle, all of them; those answered or withdrawn aren't listed, nor are the questions asked of you. What runs in the VM isn't here: max-jobs list there shows the background commands and the background agents."
            .into()
    }

    async fn run(context: &Context, Any { handle }: Any) -> Result<Running, Failure> {
        let handle = handle.as_deref().map(handle_of).transpose()?;
        let running = conversation(context)?.status(handle).await;
        running.map(|running| Running { running }).map_err(failed)
    }
}

/// The conversation whose jobs these are. Only a turn's programs, and
/// those Max keeps in the VM, have one at hand.
fn conversation(context: &Context) -> Result<&Poster, Failure> {
    let here = context.caller.poster();
    here.ok_or_else(|| Failure::new("not_here", "there are no background jobs here"))
}

fn failed(message: String) -> Failure {
    Failure::new("failed", message)
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
        assert_eq!(handle_of(" ask#4").unwrap(), Handle::Ask(4));
        let bare = handle_of("3").unwrap_err();
        assert_eq!(bare.code, "bad_arguments");
        assert_eq!(bare.message, "3 isn't a handle: write ask#5");
    }
}
