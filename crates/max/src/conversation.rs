//! A conversation's actor: the one writer of its timeline and the driver
//! of its core. See "会话 actor" in docs/rust-rewrite.md.

mod actor;
pub mod classify;
pub mod ingest;
pub mod model;
pub mod project;
#[cfg(test)]
pub(crate) mod testing;

use std::fmt;

use max_core::ids::{CallId, ConversationId, EndpointId, MessageId};
use max_core::intent::Verdict;
use max_core::item::{ModelOutput, ToolOutput};
use max_core::message::Platform;
use max_core::segment::Segment;
use max_db::platform::{Account, ConversationKind};

pub use actor::{Conversation, Outgoing, Shared};

use crate::historian::Compacted;
use crate::inbound::Inbound;

/// What arrives in an actor's mailbox: everything that happens to a
/// conversation, in the order the actor handles it.
#[derive(Debug)]
pub enum Event {
    Inbound(Inbound),
    /// The `!bind <码>` that just bound this group, from the table.
    Bound(Inbound),
    /// The model call's segmenter cut a message out of the stream.
    Said {
        task: TaskId,
        segment: Segment,
    },
    /// The model call ended. An error once something was said is not
    /// retried.
    ModelDone {
        task: TaskId,
        out: Result<ModelOutput, String>,
    },
    ToolDone {
        task: TaskId,
        call: CallId,
        out: ToolOutput,
    },
    /// The classifier's answer; None if it failed.
    Verdict(Option<Verdict>),
    /// How the historian's `!compact` went, to answer the command.
    Compacted {
        command: MessageId,
        result: Compacted,
    },
    /// Max restarts: end the core, within a grace, then stop.
    Stop,
}

/// An I/O task, numbered within its conversation and never reused: an
/// event from a task the actor no longer waits for is dropped.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct TaskId(pub u64);

impl fmt::Display for TaskId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "task#{}", self.0)
    }
}

/// Where a conversation lives. v1 has one endpoint per conversation; the
/// mirror will make this a list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Place {
    pub conversation: ConversationId,
    pub kind: ConversationKind,
    pub endpoint: EndpointId,
    pub platform: Platform,
    /// The adapter's id for the endpoint, such as `group:<group_openid>`.
    pub native_id: String,
    /// Max's account there.
    pub me: Account,
    pub my_name: String,
}
