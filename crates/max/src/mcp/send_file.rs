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
    #[schemars(
        length(min = 1),
        description = "a path under /work; a relative one is from /work"
    )]
    path: String,
    #[schemars(
        length(min = 1),
        description = "the file name shown in the chat; the path's by default"
    )]
    name: Option<String>,
}

#[derive(Serialize, JsonSchema)]
pub struct Sent {
    handle: String,
}

impl Tool for SendFile {
    const NAME: &'static str = "send_file";
    const DESCRIPTION: &'static str = "Sends a file under /work to this chat, such as a document, a spreadsheet or an archive you made.";

    type Args = Args;
    type Output = Sent;

    fn guide() -> String {
        format!(
            "Sends a file under /work to this chat, where it shows as a file that opens to download: documents, spreadsheets, PDFs, archives, code. At most {} MiB, and not empty; no symlink on the path.\n  \
            name is the file name shown in the chat, the path's by default. It returns once the file is stored and queued, and handle is the file's handle; the upload goes on after that, a big file takes a minute or two to reach the chat, and what you say afterwards waits behind it. If it doesn't go out, its row in the records is marked （没发出去）.\n  \
            A picture for everyone to see goes with send_image, not as a file. To send again a file the records already have, copy it to /work with file first.",
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
        context.poster.as_ref(),
    ) else {
        return Err(Failure::new("unavailable", "files can't be sent from here"));
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
        .map_err(|error| Failure::new("not_sent", format!("not sent: {error}")))?;
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
            Failure::new("unreadable", format!("can't read {shown}: {error}"))
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
        return Err(Failure::new("empty", format!("{shown} is empty")));
    }
    partial.finish().await.map_err(stored)
}

/// The name a file is shown and saved under: one path component, without
/// control characters.
fn named(name: &str) -> Result<String, Failure> {
    let name = name.trim();
    let bad = |why: String| Failure::new("bad_name", format!("the file name {why}"));
    if name.is_empty() || name == "." || name == ".." {
        return Err(bad("can't be empty".into()));
    }
    if name.chars().count() > LONGEST_NAME {
        return Err(bad(format!("is at most {LONGEST_NAME} characters")));
    }
    if name.contains(['/', '\\']) || name.chars().any(char::is_control) {
        return Err(bad("can't have /, \\ or control characters".into()));
    }
    Ok(name.to_owned())
}

#[cfg(test)]
mod tests;
