//! `max.file`: a medium of the conversation's record, by its handle,
//! copied into /work/chat for a program to read. Not one of Max's tools:
//! the runner's SDK calls it by this name. See "读文件".

use max_core::ids::MessageId;
use max_db::media::{self, Stored};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::task::spawn_blocking;

use super::work::put;
use super::{Context, Failure, arguments, internal};

pub const NAME: &str = "max.file";
/// Where in /work the files go.
const DIR: &str = "chat";
/// The most of a file's name kept, in bytes.
const LONGEST_NAME: usize = 150;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Args {
    handle: String,
}

pub async fn run(context: &Context, args: Value) -> Result<Value, Failure> {
    let Args { handle } = arguments(NAME, args)?;
    let (Some(work), Some(store)) = (&context.work, &context.services.store) else {
        return Err(Failure::new("unavailable", "这里拿不了文件。"));
    };
    let Some((message, ordinal)) = parse(&handle) else {
        return Err(Failure::new(
            "bad_handle",
            format!("{handle} 不是句柄，要写成 file#123.0 这样"),
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
                "本群的记录里没有存下来的 {handle}：句柄不对，或者没下载下来（超过 64 MiB，或者下载失败）"
            ),
        ));
    };
    let name = file_name(message, ordinal, &stored);
    let (work, from, to) = (work.clone(), store.path(&stored.sha256), name.clone());
    spawn_blocking(move || put(&work, DIR, &to, &from))
        .await
        .map_err(|_| internal())??;
    Ok(json!({ "path": format!("/work/{DIR}/{name}"), "name": stored.name, "size": stored.size }))
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
