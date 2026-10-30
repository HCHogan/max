//! A conversation's actor: the one writer of its timeline and the driver
//! of its core. See "会话 actor" in docs/rust-rewrite.md.

mod actor;
pub mod classify;
pub mod ingest;
pub mod model;
pub mod project;
mod report;
#[cfg(test)]
pub(crate) mod testing;
mod tool;

use std::fmt;

use max_core::ids::{CallId, ConversationId, EndpointId, MessageId, TurnId};
use max_core::intent::Verdict;
use max_core::item::{ModelOutput, Timing, ToolOutput};
use max_core::message::{Draft, Platform};
use max_core::segment::Segment;
use max_db::platform::{Account, ConversationKind};
use tokio::sync::mpsc::UnboundedSender;
use tokio::sync::oneshot;

pub use actor::{Conversation, Outgoing, Shared};

use crate::historian::Compacted;
use crate::inbound::Inbound;
use crate::job;

/// What arrives in an actor's mailbox: everything that happens to a
/// conversation, in the order the actor handles it.
#[derive(Debug)]
pub enum Event {
    Inbound(Inbound),
    /// The `/bind <码>` that just bound this group, from the table.
    Bound(Inbound),
    /// Something to say or do that isn't the model's text, such as a
    /// tool's picture or recall.
    Post(Post),
    /// The model call's segmenter cut a message out of the stream.
    Said {
        task: TaskId,
        segment: Segment,
    },
    /// The model call ended. An error once something was said is not
    /// retried.
    ModelDone {
        task: TaskId,
        out: Result<(ModelOutput, Timing), String>,
    },
    ToolDone {
        task: TaskId,
        call: CallId,
        out: ToolOutput,
    },
    /// The classifier's answer; None if it failed.
    Verdict(Option<Verdict>),
    /// How the historian's `/compact` went, to answer the command.
    Compacted(Compacted),
    /// A tool asks about the background agents.
    Jobs {
        request: job::Request,
        /// The turn it comes from, if any.
        origin: Option<TurnId>,
        reply: oneshot::Sender<Result<job::Reply, String>>,
    },
    /// A background agent ended.
    JobDone {
        job: u32,
        finished: job::Finished,
    },
    /// Max restarts: end the core, within a grace, then stop.
    Stop,
}

/// What Max says or does that isn't the model's text: committed by the
/// actor and sent like a segment. See "经 `Post` 发".
#[derive(Debug)]
pub struct Post {
    pub act: Act,
    /// The turn it comes from, if any: the row's turn.
    pub origin: Option<TurnId>,
    /// Told how the sending went.
    pub receipt: Option<Receipt>,
}

#[derive(Debug)]
pub enum Act {
    Say(Draft),
    /// Take back an earlier message of the timeline.
    Unsend(MessageId),
}

/// Where the sender says how a row's sending went: the row, or why it
/// didn't go out.
pub type Receipt = oneshot::Sender<Result<MessageId, String>>;

/// Lets a tool act in its turn's conversation: say something, or run a
/// background agent.
#[derive(Clone, Debug)]
pub struct Poster {
    mailbox: UnboundedSender<Event>,
    origin: TurnId,
}

impl Poster {
    pub fn new(mailbox: UnboundedSender<Event>, origin: TurnId) -> Self {
        Self { mailbox, origin }
    }

    /// Says `draft`, and waits until it is sent.
    pub async fn post(&self, draft: Draft) -> Result<MessageId, String> {
        self.act(Act::Say(draft)).await
    }

    /// Takes back `target`, and waits until the platform has.
    pub async fn unsend(&self, target: MessageId) -> Result<MessageId, String> {
        self.act(Act::Unsend(target)).await
    }

    /// Asks the conversation about its background agents: the answer, or
    /// why not.
    pub async fn jobs(&self, request: job::Request) -> Result<job::Reply, String> {
        let (reply, answer) = oneshot::channel();
        self.mailbox
            .send(Event::Jobs {
                request,
                origin: Some(self.origin),
                reply,
            })
            .map_err(|_| "这个群的会话已经停了".to_owned())?;
        answer.await.map_err(|_| "没等到回答".to_owned())?
    }

    async fn act(&self, act: Act) -> Result<MessageId, String> {
        let (receipt, sent) = oneshot::channel();
        let post = Post {
            act,
            origin: Some(self.origin),
            receipt: Some(receipt),
        };
        self.mailbox
            .send(Event::Post(post))
            .map_err(|_| "这个群的会话已经停了".to_owned())?;
        sent.await.map_err(|_| "没等到发送的结果".to_owned())?
    }
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
