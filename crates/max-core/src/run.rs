//! The core: a sans-I/O state machine that decides what a turn does next.
//! Every method is synchronous and one complete transition; nothing here
//! awaits, spawns, reads the clock or touches the network.
//!
//! Every input method builds an [`Input`] and applies it, and the core keeps
//! the inputs. A snapshot is that log, and replaying it rebuilds the core
//! exactly. Starting a model call or a tool batch is logged too, so replay
//! knows which inputs a call saw. What the core makes up itself, such as the
//! results it fills in for cancelled calls, isn't logged; replay makes it
//! again.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::ids::{CallId, MessageId, PrincipalId, TurnId};
use crate::intent::Reason;
use crate::item::{Item, ModelOutput, ModelTag, ToolOutput};
use crate::tools::{Call, ToolSpec};

/// What a run is allowed: fixed for the turn.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunSpec {
    pub model: ModelTag,
    /// The model's context window, C.
    pub window: u32,
    /// The model's output limit; reserves C / 8 when it has none.
    pub max_output: Option<u32>,
    /// The Max tools a program may call.
    pub max_tools: Vec<String>,
}

impl RunSpec {
    /// How big transcript and waiting inputs may grow before the core is
    /// replaced: the window minus output, a 5% margin and the base context,
    /// and never more than half the window.
    pub fn limit(&self, base: u32) -> u32 {
        let c = self.window;
        let available = c
            .saturating_sub(self.max_output.unwrap_or(c / 8))
            .saturating_sub(c / 20);
        available.saturating_sub(base).min(c / 2)
    }
}

/// Projected once before the core starts, then fixed. The first inputs are
/// already rendered in it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Context {
    pub items: Vec<Item>,
    /// The people its roster shows; see [`Segmenter`].
    pub roster: BTreeSet<PrincipalId>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Input {
    /// The core started a model call.
    CalledModel,
    /// The core started the tool calls from the last model output.
    RanTools,
    ModelOutput(ModelOutput),
    /// The model call was cut off; `text` had already been said.
    PartialOutput {
        text: String,
        tokens: u32,
    },
    ToolResult {
        call: CallId,
        output: ToolOutput,
    },
    /// New rows on the timeline. Not a trigger: they wait for the next
    /// model call.
    Messages {
        ids: Vec<MessageId>,
        item: Item,
    },
    Wake(Wake),
    Interrupt {
        reason: String,
    },
    Fail {
        reason: FailReason,
    },
}

/// intent woke the core.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Wake {
    /// The rows it is about.
    pub ids: Vec<MessageId>,
    pub reason: Reason,
    /// What the model is shown, such as `[判定 followup：…]`. None for a
    /// direct trigger, whose rows are marked already.
    pub item: Option<Item>,
    /// The turn that hit its limit before handling this. A trigger is handed
    /// over once at most.
    pub handed_over: Option<TurnId>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum FailReason {
    Model {
        error: String,
    },
    /// A handed-over trigger hit the limit again.
    ContextExhausted,
    /// The first inputs alone are over the limit.
    InputTooLarge,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Outcome {
    Answered,
    Silent,
    Interrupted,
    Failed {
        reason: FailReason,
    },
    /// Suspended and not resumed in time.
    Expired,
    /// Running when the process crashed.
    Lost,
}

#[derive(Debug)]
pub enum Step {
    /// The request is complete; nothing changes it afterwards.
    CallModel(Request),
    RunTools(Vec<Call>),
    /// Nothing to do until something arrives. Whether to wait or end is the
    /// actor's call.
    Idle,
}

#[derive(Debug)]
pub struct Request {
    pub model: ModelTag,
    pub items: Vec<Item>,
    pub tools: &'static [ToolSpec],
    pub max_output: Option<u32>,
    /// For the segmenter in the model call.
    pub roster: BTreeSet<PrincipalId>,
}

/// An input that doesn't fit the core's state. It is not applied.
#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum Rejected {
    #[error("the run has ended")]
    Ended,
    #[error("a model call or tool batch is in flight")]
    Busy,
    #[error("the tool calls are due first")]
    ToolsDue,
    #[error("no tool calls are due")]
    NothingDue,
    #[error("no model call is in flight")]
    NoModelCall,
    #[error("no such tool call is in flight")]
    UnknownCall,
    #[error("only messages and wakes come in through input()")]
    NotAnInput,
}

#[cfg(test)]
mod tests;
