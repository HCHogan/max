//! `file`: a medium of the conversation's record, by its handle, copied
//! into /work/chat for a program to read. Until 2026-11-12 it was a
//! request of the runner's own, `max.file`. See "Reading files".

use max_core::ids::MessageId;
use max_db::media::{self, Stored};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use tokio::task::spawn_blocking;

use super::tool::Tool;
use super::work::put;
use super::{Context, Failure, internal};
use max_core::limits::KEPT_FILE_BYTES;

/// Where in /work the files go.
const DIR: &str = "chat";
/// The most of a file's name kept, in bytes.
const LONGEST_NAME: usize = 150;

pub struct File;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Args {
    #[schemars(
        length(min = 1),
        description = "the handle, as the records show it: file#123.0, or image#, sticker#, video#, audio#"
    )]
    handle: String,
}

/// Where the copy is, and what the record says of the file.
#[derive(Serialize, JsonSchema)]
pub struct Fetched {
    path: String,
    name: Option<String>,
    size: u64,
}

impl Tool for File {
    const NAME: &'static str = "file";
    const DESCRIPTION: &'static str = "Copies a file of this chat's records into /work/chat, by its handle (file#123.0), and returns {path, name, size}.";

    type Args = Args;
    type Output = Fetched;

    fn guide() -> String {
        format!(
            "Copies a file of this chat's records into /work/chat/ and returns {{ path, name, size }}. handle is as the records show it, file#123.0; what the people sent as a picture, a sticker, a video or a voice message has one too (image#123.0). Only what was downloaded is there: at most {} MiB each. Read the copy from there with shell: pdftotext for a PDF, max.video for a video.",
            KEPT_FILE_BYTES >> 20
        )
    }

    async fn run(context: &Context, Args { handle }: Args) -> Result<Fetched, Failure> {
        fetch(context, &handle).await
    }
}

async fn fetch(context: &Context, handle: &str) -> Result<Fetched, Failure> {
    let (Some(work), Some(store)) = (&context.work, &context.services.store) else {
        return Err(Failure::new("unavailable", "files can't be fetched here"));
    };
    let Some((message, ordinal)) = parse(handle) else {
        return Err(Failure::new(
            "bad_handle",
            format!("{handle} isn't a handle: write it like file#123.0"),
        ));
    };
    let mut conn = context.services.pool.acquire().await?;
    let stored = media::stored(&mut conn, message, ordinal).await?;
    drop(conn);
    let Some(stored) = stored.filter(|stored| stored.conversation == context.place.conversation)
    else {
        return Err(Failure::new(
            "not_found",
            format!(
                "this chat's records hold no stored {handle}: the handle is wrong, or it wasn't downloaded (over {} MiB, or the download failed)",
                KEPT_FILE_BYTES >> 20
            ),
        ));
    };
    let name = file_name(message, ordinal, &stored);
    let (work, from, to) = (work.clone(), store.path(&stored.sha256), name.clone());
    spawn_blocking(move || put(&work, DIR, &to, &from))
        .await
        .map_err(|_| internal())??;
    Ok(Fetched {
        path: format!("/work/{DIR}/{name}"),
        name: stored.name,
        size: stored.size,
    })
}

/// `file#123.0`, also as the record shows it: in brackets, with what it
/// is after a colon.
fn parse(handle: &str) -> Option<(MessageId, u16)> {
    let handle = handle.trim().trim_start_matches('[');
    let handle = handle.split([':', ']']).next()?.trim();
    let (word, numbers) = handle.split_once('#')?;
    if !["image", "sticker", "video", "audio", "file"].contains(&word) {
        return None;
    }
    let (message, ordinal) = numbers.split_once('.')?;
    Some((MessageId(message.parse().ok()?), ordinal.parse().ok()?))
}

/// `123.0-周报.pdf` for a file with a name, `123.0.jpg` for the rest: the
/// handle's numbers first, so that no two clash.
fn file_name(message: MessageId, ordinal: u16, stored: &Stored) -> String {
    let numbers = format!("{}.{ordinal}", message.0);
    let name = stored.name.as_deref().map(cleaned).unwrap_or_default();
    if !name.is_empty() {
        return format!("{numbers}-{name}");
    }
    match stored.mime.as_deref().and_then(extension) {
        Some(extension) => format!("{numbers}.{extension}"),
        None => numbers,
    }
}

/// A name someone gave a file, as one path component: `/`, `\` and
/// control characters as `_`, and no longer than a file system takes.
fn cleaned(name: &str) -> String {
    let mut cleaned = String::new();
    for c in name.trim().chars() {
        let c = if c == '/' || c == '\\' || c.is_control() {
            '_'
        } else {
            c
        };
        if cleaned.len() + c.len_utf8() > LONGEST_NAME {
            break;
        }
        cleaned.push(c);
    }
    cleaned
}

/// `jpg` for `image/jpeg`, the subtype itself when it is short and plain.
fn extension(mime: &str) -> Option<&str> {
    let subtype = mime.split(';').next()?.split_once('/')?.1.trim();
    match subtype {
        "jpeg" => Some("jpg"),
        subtype
            if !subtype.is_empty()
                && subtype.len() <= 5
                && subtype.chars().all(|c| c.is_ascii_alphanumeric()) =>
        {
            Some(subtype)
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests;
