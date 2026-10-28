//! What the model sees and says: base context, transcript and requests are
//! all made of items. Like messages, items are neutral and typed, with the
//! provider's own data carried along untouched in `opaque`; the protocol
//! adapters only remove or reshape when they lower a request.

use serde::{Deserialize, Serialize};

use crate::ids::CallId;
use crate::message::MediaRef;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Item {
    pub kind: ItemKind,
    /// For items the model produced: which protocol and model. An adapter
    /// drops `opaque` from another source.
    pub source: Option<ModelTag>,
    /// Provider fields the core carries but never reads, such as encrypted
    /// reasoning or a signature on a tool call.
    pub opaque: Option<serde_json::Value>,
    /// Estimated by `max` before the item reaches the core; for model
    /// output, from the provider's usage.
    pub tokens: u32,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ItemKind {
    System {
        text: String,
    },
    /// What Max is shown: context blocks and new inputs.
    User {
        text: String,
    },
    /// What the model wrote.
    Assistant {
        text: String,
    },
    /// The readable part of reasoning, if any; the rest is in `opaque`.
    Reasoning {
        text: Option<String>,
    },
    ToolCall(ToolCall),
    ToolResult {
        call: CallId,
        output: ToolOutput,
    },
}

impl Item {
    /// An item `max` or the core wrote, not the model.
    pub fn new(kind: ItemKind, tokens: u32) -> Self {
        Self {
            kind,
            source: None,
            opaque: None,
            tokens,
        }
    }
}

/// A tool call as the model wrote it. The arguments are the model's JSON
/// text, which may not be valid; see `tools`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolCall {
    pub id: CallId,
    pub name: String,
    pub arguments: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolOutput {
    pub parts: Vec<Part>,
    pub error: bool,
    /// Estimated by `max`.
    pub tokens: u32,
}

impl ToolOutput {
    pub fn text(text: impl Into<String>, error: bool, tokens: u32) -> Self {
        Self {
            parts: vec![Part::Text { text: text.into() }],
            error,
            tokens,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Part {
    Text { text: String },
    Media { media: MediaRef },
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ModelTag {
    pub protocol: Protocol,
    pub model: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Protocol {
    Responses,
    Chat,
}

/// One model call's result.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ModelOutput {
    pub items: Vec<Item>,
    pub usage: Usage,
}

/// As the provider reported it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Usage {
    /// The whole request.
    pub input: u32,
    pub cached: u32,
    /// Including reasoning.
    pub output: u32,
    pub reasoning: u32,
}
