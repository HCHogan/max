//! Max's tools, which programs in a group's VM call through the MCP
//! service; see "MCP 通道". max-core's `MAX_TOOLS` declares them.

mod agent;
mod chat_file;
mod find_stickers;
mod forward;
mod history;
mod mute_member;
mod recall_message;
mod send_file;
mod send_image;
mod service;
mod show;
mod web_search;
pub(crate) mod work;

pub use service::{Grant, Sessions, serve};

#[cfg(test)]
mod runner_tests;

use std::path::PathBuf;
use std::sync::Arc;

use chrono::FixedOffset;
use max_core::tools::MAX_TOOLS;
use serde::de::DeserializeOwned;
use serde_json::Value;
use sqlx::PgPool;
use tracing::warn;

use crate::conversation::{Place, Poster};
use crate::embedding::Embedder;
use crate::llm::Upstream;
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
    /// The host's side of the VM's /work, for a program run there.
    pub work: Option<PathBuf>,
    pub caller: Caller,
}

/// Who calls, which decides the tools it has.
pub enum Caller {
    /// A turn's program: every tool, and what it says goes through the turn.
    Turn(Poster),
    /// A background agent: only the tools marked `job`, and its model
    /// calls forwarded to the upstream.
    Job(Arc<Upstream>),
    /// `vm-check`'s program, and tests': nobody to say anything for.
    Check,
}

impl Caller {
    /// Says things in the conversation for the turn that called.
    pub fn poster(&self) -> Option<&Poster> {
        match self {
            Caller::Turn(poster) => Some(poster),
            Caller::Job(_) | Caller::Check => None,
        }
    }

    /// Whether it may call the Max tool `name`; the runner's own requests
    /// aren't Max tools.
    pub fn allows(&self, name: &str) -> bool {
        !matches!(self, Caller::Job(_))
            || MAX_TOOLS.iter().any(|tool| tool.name == name && tool.job)
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

/// A call that failed, as the program sees it.
#[derive(Debug, PartialEq, Eq)]
pub struct Failure {
    pub code: &'static str,
    pub message: String,
}

impl Failure {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
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

/// Runs the Max tool `name`.
pub async fn call(name: &str, context: &Context, args: Value) -> Result<Value, Failure> {
    match name {
        "history" => history::run(context, args).await,
        "web_search" => web_search::run(context, args).await,
        "send_image" => send_image::run(context, args).await,
        "send_file" => send_file::run(context, args).await,
        "recall_message" => recall_message::run(context, args).await,
        "mute_member" => mute_member::run(context, args).await,
        "find_stickers" => find_stickers::run(context, args).await,
        name if agent::NAMES.contains(&name) => agent::run(name, context, args).await,
        _ => Err(Failure::new(
            "unknown_tool",
            format!("没有 {name} 这个工具"),
        )),
    }
}

fn internal() -> Failure {
    Failure::new("internal", "出错了，稍后再试。")
}

fn arguments<T: DeserializeOwned>(tool: &str, args: Value) -> Result<T, Failure> {
    serde_json::from_value(args)
        .map_err(|error| Failure::new("bad_arguments", format!("{tool} 的参数不对：{error}")))
}
