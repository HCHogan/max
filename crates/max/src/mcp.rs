//! Max's tools, which programs in a group's VM call through the MCP
//! service; see "The MCP channel". Each declares itself as a [`tool::Tool`].

mod agent;
mod ask;
mod chat_file;
mod config;
mod find_stickers;
mod forward;
mod harness;
mod history;
mod mute_member;
mod program;
mod recall_message;
mod send_file;
mod send_image;
mod service;
mod show;
pub mod tool;
mod web_search;
pub(crate) mod work;

pub use forward::api;
pub use mute_member::MuteMember;
pub use service::{Grant, Sessions, serve, serve_with};

#[cfg(test)]
mod runner_tests;

use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use chrono::FixedOffset;
use serde::de::DeserializeOwned;
use serde_json::Value;
use sqlx::PgPool;
use tracing::warn;

use crate::conversation::{Place, Poster};
use crate::embedding::Embedder;
use crate::job::Link;
use crate::media::store::Store;
use crate::qq::groups::Groups;
use crate::search::Search;

/// What the tools reach, the same for every call, built once in main; an
/// `Option` is None when the configuration has none of it. Whether a
/// caller may use a tool is [`Caller`]'s business, never these.
#[derive(Clone)]
pub struct Services {
    pub pool: PgPool,
    pub offset: FixedOffset,
    /// For `web_search`.
    pub search: Option<Arc<Search>>,
    /// The content store, for pictures and files sent.
    pub store: Option<Arc<Store>>,
    /// For `find_stickers`, and `history` by meaning.
    pub embedder: Option<Arc<Embedder>>,
    /// For `mute_member` and a group's name; None without QQ.
    pub groups: Option<Arc<dyn Groups>>,
}

/// Where a call comes from: the conversation whose VM the program runs in,
/// and who calls.
pub struct Context {
    pub services: Arc<Services>,
    pub place: Arc<Place>,
    /// The most tokens a page of text holds: the model's cap on one item.
    pub page_tokens: u32,
    /// Whether the turn's model watches videos, which max.video needs.
    pub video: bool,
    /// The host's side of the VM's /work, for a program run there.
    pub work: Option<PathBuf>,
    /// A call's wall clock: the conversation's, when the run or the call
    /// started.
    pub call_time: Duration,
    pub caller: Caller,
}

impl Context {
    /// A call's context in `place`, for `caller`: a page of `page_tokens`,
    /// `call_time` on the clock, no videos and no /work. A turn whose
    /// model watches videos, and a program run in the VM, say so.
    pub fn new(
        services: &Arc<Services>,
        place: &Arc<Place>,
        caller: Caller,
        page_tokens: u32,
        call_time: Duration,
    ) -> Self {
        Self {
            services: Arc::clone(services),
            place: Arc::clone(place),
            page_tokens,
            video: false,
            work: None,
            call_time,
            caller,
        }
    }
}

/// Who calls, which decides the tools it has.
pub enum Caller {
    /// A turn's program or command: the tools marked `turn`, and what it
    /// says goes through the turn; and the programs' own, which run as a
    /// program's.
    Turn(Poster),
    /// A background agent: only the tools marked `job`, and its model
    /// calls forwarded to its upstream.
    Job(Arc<Link>),
    /// A program Max keeps in the group's VM, outside any turn: only the
    /// tools marked `program`, and what it says is the program's.
    Program(Poster),
    /// `vm-check`'s program, and tests': nobody to say anything for.
    Check,
}

impl Caller {
    /// Says things in the conversation for the turn, or the program, that
    /// called.
    pub fn poster(&self) -> Option<&Poster> {
        match self {
            Caller::Turn(poster) | Caller::Program(poster) => Some(poster),
            Caller::Job(_) | Caller::Check => None,
        }
    }

    /// Where a call of this caller's goes: the one place that says who may
    /// call what. A turn has every tool the prompt declares, and the
    /// runner's own requests. A background agent has the tools marked for
    /// it and nothing else. A program Max keeps in the VM has all of Max's
    /// tools, as the turn that wrote it could: Max decides what its
    /// programs do (2026-11-05); and the chat's files, but nothing that
    /// shows a model something, having none.
    pub fn route(&self, call: Call) -> Route {
        match (self, call) {
            (Caller::Job(_), Call::Tool(tool)) if tool.job => Route::Here,
            (Caller::Job(_), _) => Route::Refused,
            // What only programs have, so that Max can try out from a
            // turn's command the program it writes.
            (Caller::Turn(_) | Caller::Check, Call::Tool(tool)) if !tool.turn => Route::AsProgram,
            (Caller::Turn(_) | Caller::Check, _) => Route::Here,
            (Caller::Program(_), Call::Tool(_) | Call::File) => Route::Here,
            (Caller::Program(_), Call::Image | Call::Video) => Route::Refused,
        }
    }

    /// What a caller is told of a call that isn't its to make.
    pub fn refusal(&self, call: Call) -> Failure {
        let whose = match self {
            Caller::Job(_) => "a background agent",
            Caller::Program(_) => "a program kept in the VM",
            Caller::Turn(_) | Caller::Check => "a turn",
        };
        Failure::new("not_allowed", format!("{whose} can't call {}", call.name()))
    }
}

/// Where a call goes, for who makes it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Route {
    /// It runs for the caller, in the caller's session if it has one.
    Here,
    /// It is handed to the conversation's actor, which runs it as a
    /// program's, outside any turn.
    AsProgram,
    /// It isn't this caller's to make.
    Refused,
}

/// What a program asks Max for by name: one of Max's tools, or one of the
/// runner's own requests. Those aren't tools: they aren't listed or
/// counted, and the model sees what they show, not a value.
#[derive(Clone, Copy)]
pub enum Call {
    Tool(&'static tool::Spec),
    /// max.image
    Image,
    /// max.video
    Video,
    /// max.file
    File,
}

impl Call {
    pub fn find(name: &str) -> Option<Self> {
        match name {
            show::IMAGE => Some(Self::Image),
            show::VIDEO => Some(Self::Video),
            chat_file::NAME => Some(Self::File),
            _ => tool::find(name).map(Self::Tool),
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Tool(tool) => tool.name,
            Self::Image => show::IMAGE,
            Self::Video => show::VIDEO,
            Self::File => chat_file::NAME,
        }
    }
}

#[cfg(test)]
impl Services {
    /// Only the database, at UTC+8.
    pub fn bare(pool: PgPool) -> Self {
        Self {
            pool,
            offset: crate::conversation::testing::offset(),
            search: None,
            store: None,
            embedder: None,
            groups: None,
        }
    }
}

#[cfg(test)]
impl Context {
    /// A check's in `place`: pages of 2000 tokens, no videos, no /work.
    pub fn check(services: Services, place: Arc<Place>) -> Self {
        let call_time = max_core::limits::CALL_TIME;
        Self::new(&Arc::new(services), &place, Caller::Check, 2000, call_time)
    }
}

/// A call that failed, as the program sees it.
#[derive(Debug, PartialEq, Eq)]
pub struct Failure {
    pub code: &'static str,
    pub message: String,
}

impl Failure {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

impl From<sqlx::Error> for Failure {
    fn from(error: sqlx::Error) -> Self {
        warn!(%error, "a Max tool's query failed");
        Self::new("internal", "the database failed; try again later")
    }
}

/// Runs `name` for a program Max keeps in the group's VM, outside any
/// turn: one of Max's tools, or the runner's max.file, within the
/// context's call time.
pub async fn program_call(name: &str, context: &Context, args: Value) -> Result<Value, Failure> {
    let call = async {
        let Some(call) = Call::find(name) else {
            return Err(unknown(name));
        };
        match (context.caller.route(call), call) {
            (Route::Here, Call::Tool(tool)) => tool.call(context, args).await,
            (Route::Here, Call::File) => chat_file::run(context, args).await,
            _ => Err(context.caller.refusal(call)),
        }
    };
    tokio::time::timeout(context.call_time, call)
        .await
        .unwrap_or_else(|_| Err(service::late(context.call_time)))
}

/// Runs the Max tool `name`, as its tests do.
#[cfg(test)]
pub async fn call(name: &str, context: &Context, args: Value) -> Result<Value, Failure> {
    match tool::find(name) {
        Some(tool) => tool.call(context, args).await,
        None => Err(unknown(name)),
    }
}

/// What `mutex` guards, even after a panic while it was held: nothing
/// here leaves it half-changed.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// What a caller is told of a name nothing answers to.
fn unknown(name: &str) -> Failure {
    Failure::new("unknown_tool", format!("there is no tool named {name}"))
}

fn internal() -> Failure {
    Failure::new("internal", "something went wrong; try again later")
}

fn arguments<T: DeserializeOwned>(tool: &str, args: Value) -> Result<T, Failure> {
    serde_json::from_value(args).map_err(|error| {
        Failure::new(
            "bad_arguments",
            format!("{tool}'s arguments are wrong: {error}"),
        )
    })
}

#[cfg(test)]
mod tests {
    use max_core::ids::TurnId;
    use tokio::sync::mpsc::unbounded_channel;

    use super::*;

    #[test]
    fn who_may_call_what() {
        let (mailbox, _events) = unbounded_channel();
        let turn = Caller::Turn(Poster::new(mailbox.clone(), TurnId(1)));
        let program = Caller::Program(Poster::program(mailbox));
        for tool in tool::TOOLS.iter() {
            let call = Call::Tool(tool);
            // What the prompt doesn't declare is a program's, and a turn
            // that calls it calls as one.
            let turns = if tool.turn {
                Route::Here
            } else {
                Route::AsProgram
            };
            assert_eq!(turn.route(call), turns, "{}", tool.name);
            assert_eq!(program.route(call), Route::Here, "{}", tool.name);
        }
        for call in [Call::Image, Call::Video, Call::File] {
            assert_eq!(turn.route(call), Route::Here, "{}", call.name());
        }
        // A program has no model to show anything to.
        assert_eq!(program.route(Call::File), Route::Here);
        for call in [Call::Image, Call::Video] {
            assert_eq!(program.route(call), Route::Refused, "{}", call.name());
            let refused = program.refusal(call);
            assert_eq!(refused.code, "not_allowed");
            assert!(
                refused
                    .message
                    .starts_with("a program kept in the VM can't call "),
                "{refused:?}"
            );
        }
    }
}
