//! A conversation's actor: the one writer of its timeline and the driver
//! of its core. See "The conversation actor" in docs/rust-rewrite.md.

mod actor;
pub mod classify;
pub mod ingest;
pub mod model;
mod notice;
pub mod project;
mod report;
#[cfg(test)]
pub(crate) mod testing;
mod tool;

use std::fmt;
use std::sync::Arc;

use max_core::ids::{CallId, ConversationId, EndpointId, MessageId};
use max_core::intent::Verdict;
use max_core::item::{ModelOutput, Timing, ToolOutput};
use max_core::limits::Setting;
use max_core::message::{Draft, Message, Platform};
use max_core::segment::Segment;
use max_db::links::Peer;
use max_db::platform::{Account, ConversationKind};
use tokio::sync::mpsc::UnboundedSender;
use tokio::sync::{broadcast, oneshot};

pub use actor::{Conversation, Outgoing, Shared};

use crate::inbound::Inbound;
use crate::service;

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
    /// A tool asks something of the conversation, and waits for the
    /// answer.
    Request(Request),
    /// Something from outside the chat that Max is to hear.
    Heard(Heard),
    /// Something in the group's VM calls a tool, and waits for the
    /// result.
    Call {
        tool: String,
        args: serde_json::Value,
        reply: oneshot::Sender<Result<serde_json::Value, service::Failure>>,
    },
    /// A program in the group's VM follows the timeline: `maxx events`.
    Subscribe(oneshot::Sender<Subscription>),
    /// Max restarts: end the core, within a grace, then stop.
    Stop,
}

/// What goes to a conversation's actor by its conversation, whatever chat
/// it is in, through the conversation table, which starts the actor if it
/// isn't running: what the VM service has for it, and a question or an
/// answer from another conversation's actor.
#[derive(Debug)]
pub enum Signal {
    /// Something in the VM calls a tool: the conversation's actor runs
    /// it, and says how it went.
    Call {
        conversation: ConversationId,
        tool: String,
        args: serde_json::Value,
        reply: oneshot::Sender<Result<serde_json::Value, service::Failure>>,
    },
    /// Something from outside the chat that Max there is to hear.
    Heard {
        conversation: ConversationId,
        heard: Heard,
    },
    /// A program in the VM follows the conversation's timeline.
    Subscribe {
        conversation: ConversationId,
        reply: oneshot::Sender<Subscription>,
    },
}

/// What Max hears from outside its chat, each a wake with some words:
/// one event, whoever it is from.
#[derive(Debug)]
pub enum Heard {
    /// The VM service, about the group's VM.
    Vm(String),
    /// Max in another conversation asks Max here. See "Asking another
    /// conversation" in docs/rust-rewrite.md.
    Asked(Question),
    /// Max in another conversation answers what Max here asked it, or it
    /// can't be asked, and why.
    Answered(Answer),
}

/// The timeline from `head` on, for a program in the group's VM: every
/// row committed after it comes to `rows`, until the actor stops. The rows
/// up to `head` are in the database.
pub struct Subscription {
    pub place: Arc<Place>,
    pub head: MessageId,
    pub rows: broadcast::Receiver<Arc<Message>>,
    pub services: Arc<service::Services>,
}

impl fmt::Debug for Subscription {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Subscription")
            .field("conversation", &self.place.conversation)
            .field("head", &self.head)
            .finish_non_exhaustive()
    }
}

/// Where a request's answer goes: what was asked for, or why it wasn't
/// done.
pub type Reply<T> = oneshot::Sender<Result<T, String>>;

/// What a tool asks of its conversation's actor, each with where its
/// answer goes.
#[derive(Debug)]
pub enum Request {
    /// Set the conversation's limits, None back to the default: what
    /// each is now.
    Configure {
        changes: Vec<(Setting, Option<u64>)>,
        reply: Reply<Vec<Configured>>,
    },
    /// Ask Max in conversation `to`: whom it went to.
    Ask {
        to: ConversationId,
        question: String,
        reply: Reply<String>,
    },
    /// Answer question `to`, as it was numbered here, which Max in
    /// another conversation asked: whom the answer went to.
    Answer {
        to: u32,
        text: String,
        reply: Reply<String>,
    },
    /// Wake Max with a program's `text`: what the program is told.
    Wake { text: String, reply: Reply<String> },
    /// Whether the tool may go on to act in the chat by itself, as a mute
    /// does, not through the actor: it may unless Max is stopped here.
    Act { reply: Reply<()> },
}

impl Request {
    /// Answers that it wasn't done, and why.
    pub fn refuse(self, why: &str) {
        let why = why.to_owned();
        match self {
            Request::Act { reply } => drop(reply.send(Err(why))),
            Request::Configure { reply, .. } => drop(reply.send(Err(why))),
            Request::Ask { reply, .. }
            | Request::Answer { reply, .. }
            | Request::Wake { reply, .. } => drop(reply.send(Err(why))),
        }
    }
}

/// What Max in one conversation asks Max in another, on its way there.
/// Nothing waits for the answer: the question carries who asked, which
/// is all that lets the one asked reach the asker, once.
#[derive(Clone, Debug)]
pub struct Question {
    /// The conversation that asks, as the one asked names it.
    pub from: Peer,
    /// The conversation asked, as the asker names it.
    pub to: Peer,
    pub text: String,
}

/// The answer to a [`Question`], on its way back to who asked.
#[derive(Clone, Debug)]
pub struct Answer {
    /// The conversation that answers, as the asker names it.
    pub by: Peer,
    /// What was asked: the asker kept nothing of it.
    pub question: String,
    /// What Max there said; or why nothing comes, where that can be
    /// told.
    pub said: Result<String, String>,
}

impl Question {
    /// What tells the asker `said` of it: an answer, or why none comes.
    pub fn answered(self, said: Result<String, String>) -> Signal {
        Signal::Heard {
            conversation: self.from.conversation,
            heard: Heard::Answered(Answer {
                by: self.to,
                question: self.text,
                said,
            }),
        }
    }
}

/// What Max says or does that isn't the model's text, which a tool
/// called from the VM asked for: committed by the actor and sent like a
/// segment. Its row is no turn's, and marked as a program's: the host
/// doesn't know what in the VM called. See "Sending via `Post`".
#[derive(Debug)]
pub struct Post {
    pub act: Act,
    /// Told how the sending went.
    pub receipt: Option<Receipt>,
}

#[derive(Debug)]
pub enum Act {
    Say(Draft),
    /// Say, but the receipt hears once the row is committed: it goes out
    /// after what was said before it, and the records show if it didn't.
    /// For a file, whose upload can take minutes.
    Queue(Draft),
    /// Take back an earlier message of the timeline.
    Unsend(MessageId),
}

/// A limit as the conversation has it: what is in force, and what it
/// would be had nobody set it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Configured {
    pub setting: Setting,
    pub value: u64,
    pub default: u64,
}

/// Where the sender says how a row's sending went: the row, or why it
/// didn't go out.
pub type Receipt = oneshot::Sender<Result<MessageId, String>>;

/// Something handed to the conversation to say or do, on its way.
pub struct Sending(oneshot::Receiver<Result<MessageId, String>>);

impl Sending {
    /// Waits until it is sent, or only committed for [`Act::Queue`]: the
    /// row, or why it didn't go out.
    pub async fn sent(self) -> Result<MessageId, String> {
        self.0.await.map_err(|_| UNANSWERED.to_owned())?
    }
}

/// What a tool is told when its conversation's actor is gone...
const GONE: &str = "this conversation's actor has stopped";
/// ...or went before it answered.
const UNANSWERED: &str = "the conversation stopped before answering";

/// Lets a tool act in its conversation: say something, ask another
/// conversation or answer one.
#[derive(Clone, Debug)]
pub struct Poster {
    mailbox: UnboundedSender<Event>,
}

impl Poster {
    pub fn new(mailbox: UnboundedSender<Event>) -> Self {
        Self { mailbox }
    }

    /// Wakes Max with a program's `text`: what the program is told, or
    /// why not.
    pub async fn wake(&self, text: String) -> Result<String, String> {
        self.request(|reply| Request::Wake { text, reply }).await
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

    /// Hands `draft` to the conversation, and waits only until it is
    /// committed, not sent: the row.
    pub async fn queue(&self, draft: Draft) -> Result<MessageId, String> {
        self.act(Act::Queue(draft))?.sent().await
    }

    /// Takes back `target`, and waits until the platform has.
    pub async fn unsend(&self, target: MessageId) -> Result<MessageId, String> {
        self.act(Act::Unsend(target))?.sent().await
    }

    /// Sets the conversation's limits, None back to the default: what
    /// each is now, or why not.
    pub async fn configure(
        &self,
        changes: Vec<(Setting, Option<u64>)>,
    ) -> Result<Vec<Configured>, String> {
        self.request(|reply| Request::Configure { changes, reply })
            .await
    }

    /// Asks Max in conversation `to`: whom the question went to, or why
    /// it wasn't asked.
    pub async fn ask(&self, to: ConversationId, question: String) -> Result<String, String> {
        let ask = |reply| Request::Ask {
            to,
            question,
            reply,
        };
        self.request(ask).await
    }

    /// Answers question `to`, which Max in another conversation asked:
    /// whom it went to, or why it wasn't taken.
    pub async fn answer(&self, to: u32, text: String) -> Result<String, String> {
        self.request(|reply| Request::Answer { to, text, reply })
            .await
    }

    /// Asks whether the tool may act in the chat by itself: `/stop`
    /// forbids it.
    pub async fn act_alone(&self) -> Result<(), String> {
        self.request(|reply| Request::Act { reply }).await
    }

    /// Sends the request `make` builds around where its answer goes, and
    /// waits for the answer.
    async fn request<T>(&self, make: impl FnOnce(Reply<T>) -> Request) -> Result<T, String> {
        let (reply, answer) = oneshot::channel();
        self.send(make(reply))?;
        answer.await.map_err(|_| UNANSWERED.to_owned())?
    }

    fn send(&self, request: Request) -> Result<(), String> {
        let sent = self.mailbox.send(Event::Request(request));
        sent.map_err(|_| GONE.to_owned())
    }

    fn act(&self, act: Act) -> Result<Sending, String> {
        let (receipt, sent) = oneshot::channel();
        let post = Post {
            act,
            receipt: Some(receipt),
        };
        self.mailbox
            .send(Event::Post(post))
            .map_err(|_| GONE.to_owned())?;
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
