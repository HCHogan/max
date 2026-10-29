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
pub mod responses;

pub use client::{Call, Client, Provider};
pub use error::Error;

use std::borrow::Cow;
use std::collections::BTreeMap;

use max_core::item::{Image, Item, ItemKind, Part, ToolOutput, Usage};
use max_core::tools::ToolSpec;
use serde_json::Value;

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

/// The pictures a request's items name, as data URLs by handle. `max`
/// reads them before the call. One it couldn't read, or that isn't
/// downloaded, is left out of the request; its handle is still in the
/// text.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Pictures(pub BTreeMap<String, String>);

/// A piece of a user item's content.
enum Piece<'a> {
    Text(Cow<'a, str>),
    /// A data URL.
    Picture(&'a str),
}

/// A user item's content: its text, then each picture after its handle.
/// None when there are no pictures to send, so the content stays a plain
/// string, as it was before pictures.
fn pieces<'a>(
    text: &'a str,
    images: &'a [Image],
    pictures: &'a Pictures,
) -> Option<Vec<Piece<'a>>> {
    let mut pieces = vec![Piece::Text(text.into())];
    for image in images {
        let handle = image.handle();
        if let Some(url) = pictures.0.get(&handle) {
            pieces.push(Piece::Text(format!("[{handle}]").into()));
            pieces.push(Piece::Picture(url));
        }
    }
    (pieces.len() > 1).then_some(pieces)
}

/// What a call yields while the response streams in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    /// Text the model wrote, to be said.
    Text(String),
    /// The model began a tool call; its arguments are still coming.
    ToolCall { name: String },
}

/// A tool's parameter schema. max-core's tests check that each parses.
fn schema(tool: &ToolSpec) -> Value {
    serde_json::from_str(tool.parameters).expect("max-core's tool schemas are JSON")
}

/// A tool result as text. Media parts become placeholders until images
/// are lowered properly, with the VM's tools.
fn tool_text(output: &ToolOutput) -> String {
    output
        .parts
        .iter()
        .map(|part| match part {
            Part::Text { text } => text.as_str(),
            Part::Media { .. } => "[图片省略]",
        })
        .collect::<Vec<_>>()
        .join("\n")
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
