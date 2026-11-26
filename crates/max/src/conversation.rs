//! A conversation's actor: the one writer of its timeline and the driver
//! of its core. See docs/design/actor.md.

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
use max_core::limits::{ASK_DAYS, ASK_WAITING, Setting};
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
    /// A message someone sent.
    Inbound(Inbound),
    /// The `/bind <码>` that just bound this group, from the table.
    Bound(Inbound),
    /// Something to say or do that isn't the model's text, such as a
    /// tool's picture or recall.
    Post(Post),
    /// The model call's segmenter cut a message out of the stream.
    Said {
        /// The model call that said it.
        task: TaskId,
        /// The message.
        segment: Segment,
    },
    /// The model call ended. An error once something was said is not
    /// retried.
    ModelDone {
        /// The model call.
        task: TaskId,
        /// What the model produced, and how long the call took; or why it gave
        /// nothing.
        out: Result<(ModelOutput, Timing), ModelFailed>,
    },
    /// A tool call ended.
    ToolDone {
        /// The task that ran it.
        task: TaskId,
        /// The call.
        call: CallId,
        /// What it gave.
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
        /// The tool's name.
        tool: String,
        /// Its arguments.
        args: serde_json::Value,
        /// Where the result goes.
        reply: oneshot::Sender<Result<serde_json::Value, service::Failure>>,
    },
    /// A program in the group's VM follows the timeline: `maxx events`.
    Subscribe(oneshot::Sender<Subscription>),
    /// Max restarts: end the core, within a grace, then stop.
    Stop,
}

/// Why a model call gave no output.
#[derive(Debug, thiserror::Error)]
pub enum ModelFailed {
    /// As max-llm says of the last attempt.
    #[error(transparent)]
    Call(#[from] max_llm::Error),
    /// Its task was aborted or panicked before it said how the call
    /// went.
    #[error("the model call ended without a result")]
    Lost,
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
        /// Whose VM calls.
        conversation: ConversationId,
        /// The tool's name.
        tool: String,
        /// Its arguments.
        args: serde_json::Value,
        /// Where the result goes.
        reply: oneshot::Sender<Result<serde_json::Value, service::Failure>>,
    },
    /// Something from outside the chat that Max there is to hear.
    Heard {
        /// Whose Max is to hear it.
        conversation: ConversationId,
        /// What there is to hear.
        heard: Heard,
    },
    /// A program in the VM follows the conversation's timeline.
    Subscribe {
        /// Whose timeline.
        conversation: ConversationId,
        /// Where the subscription goes.
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
    /// conversation" in docs/design/jobs.md.
    Asked(Question),
    /// Max in another conversation answers what Max here asked it, or it
    /// can't be asked, and why.
    Answered(Answer),
}

/// The timeline from `head` on, for a program in the group's VM: every
/// row committed after it comes to `rows`, until the actor stops. The rows
/// up to `head` are in the database; a conversation without a row has
/// none.
pub struct Subscription {
    /// The conversation's place.
    pub place: Arc<Place>,
    /// The last row committed when the subscription was made, if any.
    pub head: Option<MessageId>,
    /// Each row committed after `head`.
    pub rows: broadcast::Receiver<Arc<Message>>,
    /// The database, and what the tools reach.
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

/// Why the conversation won't do what an event asks, by the one rule of
/// what goes on once Max is stopped or stopping.
#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum Refusal {
    /// `/stop` stopped Max here.
    #[error("Max is stopped here (/stop), so this wasn't done")]
    Stopped,
    /// Max is shutting down.
    #[error("Max is restarting, so this wasn't done")]
    Stopping,
}

/// Why a conversation didn't do what a tool asked of it, worded as the
/// tool's caller is told.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum Refused {
    /// The actor is gone: it stopped on an error, or Max is stopping.
    #[error("this conversation's actor has stopped")]
    Gone,
    /// The actor went with the request in its hands.
    #[error("the conversation stopped before answering")]
    Abandoned,
    /// The stop rule: Max is stopped here, or stopping.
    #[error(transparent)]
    Rule(#[from] Refusal),
    /// `ask`: no edge leads to that conversation, or there is none. The
    /// two are refused alike: asking tells nothing of which there are.
    #[error(
        "can't ask c#{0}: there is no link from here to it, or no such conversation; whom Max here may ask is listed under [能问的会话]"
    )]
    NotLinked(ConversationId),
    /// `ask`: as many questions from here wait there as may.
    #[error(
        "c#{0} has yet to answer {most} questions from here, the most that wait at once, so this one wasn't asked; they are listed under [问出去还没回的]",
        most = ASK_WAITING
    )]
    TooMany(ConversationId),
    /// `answer`: no question of that number waits here.
    #[error(
        "there is no ask#{0} to answer here: no such question, or it was answered already, or it was asked over {days} days ago; nothing was sent. What waits is listed under [等你回答的问题]",
        days = ASK_DAYS
    )]
    NoQuestion(i64),
    /// Nothing in a draft could be said.
    #[error("there was nothing in it to send")]
    NothingToSay,
    /// The row to take back isn't one of this conversation's.
    #[error("no such message here")]
    NoSuchMessage,
    /// The platform didn't take it, or its answer was lost: what the
    /// sender says of that.
    #[error("{0}")]
    Unsent(String),
}

/// Where a request's answer goes: what was asked for, or why it wasn't
/// done.
pub type Reply<T> = oneshot::Sender<Result<T, Refused>>;

/// What a tool asks of its conversation's actor, each with where its
/// answer goes.
#[derive(Debug)]
pub enum Request {
    /// Set the conversation's limits, None back to the default: what
    /// each is now.
    Configure {
        /// Each limit to set, and what to.
        changes: Vec<(Setting, Option<u64>)>,
        /// Where the limits as they are then go.
        reply: Reply<Vec<Configured>>,
    },
    /// Ask Max in conversation `to`: whom it went to.
    Ask {
        /// The conversation asked.
        to: ConversationId,
        /// What is asked.
        question: String,
        /// Where the name of whom it went to goes.
        reply: Reply<String>,
    },
    /// Answer question `to`, which Max in another conversation asked:
    /// whom the answer went to.
    Answer {
        /// The question's number.
        to: i64,
        /// The answer.
        text: String,
        /// Where the name of whom it went to goes.
        reply: Reply<String>,
    },
    /// Wake Max with a program's `text`: what the program is told.
    Wake {
        /// What the program says.
        text: String,
        /// Where what it is told goes.
        reply: Reply<String>,
    },
    /// Whether the tool may go on to act in the chat by itself, as a mute
    /// does, not through the actor: it may unless Max is stopped here.
    Act {
        /// Where the leave, or the refusal, goes.
        reply: Reply<()>,
    },
}

impl Request {
    /// Answers that it wasn't done, and why.
    pub fn refuse(self, why: Refused) {
        match self {
            Self::Act { reply } => drop(reply.send(Err(why))),
            Self::Configure { reply, .. } => drop(reply.send(Err(why))),
            Self::Ask { reply, .. } | Self::Answer { reply, .. } | Self::Wake { reply, .. } => {
                drop(reply.send(Err(why)))
            }
        }
    }
}

/// What Max in one conversation asks Max in another, on its way there:
/// the actor it reaches keeps it as a row, which is all that lets the
/// one asked reach the asker, once.
#[derive(Clone, Debug)]
pub struct Question {
    /// The conversation that asks, as the one asked names it.
    pub from: Peer,
    /// The conversation asked, as the asker names it.
    pub to: Peer,
    /// The question.
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
    pub said: Result<String, Unanswered>,
}

/// Why Max in another conversation gives no answer, as the asker is
/// told.
#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum Unanswered {
    /// `/stop` stopped Max there.
    #[error("Max is stopped there (/stop)")]
    Stopped,
    /// Max is shutting down there.
    #[error("Max is restarting there")]
    Restarting,
    /// The conversation table found no chat to start its actor in.
    #[error("Max serves no chat of that conversation")]
    NoChat,
    /// The table couldn't start its actor.
    #[error("Max couldn't start on that conversation")]
    NotStarted,
}

impl Question {
    /// What tells the asker `said` of it: an answer, or why none comes.
    #[must_use]
    pub fn answered(self, said: Result<String, Unanswered>) -> Signal {
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
    /// What to say or do.
    pub act: Act,
    /// Told how the sending went.
    pub receipt: Option<Receipt>,
}

/// What a tool has Max's account say or do.
#[derive(Debug)]
pub enum Act {
    /// Say it, and tell the receipt once it is sent.
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
    /// The limit.
    pub setting: Setting,
    /// What is in force.
    pub value: u64,
    /// What it would be had nobody set it.
    pub default: u64,
}

/// Where the sender says how a row's sending went: the row, or why it
/// didn't go out.
pub type Receipt = oneshot::Sender<Result<MessageId, Refused>>;

/// Something handed to the conversation to say or do, on its way.
#[derive(Debug)]
pub struct Sending(oneshot::Receiver<Result<MessageId, Refused>>);

impl Sending {
    /// Waits until it is sent, or only committed for [`Act::Queue`]: the
    /// row, or why it didn't go out.
    ///
    /// # Errors
    ///
    /// [`Refused`], which says why it didn't go out; [`Refused::Abandoned`]
    /// if the conversation stopped first.
    pub async fn sent(self) -> Result<MessageId, Refused> {
        self.0.await.map_err(|_| Refused::Abandoned)?
    }
}

/// Lets a tool act in its conversation: say something, ask another
/// conversation or answer one.
#[derive(Clone, Debug)]
pub struct Poster {
    mailbox: UnboundedSender<Event>,
}

impl Poster {
    /// A poster into the conversation whose mailbox this is.
    #[must_use]
    pub fn new(mailbox: UnboundedSender<Event>) -> Self {
        Self { mailbox }
    }

    /// Wakes Max with a program's `text`: what the program is told, or
    /// why not.
    ///
    /// # Errors
    ///
    /// [`Refused`]: the conversation is gone, or Max is stopped or stopping.
    pub async fn wake(&self, text: String) -> Result<String, Refused> {
        self.request(|reply| Request::Wake { text, reply }).await
    }

    /// Says `draft`, and waits until it is sent.
    ///
    /// # Errors
    ///
    /// [`Refused`]: the conversation is gone or stopped, nothing in the draft
    /// could be said, or the platform didn't take it.
    pub async fn post(&self, draft: Draft) -> Result<MessageId, Refused> {
        self.say(draft)?.sent().await
    }

    /// Hands `draft` to the conversation, which says it whether or not
    /// anyone waits: what comes back is how the sending went.
    ///
    /// # Errors
    ///
    /// [`Refused::Gone`] if the conversation's actor has stopped.
    pub fn say(&self, draft: Draft) -> Result<Sending, Refused> {
        self.act(Act::Say(draft))
    }

    /// Hands `draft` to the conversation, and waits only until it is
    /// committed, not sent: the row.
    ///
    /// # Errors
    ///
    /// [`Refused`]: the conversation is gone or stopped, or nothing in the
    /// draft could be said.
    pub async fn queue(&self, draft: Draft) -> Result<MessageId, Refused> {
        self.act(Act::Queue(draft))?.sent().await
    }

    /// Takes back `target`, and waits until the platform has.
    ///
    /// # Errors
    ///
    /// [`Refused`]: the conversation is gone or stopped, the row isn't one of
    /// its, or the platform didn't take it back.
    pub async fn unsend(&self, target: MessageId) -> Result<MessageId, Refused> {
        self.act(Act::Unsend(target))?.sent().await
    }

    /// Sets the conversation's limits, None back to the default: what
    /// each is now, or why not.
    ///
    /// # Errors
    ///
    /// [`Refused`] if the conversation is gone.
    pub async fn configure(
        &self,
        changes: Vec<(Setting, Option<u64>)>,
    ) -> Result<Vec<Configured>, Refused> {
        self.request(|reply| Request::Configure { changes, reply })
            .await
    }

    /// Asks Max in conversation `to`: whom the question went to, or why
    /// it wasn't asked.
    ///
    /// # Errors
    ///
    /// [`Refused`]: the conversation is gone, Max is stopped or stopping, or
    /// no link leads to `to`.
    pub async fn ask(&self, to: ConversationId, question: String) -> Result<String, Refused> {
        let ask = |reply| Request::Ask {
            to,
            question,
            reply,
        };
        self.request(ask).await
    }

    /// Answers question `to`, which Max in another conversation asked:
    /// whom it went to, or why it wasn't taken.
    ///
    /// # Errors
    ///
    /// [`Refused`]: the conversation is gone or stopped, or no question has
    /// that number.
    pub async fn answer(&self, to: i64, text: String) -> Result<String, Refused> {
        self.request(|reply| Request::Answer { to, text, reply })
            .await
    }

    /// Asks whether the tool may act in the chat by itself: `/stop`
    /// forbids it.
    ///
    /// # Errors
    ///
    /// [`Refused`]: the conversation is gone, or Max is stopped here.
    pub async fn act_alone(&self) -> Result<(), Refused> {
        self.request(|reply| Request::Act { reply }).await
    }

    /// Sends the request `make` builds around where its answer goes, and
    /// waits for the answer.
    async fn request<T>(&self, make: impl FnOnce(Reply<T>) -> Request) -> Result<T, Refused> {
        let (reply, answer) = oneshot::channel();
        self.send(make(reply))?;
        answer.await.map_err(|_| Refused::Abandoned)?
    }

    fn send(&self, request: Request) -> Result<(), Refused> {
        let sent = self.mailbox.send(Event::Request(request));
        sent.map_err(|_| Refused::Gone)
    }

    fn act(&self, act: Act) -> Result<Sending, Refused> {
        let (receipt, sent) = oneshot::channel();
        let post = Post {
            act,
            receipt: Some(receipt),
        };
        self.mailbox
            .send(Event::Post(post))
            .map_err(|_| Refused::Gone)?;
        Ok(Sending(sent))
    }
}

/// An I/O task, numbered within its conversation and never reused: an
/// event from a task the actor no longer waits for is dropped.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct TaskId(u64);

impl TaskId {
    /// The `n`th task of its conversation.
    #[must_use]
    pub const fn new(n: u64) -> Self {
        Self(n)
    }
}

impl fmt::Display for TaskId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "task#{}", self.0)
    }
}

/// Where a conversation lives. v1 has one endpoint per conversation; the
/// mirror will make this a list.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Place {
    /// The conversation.
    pub conversation: ConversationId,
    /// A group or a private chat.
    pub kind: ConversationKind,
    /// Its endpoint.
    pub endpoint: EndpointId,
    /// The platform the endpoint is on.
    pub platform: Platform,
    /// The adapter's id for the endpoint, such as `group:<group_openid>`.
    pub native_id: String,
    /// Max's account there.
    pub me: Account,
    /// What Max is called there.
    pub my_name: String,
}
