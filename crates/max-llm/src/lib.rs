//! Adapters between Max's core and the model providers: Responses and Chat
//! Completions, streaming, reasoning passthrough and multimodal lowering.
//!
//! Each protocol has two halves without I/O: lowering a core request to the
//! wire, and a parser fed one server-sent event at a time. Only the fields
//! Max reads get types; everything the provider sends back for itself is
//! kept as raw JSON in an item's `opaque` and replayed as it came.

pub mod chat;
mod error;
pub mod responses;

pub use error::Error;

use max_core::item::{Item, ItemKind, Part, ToolOutput, Usage};
use max_core::tools::ToolSpec;
use serde_json::Value;

/// Per-call settings the core's request doesn't carry.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Options {
    /// Reasoning effort, as the provider spells it.
    pub effort: Option<String>,
    pub temperature: Option<f64>,
    pub top_p: Option<f64>,
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
/// the rest share the remainder. The totals stay exact.
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
    }
}
