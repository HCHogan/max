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

use max_core::ids::{CallId, ConversationId, EndpointId, Handle, MessageId, TurnId};
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
use crate::job;
use crate::mcp;
use crate::tools::{Background, Moved};

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
    /// A tool, or a program Max keeps in the group's VM, asks something
    /// of the conversation, and waits for the answer.
    Request {
        request: Request,
        /// The turn it comes from; None from a program, outside any turn.
        origin: Option<TurnId>,
    },
    /// A background agent or command ended.
    JobDone {
        handle: Handle,
        finished: job::Finished,
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
    /// Max in another conversation asks Max here, from the table.
    Asked(Question),
    /// The question Max here asked, `ask`, was answered, or won't be, and
    /// why.
    Answered {
        ask: u32,
        answer: Result<String, String>,
    },
    /// Max restarts: end the core, within a grace, then stop.
    Stop,
}

/// What goes to a conversation's actor by its conversation, whatever chat
/// it is in, through the conversation table, which starts the actor if it
/// isn't running: what the VM service has for it, and a question from
/// another conversation's actor.
#[derive(Debug)]
pub enum Signal {
    /// A program Max keeps in the VM calls a tool, outside any turn: the
    /// conversation's actor runs it, and says how it went.
    Call {
        conversation: ConversationId,
        tool: String,
        args: serde_json::Value,
        reply: oneshot::Sender<Result<serde_json::Value, mcp::Failure>>,
    },
    /// Something about the VM Max should hear.
    Notice {
        conversation: ConversationId,
        text: String,
    },
    /// A program in the VM follows the conversation's timeline.
    Subscribe {
        conversation: ConversationId,
        reply: oneshot::Sender<Subscription>,
    },
    /// Max in another conversation asks Max in this one. See "Asking
    /// another conversation" in docs/rust-rewrite.md.
    Ask {
        conversation: ConversationId,
        question: Question,
    },
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

/// Where a request's answer goes: what was asked for, or why it wasn't
/// done.
pub type Reply<T> = oneshot::Sender<Result<T, String>>;

/// What a tool asks of its conversation's actor, each with where its
/// answer goes. A job is named by its number.
#[derive(Debug)]
pub enum Request {
    /// Start a background agent: its job.
    Agent {
        task: String,
        title: Option<String>,
        workdir: String,
        reply: Reply<u32>,
    },
    /// Run a `shell` command in the background: its job.
    Shell {
        shell: Background,
        reply: Reply<u32>,
    },
    /// Take a turn's command someone waits on as a background job: its
    /// job, or the command back with why not.
    Adopt {
        moved: Box<Moved>,
        reply: oneshot::Sender<Result<u32, (String, Box<Moved>)>>,
    },
    /// Tell a running agent something more.
    Steer {
        agent: u32,
        message: String,
        reply: Reply<()>,
    },
    /// Stop an agent or a command, or withdraw a question.
    Cancel { handle: Handle, reply: Reply<()> },
    /// One job's state, or every running one's.
    Status {
        handle: Option<Handle>,
        reply: Reply<Vec<job::Status>>,
    },
    /// Set the conversation's limits, None back to the default: what
    /// each is now.
    Configure {
        changes: Vec<(Setting, Option<u64>)>,
        reply: Reply<Vec<Configured>>,
    },
    /// Ask Max in conversation `to`; or, for agent `by`, with no `to`,
    /// Max here: the question's number here.
    Ask {
        to: Option<ConversationId>,
        question: String,
        by: Option<u32>,
        reply: Reply<u32>,
    },
    /// Answer question `to`, as it was numbered here, which Max in
    /// another conversation or an agent here asked; `by` an agent, the
    /// one answering: whom the answer went to.
    Answer {
        to: u32,
        text: String,
        by: Option<u32>,
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
            Request::Agent { reply, .. }
            | Request::Shell { reply, .. }
            | Request::Ask { reply, .. } => drop(reply.send(Err(why))),
            Request::Adopt { moved, reply } => drop(reply.send(Err((why, moved)))),
            Request::Steer { reply, .. }
            | Request::Cancel { reply, .. }
            | Request::Act { reply } => drop(reply.send(Err(why))),
            Request::Status { reply, .. } => drop(reply.send(Err(why))),
            Request::Configure { reply, .. } => drop(reply.send(Err(why))),
            Request::Answer { reply, .. } | Request::Wake { reply, .. } => {
                drop(reply.send(Err(why)));
            }
        }
    }
}

/// What Max in one conversation asks Max in another, on its way there.
#[derive(Debug)]
pub struct Question {
    /// The conversation that asks, as the one asked names it.
    pub from: Peer,
    pub text: String,
    /// Where the answer goes; or why there won't be one.
    pub answer: oneshot::Sender<Result<String, String>>,
}

impl Question {
    /// Tells the asker there won't be an answer, and why.
    pub fn refuse(self, why: &str) {
        let _ = self.answer.send(Err(why.to_owned()));
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

/// Lets a tool act in its conversation: say something, or run a
/// background agent, for its turn, or for a program Max keeps in the
/// group's VM; or ask and answer, for a background agent.
#[derive(Clone, Debug)]
pub struct Poster {
    mailbox: UnboundedSender<Event>,
    /// None for a program's, or an agent's.
    origin: Option<TurnId>,
    /// The agent's number, for an agent's.
    agent: Option<u32>,
}

impl Poster {
    pub fn new(mailbox: UnboundedSender<Event>, origin: TurnId) -> Self {
        Self {
            mailbox,
            origin: Some(origin),
            agent: None,
        }
    }

    /// For a program Max keeps in the group's VM.
    pub fn program(mailbox: UnboundedSender<Event>) -> Self {
        Self {
            mailbox,
            origin: None,
            agent: None,
        }
    }

    /// For background agent `agent`, which may only ask and answer.
    pub fn for_agent(mailbox: UnboundedSender<Event>, agent: u32) -> Self {
        Self {
            mailbox,
            origin: None,
            agent: Some(agent),
        }
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

    /// Starts a background agent: its number, or why not.
    pub async fn agent(
        &self,
        task: String,
        title: Option<String>,
        workdir: String,
    ) -> Result<u32, String> {
        let agent = |reply| Request::Agent {
            task,
            title,
            workdir,
            reply,
        };
        self.request(agent).await
    }

    /// Runs a `shell` command in the background: its number, or why not.
    pub async fn shell(&self, shell: Background) -> Result<u32, String> {
        self.request(|reply| Request::Shell { shell, reply }).await
    }

    /// Tells agent `agent` something more.
    pub async fn steer(&self, agent: u32, message: String) -> Result<(), String> {
        let steer = |reply| Request::Steer {
            agent,
            message,
            reply,
        };
        self.request(steer).await
    }

    /// Stops `handle`, an agent or a command, or withdraws it, a question.
    pub async fn cancel(&self, handle: Handle) -> Result<(), String> {
        self.request(|reply| Request::Cancel { handle, reply })
            .await
    }

    /// `handle` as it runs, or every running job.
    pub async fn status(&self, handle: Option<Handle>) -> Result<Vec<job::Status>, String> {
        self.request(|reply| Request::Status { handle, reply })
            .await
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

    /// Asks Max in conversation `to`, or an agent's Max, with no `to`:
    /// the question's number here, or why it wasn't asked.
    pub async fn ask(&self, to: Option<ConversationId>, question: String) -> Result<u32, String> {
        let ask = |reply| Request::Ask {
            to,
            question,
            by: self.agent,
            reply,
        };
        self.request(ask).await
    }

    /// Answers question `to`, which Max in another conversation or an
    /// agent here asked: whom it went to, or why it wasn't taken.
    pub async fn answer(&self, to: u32, text: String) -> Result<String, String> {
        let answer = |reply| Request::Answer {
            to,
            text,
            by: self.agent,
            reply,
        };
        self.request(answer).await
    }

    /// Asks whether the tool may act in the chat by itself: `/stop`
    /// forbids it, and a turn that has ended.
    pub async fn act_alone(&self) -> Result<(), String> {
        self.request(|reply| Request::Act { reply }).await
    }

    /// Hands a turn's command to the conversation as a background job:
    /// its number; or why not, with the command back, unless the
    /// conversation is gone with it.
    pub async fn adopt(&self, moved: Box<Moved>) -> Result<u32, (String, Option<Box<Moved>>)> {
        let (reply, answer) = oneshot::channel();
        let gone = || (GONE.to_owned(), None);
        self.send(Request::Adopt { moved, reply })
            .map_err(|_| gone())?;
        match answer.await {
            Ok(Ok(job)) => Ok(job),
            Ok(Err((why, moved))) => Err((why, Some(moved))),
            Err(_) => Err(gone()),
        }
    }

    /// Sends the request `make` builds around where its answer goes, and
    /// waits for the answer.
    async fn request<T>(&self, make: impl FnOnce(Reply<T>) -> Request) -> Result<T, String> {
        let (reply, answer) = oneshot::channel();
        self.send(make(reply))?;
        answer.await.map_err(|_| UNANSWERED.to_owned())?
    }

    fn send(&self, request: Request) -> Result<(), String> {
        let origin = self.origin;
        let sent = self.mailbox.send(Event::Request { request, origin });
        sent.map_err(|_| GONE.to_owned())
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
