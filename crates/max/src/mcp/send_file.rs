//! `send_file`: a file a program made or fetched in /work, sent to its
//! group as a file. See "发文件".

use chrono::Utc;
use max_core::message::{Draft, DraftNode};
use max_db::media::{self, Blob};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::task::spawn_blocking;
use tracing::warn;

use super::work::{beneath_work, read};
use super::{Context, Failure, arguments, internal};

/// The largest file sent, in bytes: as large as one downloaded. QQ takes
/// up to 200 MiB, but a call has a minute, and 32 MiB took 14 seconds to
/// upload from tank on 2026-10-29.
const MOST: u64 = 64 << 20;
/// The longest name, in characters.
const LONGEST_NAME: usize = 100;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Args {
    path: String,
    name: Option<String>,
}

pub async fn run(context: &Context, args: Value) -> Result<Value, Failure> {
    let Args { path, name } = arguments("send_file", args)?;
    let (Some(work), Some(store), Some(poster)) = (
        &context.work,
        &context.services.store,
        context.caller.poster(),
    ) else {
        return Err(Failure::new("unavailable", "这里发不了文件。"));
    };
    let relative = beneath_work(&path)?;
    let name = match name {
        Some(name) => name,
        None => relative
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default(),
    };
    let name = named(&name)?;
    let work = work.clone();
    let bytes = spawn_blocking(move || read(&work, &relative, MOST))
        .await
        .map_err(|_| internal())??;
    if bytes.is_empty() {
        return Err(Failure::new("empty", format!("{path} 是空的")));
    }
    let size = bytes.len() as u64;
    let sha256 = store.put(bytes).await.map_err(|error| {
        warn!(%error, "couldn't store a file to send");
        internal()
    })?;
    let blob = Blob {
        sha256: sha256.clone(),
        mime: None,
        size,
        width: None,
        height: None,
        model_sha256: None,
    };
    let mut conn = context.services.pool.acquire().await?;
    media::remember(&mut conn, &blob, Utc::now()).await?;
    drop(conn);
    let draft = Draft {
        reply_to: None,
        nodes: vec![DraftNode::File { sha256, name, size }],
    };
    let id = poster
        .post(draft)
        .await
        .map_err(|error| Failure::new("not_sent", format!("没发出去：{error}")))?;
    Ok(json!({ "handle": format!("file#{id}.0") }))
}

/// The name a file is shown and saved under: one path component, without
/// control characters.
fn named(name: &str) -> Result<String, Failure> {
    let name = name.trim();
    let bad = |why: String| Failure::new("bad_name", format!("文件名{why}"));
    if name.is_empty() || name == "." || name == ".." {
        return Err(bad("不能是空的".into()));
    }
    if name.chars().count() > LONGEST_NAME {
        return Err(bad(format!("最长 {LONGEST_NAME} 个字")));
    }
    if name.contains(['/', '\\']) || name.chars().any(char::is_control) {
        return Err(bad("里不能有 /、\\ 或控制字符".into()));
    }
    Ok(name.to_owned())
}

#[cfg(test)]
mod tests;
