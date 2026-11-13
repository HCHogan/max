//! Adapters between Max's core and the model providers: Responses and Chat
//! Completions, streaming, reasoning passthrough and multimodal lowering.
//!
//! Each protocol has two halves without I/O: lowering a core request to the
//! wire, and a parser fed one server-sent event at a time. Only the fields
//! Max reads get types; everything the provider sends back for itself is
//! kept as raw JSON in an item's `opaque` and replayed as it came.

pub mod chat;
mod client;
mod error;
mod meter;
pub mod responses;

pub use client::{Call, Client, Provider};
pub use error::Error;
pub use meter::Meter;

use std::borrow::Cow;
use std::collections::BTreeMap;
use std::fmt;

use base64::display::Base64Display;
use base64::engine::general_purpose::STANDARD;
use max_core::item::{Image, Item, ItemKind, Part, ToolOutput, Usage};
use max_core::message::MediaRef;
use max_core::tools::ToolSpec;
use serde::{Serialize, Serializer};
use serde_json::value::RawValue;

/// Per-call settings the core's request doesn't carry.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Options {
    /// Reasoning effort, as the provider spells it.
    pub effort: Option<String>,
    pub temperature: Option<f64>,
    pub top_p: Option<f64>,
    /// Mark where each stable block of the context ends, for servers that
    /// cache a prefix only where told to (NInfer). Chat only.
    pub cache_breakpoints: bool,
}

/// The pictures a request's items name: a row's by handle, a tool
/// result's by SHA-256; and the videos tool results show, by SHA-256.
/// `max` reads them before the call. One it couldn't read, or that isn't
/// downloaded, is left out of the request; its handle is still in the
/// text.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Pictures(pub BTreeMap<String, Medium>);

/// A picture's or a video's file. It goes out as a data URL, base64'd as
/// the body is written: no copy of it is made for the request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Medium {
    pub mime: &'static str,
    pub bytes: Vec<u8>,
}

/// A piece of a user item's content.
enum Piece<'a> {
    Text(Cow<'a, str>),
    Picture(&'a Medium),
    /// An MP4.
    Video(&'a Medium),
}

/// A medium as its data URL.
struct DataUrl<'a>(&'a Medium);

impl Serialize for DataUrl<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let Medium { mime, bytes } = self.0;
        let base64 = Base64Display::new(bytes, &STANDARD);
        serializer.collect_str(&format_args!("data:{mime};base64,{base64}"))
    }
}

/// Texts joined as they are written, not into a string first.
struct Joined<T>(Vec<T>, &'static str);

impl<T: AsRef<str>> fmt::Display for Joined<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for (n, text) in self.0.iter().enumerate() {
            if n > 0 {
                f.write_str(self.1)?;
            }
            f.write_str(text.as_ref())?;
        }
        Ok(())
    }
}

impl<T: AsRef<str>> Serialize for Joined<T> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}

/// A user item's content: its text, with each picture after its handle
/// right after the line of its row, so that it is next to who sent it; at
/// the end if no line names it. All went at the end until 2026-11-04,
/// where the model had to match handles to rows to tell whose was whose.
/// None when there are no pictures to send, so the content stays a plain
/// string, as it was before pictures.
fn pieces<'a>(
    text: &'a str,
    images: &'a [Image],
    pictures: &'a Pictures,
) -> Option<Vec<Piece<'a>>> {
    let mut placed: Vec<(usize, String, &Medium)> = images
        .iter()
        .filter_map(|image| {
            let handle = image.handle();
            let medium = pictures.0.get(&handle)?;
            let at = after_line(text, &handle).unwrap_or(text.len());
            Some((at, handle, medium))
        })
        .collect();
    if placed.is_empty() {
        return None;
    }
    placed.sort_by_key(|(at, ..)| *at);
    let mut pieces = Vec::new();
    let mut from = 0;
    for (at, handle, medium) in placed {
        if at > from {
            pieces.push(Piece::Text(text[from..at].into()));
            from = at;
        }
        pieces.push(Piece::Text(format!("[{handle}]").into()));
        pieces.push(Piece::Picture(medium));
    }
    if from < text.len() {
        pieces.push(Piece::Text(text[from..].into()));
    }
    Some(pieces)
}

/// Where the last line naming `handle` ends, after its newline: rows come
/// after the memory, which could name one too.
fn after_line(text: &str, handle: &str) -> Option<usize> {
    let named = format!("[{handle}");
    let at = text
        .rmatch_indices(&named)
        .map(|(at, _)| at)
        .find(|at| text[at + named.len()..].starts_with([']', ':']))?;
    Some(text[at..].find('\n').map_or(text.len(), |end| at + end + 1))
}

/// A tool's parameter schema, as max-core writes it. max-core's tests
/// check that each parses.
fn schema(tool: &ToolSpec) -> &'static RawValue {
    serde_json::from_str(tool.parameters).expect("max-core's tool schemas are JSON")
}

/// What a tool result says where a picture was that the request doesn't
/// carry: an old one, past the budget, or one gone from the store.
const LEFT_OUT: &str = "[这张图省略了，要看再 tools.show]";
/// And where a video was.
const VIDEO_LEFT_OUT: &str = "[这段视频省略了，要看再 tools.video]";

/// A tool result's pieces: its text, and the pictures and videos it shows.
fn tool_pieces<'a>(output: &'a ToolOutput, pictures: &'a Pictures) -> Vec<Piece<'a>> {
    output
        .parts
        .iter()
        .map(|part| match part {
            Part::Text { text } => Piece::Text(text.into()),
            Part::Media {
                media: MediaRef::Blob(sha256),
            } => pictures
                .0
                .get(sha256)
                .map_or(Piece::Text(LEFT_OUT.into()), Piece::Picture),
            Part::Media { .. } => Piece::Text(LEFT_OUT.into()),
            Part::Video {
                media: MediaRef::Blob(sha256),
                ..
            } => pictures
                .0
                .get(sha256)
                .map_or(Piece::Text(VIDEO_LEFT_OUT.into()), Piece::Video),
            Part::Video { .. } => Piece::Text(VIDEO_LEFT_OUT.into()),
        })
        .collect()
}

/// The pieces' texts, if there is no picture or video among them; else
/// the pieces.
fn plain(pieces: Vec<Piece<'_>>) -> Result<Vec<Cow<'_, str>>, Vec<Piece<'_>>> {
    if !pieces.iter().all(|piece| matches!(piece, Piece::Text(_))) {
        return Err(pieces);
    }
    Ok(pieces
        .into_iter()
        .filter_map(|piece| match piece {
            Piece::Text(text) => Some(text),
            Piece::Picture(_) | Piece::Video(_) => None,
        })
        .collect())
}

/// Spreads the provider's output count over the items it produced, by the
/// length of what each holds: reasoning items share the reasoning tokens,
/// the rest share the remainder. An item's tokens are what it will cost
/// when sent again, so reasoning the provider kept to itself, with no item
/// to carry it, counts for nothing.
fn share_tokens(items: &mut [Item], usage: &Usage) {
    let visible = usage.output.saturating_sub(usage.reasoning);
    let (reasoning, rest): (Vec<_>, Vec<_>) = items
        .iter_mut()
        .partition(|item| matches!(item.kind, ItemKind::Reasoning { .. }));
    spread(reasoning, usage.reasoning);
    spread(rest, visible);
}

fn spread(mut items: Vec<&mut Item>, total: u32) {
    let weights: Vec<u64> = items.iter().map(|item| weight(item)).collect();
    let sum: u64 = weights.iter().sum();
    let mut left = total;
    for (item, weight) in items.iter_mut().zip(&weights) {
        let share = u32::try_from(u64::from(total) * weight / sum.max(1)).unwrap_or(total);
        item.tokens = share.min(left);
        left -= item.tokens;
    }
    if let Some(last) = items.last_mut() {
        last.tokens += left;
    }
}

fn weight(item: &Item) -> u64 {
    let length = match &item.kind {
        ItemKind::Assistant { text } => text.len(),
        ItemKind::Reasoning { text } => text.as_ref().map_or(0, String::len),
        ItemKind::ToolCall(call) => call.name.len() + call.arguments.len(),
        _ => 0,
    };
    u64::try_from(length).unwrap_or(u64::MAX).max(1)
}

#[cfg(test)]
mod tests {
    use max_core::ids::CallId;
    use max_core::item::ToolCall;

    use super::*;

    #[test]
    fn tokens_follow_the_text() {
        let mut items = vec![
            Item::new(ItemKind::Reasoning { text: None }, 0),
            Item::new(
                ItemKind::Assistant {
                    text: "a".repeat(30),
                },
                0,
            ),
            Item::new(
                ItemKind::ToolCall(ToolCall {
                    id: CallId("c".into()),
                    name: "run_code".into(),
                    arguments: "x".repeat(2),
                }),
                0,
            ),
        ];
        let usage = Usage {
            input: 1000,
            cached: 0,
            output: 141,
            reasoning: 100,
        };
        share_tokens(&mut items, &usage);
        let tokens: Vec<u32> = items.iter().map(|item| item.tokens).collect();
        assert_eq!(tokens, [100, 30, 11]);

        items.remove(0);
        share_tokens(&mut items, &usage);
        let tokens: Vec<u32> = items.iter().map(|item| item.tokens).collect();
        assert_eq!(tokens, [30, 11]);
    }
}
