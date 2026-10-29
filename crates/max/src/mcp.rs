//! Max's tools, which programs in a group's VM call through the MCP
//! service; see "MCP 通道". max-core's `MAX_TOOLS` declares them.

mod context_read;
mod context_search;
mod find_stickers;
mod mute_member;
mod recall_message;
mod send_image;
mod service;
mod show;
mod web_search;

pub use service::{Grant, Sessions, serve};

#[cfg(test)]
mod runner_tests;

use std::path::PathBuf;
use std::sync::Arc;

use chrono::FixedOffset;
use serde::de::DeserializeOwned;
use serde_json::Value;
use sqlx::PgPool;
use tracing::warn;

use crate::conversation::{Place, Poster};
use crate::embedding::Embedder;
use crate::media::store::Store;
use crate::qq::admin::Admin;
use crate::search::Search;

/// Where a call comes from: the conversation whose VM the program runs in.
pub struct Context {
    pub pool: PgPool,
    pub place: Arc<Place>,
    pub offset: FixedOffset,
    /// The most tokens a page of text holds: the model's cap on one item.
    pub page_tokens: u32,
    /// None when no search is configured.
    pub search: Option<Arc<Search>>,
    /// The host's side of the VM's /work, for a program run there.
    pub work: Option<PathBuf>,
    /// The content store, if there is one, for pictures sent.
    pub store: Option<Arc<Store>>,
    /// Says things in the conversation for the turn that called.
    pub poster: Option<Poster>,
    /// For `find_stickers`; None when no embedding model is configured.
    pub embedder: Option<Arc<Embedder>>,
    /// For `mute_member`; None without QQ.
    pub admin: Option<Arc<dyn Admin>>,
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
        "context_read" => context_read::run(context, args).await,
        "web_search" => web_search::run(context, args).await,
        "send_image" => send_image::run(context, args).await,
        "recall_message" => recall_message::run(context, args).await,
        "mute_member" => mute_member::run(context, args).await,
        "find_stickers" => find_stickers::run(context, args).await,
        "context_search" => context_search::run(context, args).await,
        _ => Err(Failure::new(
            "unknown_tool",
            format!("没有 {name} 这个工具"),
        )),
    }
}

fn arguments<T: DeserializeOwned>(tool: &str, args: Value) -> Result<T, Failure> {
    serde_json::from_value(args)
        .map_err(|error| Failure::new("bad_arguments", format!("{tool} 的参数不对：{error}")))
}
