//! A conversation's actor: the one writer of its timeline and the driver
//! of its core. See "The conversation actor" in docs/rust-rewrite.md.

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
use std::sync::Arc;

use max_core::ids::{CallId, ConversationId, EndpointId, MessageId, TurnId};
use max_core::intent::Verdict;
use max_core::item::{ModelOutput, Timing, ToolOutput};
use max_core::message::{Draft, Message, Platform};
use max_core::segment::Segment;
use max_db::platform::{Account, ConversationKind};
use tokio::sync::mpsc::UnboundedSender;
use tokio::sync::{broadcast, oneshot};

pub use actor::{Conversation, Outgoing, Shared};

use crate::inbound::Inbound;
use crate::job;
use crate::mcp;
use crate::tools::Moved;

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
    /// A tool asks about the background agents.
    Jobs {
        request: job::Request,
        /// The turn it comes from, if any.
        origin: Option<TurnId>,
        reply: oneshot::Sender<Result<job::Reply, String>>,
    },
    /// A turn's command someone waits on moves to the background: the
    /// actor takes it as a job, its number, or gives it back with why not.
    Move {
        moved: Box<Moved>,
        origin: Option<TurnId>,
        reply: oneshot::Sender<Result<u32, (String, Box<Moved>)>>,
    },
    /// A background agent asks Max, and waits for the answer.
    JobAsks {
        job: u32,
        question: String,
    },
    /// A background agent ended.
    JobDone {
        job: u32,
        finished: job::Finished,
    },
    /// A program in the group's VM runs `max-wake`, and waits to hear
    /// whether Max was woken.
    Woken {
        text: String,
        reply: oneshot::Sender<Result<String, String>>,
    },
    /// The VM service has something to say about the group's VM.
    VmNotice(String),
    /// A program Max keeps in the group's VM calls a tool, outside any
    /// turn, and waits for the result.
    Call {
        tool: String,
        args: serde_json::Value,
        reply: oneshot::Sender<Result<serde_json::Value, mcp::Failure>>,
    },
    /// A program in the group's VM follows the timeline: `maxx events`.
    Subscribe(oneshot::Sender<Subscription>),
    /// Max restarts: end the core, within a grace, then stop.
    Stop,
}

/// The timeline from `head` on, for a program in the group's VM: every
/// row committed after it comes to `rows`, until the actor stops. The rows
/// up to `head` are in the database.
pub struct Subscription {
    pub place: Arc<Place>,
    pub head: MessageId,
    pub rows: broadcast::Receiver<Arc<Message>>,
    pub services: Arc<mcp::Services>,
}

impl fmt::Debug for Subscription {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Subscription")
            .field("conversation", &self.place.conversation)
            .field("head", &self.head)
            .finish_non_exhaustive()
    }
}

/// What Max says or does that isn't the model's text: committed by the
/// actor and sent like a segment. See "Sending via `Post`".
#[derive(Debug)]
pub struct Post {
    pub act: Act,
    /// The turn it comes from: the row's turn. None from a program Max
    /// keeps in the group's VM, outside any turn.
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

/// Something handed to the conversation to say or do, on its way.
pub struct Sending(oneshot::Receiver<Result<MessageId, String>>);

impl Sending {
    /// Waits until it is sent: the row, or why it didn't go out.
    pub async fn sent(self) -> Result<MessageId, String> {
        self.0.await.map_err(|_| "没等到发送的结果".to_owned())?
    }
}

/// Lets a tool act in its conversation: say something, or run a
/// background agent, for its turn, or for a program Max keeps in the
/// group's VM.
#[derive(Clone, Debug)]
pub struct Poster {
    mailbox: UnboundedSender<Event>,
    /// None for a program's.
    origin: Option<TurnId>,
}

impl Poster {
    pub fn new(mailbox: UnboundedSender<Event>, origin: TurnId) -> Self {
        Self {
            mailbox,
            origin: Some(origin),
        }
    }

    /// For a program Max keeps in the group's VM.
    pub fn program(mailbox: UnboundedSender<Event>) -> Self {
        Self {
            mailbox,
            origin: None,
        }
    }

    /// Wakes Max with a program's `text`: what the program is told, or
    /// why not.
    pub async fn wake(&self, text: String) -> Result<String, String> {
        let (reply, answer) = oneshot::channel();
        self.mailbox
            .send(Event::Woken { text, reply })
            .map_err(|_| "这个群的会话已经停了".to_owned())?;
        answer.await.map_err(|_| "没等到回答".to_owned())?
    }

    /// Says `draft`, and waits until it is sent.
    pub async fn post(&self, draft: Draft) -> Result<MessageId, String> {
        self.say(draft)?.sent().await
    }

    /// Hands `draft` to the conversation, which says it whether or not
    /// anyone waits: what comes back is how the sending went.
    pub fn say(&self, draft: Draft) -> Result<Sending, String> {
        self.act(Act::Say(draft))
    }

    /// Takes back `target`, and waits until the platform has.
    pub async fn unsend(&self, target: MessageId) -> Result<MessageId, String> {
        self.act(Act::Unsend(target))?.sent().await
    }

    /// Asks the conversation about its background agents: the answer, or
    /// why not.
    pub async fn jobs(&self, request: job::Request) -> Result<job::Reply, String> {
        let (reply, answer) = oneshot::channel();
        self.mailbox
            .send(Event::Jobs {
                request,
                origin: self.origin,
                reply,
            })
            .map_err(|_| "这个群的会话已经停了".to_owned())?;
        answer.await.map_err(|_| "没等到回答".to_owned())?
    }

    /// Hands a turn's command to the conversation as a background job:
    /// its number; or why not, with the command back, unless the
    /// conversation is gone with it.
    pub async fn adopt(&self, moved: Box<Moved>) -> Result<u32, (String, Option<Box<Moved>>)> {
        let (reply, answer) = oneshot::channel();
        let gone = || ("这个群的会话已经停了".to_owned(), None);
        self.mailbox
            .send(Event::Move {
                moved,
                origin: self.origin,
                reply,
            })
            .map_err(|_| gone())?;
        match answer.await {
            Ok(Ok(job)) => Ok(job),
            Ok(Err((why, moved))) => Err((why, Some(moved))),
            Err(_) => Err(gone()),
        }
    }

    fn act(&self, act: Act) -> Result<Sending, String> {
        let (receipt, sent) = oneshot::channel();
        let post = Post {
            act,
            origin: self.origin,
            receipt: Some(receipt),
        };
        self.mailbox
            .send(Event::Post(post))
            .map_err(|_| "这个群的会话已经停了".to_owned())?;
        Ok(Sending(sent))
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
