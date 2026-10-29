//! Max's tools, which programs in a group's VM call through the MCP
//! service; see "MCP 通道". max-core's `MAX_TOOLS` declares them.

mod context_read;
mod service;

pub use service::{Grant, Sessions, serve};

use std::sync::Arc;

use chrono::FixedOffset;
use serde::de::DeserializeOwned;
use serde_json::Value;
use sqlx::PgPool;
use tracing::warn;

use crate::conversation::Place;

/// Where a call comes from: the conversation whose VM the program runs in.
pub struct Context {
    pub pool: PgPool,
    pub place: Arc<Place>,
    pub offset: FixedOffset,
    /// The most tokens a page of text holds: the model's cap on one item.
    pub page_tokens: u32,
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
