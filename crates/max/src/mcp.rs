//! Max's tools, which programs in a group's VM call through the MCP
//! service; see "The MCP channel". Each declares itself as a [`tool::Tool`].

mod agent;
mod chat_file;
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
pub use service::{Grant, Sessions, serve, serve_with};

#[cfg(test)]
mod runner_tests;

use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use chrono::FixedOffset;
use serde::de::DeserializeOwned;
use serde_json::Value;
use sqlx::PgPool;
use tracing::warn;

use crate::conversation::{Place, Poster};
use crate::embedding::Embedder;
use crate::job::Link;
use crate::media::store::Store;
use crate::qq::admin::Admin;
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
    /// For `mute_member`; None without QQ.
    pub admin: Option<Arc<dyn Admin>>,
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
    pub caller: Caller,
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

    /// Whether it may make `call`. A program Max keeps in the VM may use
    /// all of Max's tools, as the turn that wrote it could: Max decides
    /// what its programs do (2026-11-05).
    pub fn allows(&self, call: Call) -> bool {
        match (self, call) {
            (Caller::Job(_), Call::Tool(tool)) => tool.job,
            (_, Call::Tool(_)) => true,
            (Caller::Turn(_) | Caller::Check, _) => true,
            // A program kept in the VM reads the chat's files, but has no
            // model to show anything to.
            (Caller::Program(_), Call::File) => true,
            (Caller::Job(_) | Caller::Program(_), _) => false,
        }
    }
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
            admin: None,
        }
    }
}

#[cfg(test)]
impl Context {
    /// A check's in `place`: pages of 2000 tokens, no videos, no /work.
    pub fn check(services: Services, place: Arc<Place>) -> Self {
        Self {
            services: Arc::new(services),
            place,
            page_tokens: 2000,
            video: false,
            work: None,
            caller: Caller::Check,
        }
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
        Self::new("internal", "数据库出错了，稍后再试。")
    }
}

/// Runs `name` for a program Max keeps in the group's VM, outside any
/// turn: one of Max's tools, or the runner's max.file.
pub async fn program_call(name: &str, context: &Context, args: Value) -> Result<Value, Failure> {
    match Call::find(name).filter(|call| context.caller.allows(*call)) {
        Some(Call::Tool(tool)) => tool.call(context, args).await,
        Some(Call::File) => chat_file::run(context, args).await,
        _ => Err(Failure::new(
            "not_allowed",
            format!("常驻程序用不了 {name}"),
        )),
    }
}

/// Runs the Max tool `name`, as its tests do.
#[cfg(test)]
pub async fn call(name: &str, context: &Context, args: Value) -> Result<Value, Failure> {
    match tool::find(name) {
        Some(tool) => tool.call(context, args).await,
        None => Err(Failure::new(
            "unknown_tool",
            format!("没有 {name} 这个工具"),
        )),
    }
}

/// What `mutex` guards, even after a panic while it was held: nothing
/// here leaves it half-changed.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn internal() -> Failure {
    Failure::new("internal", "出错了，稍后再试。")
}

fn arguments<T: DeserializeOwned>(tool: &str, args: Value) -> Result<T, Failure> {
    serde_json::from_value(args)
        .map_err(|error| Failure::new("bad_arguments", format!("{tool} 的参数不对：{error}")))
}
