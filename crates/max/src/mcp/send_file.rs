//! `send_file`: a file a program made or fetched in /work, sent to its
//! group as a file. See "Sending files".

use std::fs::File;
use std::path::Path;

use chrono::Utc;
use max_core::limits::SENT_FILE_BYTES;
use max_core::message::{Draft, DraftNode};
use max_db::media::{self, Blob};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use tokio::io::AsyncReadExt;
use tokio::task::spawn_blocking;
use tracing::warn;

use super::tool::Tool;
use super::work::{beneath_work, open, shown, too_big};
use super::{Context, Failure, internal};
use crate::media::store::Store;

/// The longest name, in characters.
const LONGEST_NAME: usize = 100;

pub struct SendFile;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Args {
    #[schemars(length(min = 1), description = "/work 下的路径，相对路径从 /work 算")]
    path: String,
    #[schemars(length(min = 1), description = "群里显示的文件名，默认用路径里的")]
    name: Option<String>,
}

#[derive(Serialize, JsonSchema)]
pub struct Sent {
    handle: String,
}

impl Tool for SendFile {
    const NAME: &'static str = "send_file";
    const DESCRIPTION: &'static str =
        "把 /work 下的一个文件发到本群，比如生成的文档、表格、压缩包。";
    const JOB: bool = false;

    type Args = Args;
    type Output = Sent;

    fn guide() -> String {
        format!(
            "把 /work 下的一个文件发到本群，群里显示成文件，点开能下载：文档、表格、PDF、压缩包、代码都行。最大 {} MiB，不能是空的；路径上不能有符号链接。\n  \
            name 是群里显示的文件名，默认用路径里的。文件存好、排上队就返回，handle 是这个文件的句柄；上传在后面接着做，大文件要一两分钟才到群里，你之后说的话排在它后面。没发出去的话，记录里这条标着（没发出去）。\n  \
            要大家直接看到的图用 send_image，别当文件发。记录里已有的文件要再发，先 max.file 拷到 /work 再发。",
            SENT_FILE_BYTES >> 20
        )
    }

    async fn run(context: &Context, args: Args) -> Result<Sent, Failure> {
        send(context, args).await
    }
}

async fn send(context: &Context, Args { path, name }: Args) -> Result<Sent, Failure> {
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
    let opened = relative.clone();
    let (file, _) = spawn_blocking(move || open(&work, &opened, SENT_FILE_BYTES))
        .await
        .map_err(|_| internal())??;
    let (sha256, size) = keep(store, file, &relative).await?;
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
        .queue(draft)
        .await
        .map_err(|error| Failure::new("not_sent", format!("没发出去：{error}")))?;
    Ok(Sent {
        handle: format!("file#{id}.0"),
    })
}

/// Copies `file`, `relative` under /work, into the store as it reads it:
/// its SHA-256 and size. Not past `SENT_FILE_BYTES`, though the guest may
/// write more after it was opened; not an empty one.
async fn keep(store: &Store, file: File, relative: &Path) -> Result<(String, u64), Failure> {
    let stored = |error: std::io::Error| {
        warn!(%error, "couldn't store a file to send");
        internal()
    };
    let mut partial = store.partial().await.map_err(stored)?;
    let mut file = tokio::fs::File::from_std(file).take(SENT_FILE_BYTES + 1);
    let mut piece = vec![0; 1 << 20];
    let mut size = 0;
    loop {
        let read = file.read(&mut piece).await.map_err(|error| {
            let shown = shown(relative);
            Failure::new("unreadable", format!("读不了 {shown}：{error}"))
        })?;
        if read == 0 {
            break;
        }
        size += read as u64;
        if size > SENT_FILE_BYTES {
            return Err(too_big(relative, SENT_FILE_BYTES));
        }
        partial.write(&piece[..read]).await.map_err(stored)?;
    }
    if size == 0 {
        let shown = shown(relative);
        return Err(Failure::new("empty", format!("{shown} 是空的")));
    }
    partial.finish().await.map_err(stored)
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
