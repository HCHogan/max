//! What the model sees and says: base context, transcript and requests are
//! all made of items. Like messages, items are neutral and typed, with the
//! provider's own data carried along untouched in `opaque`; the protocol
//! adapters only remove or reshape when they lower a request.

use core::time::Duration;

use serde::{Deserialize, Serialize};

use crate::ids::{CallId, MessageId};
use crate::message::{MediaKind, MediaRef};

/// One thing the model is shown or says, with what it costs.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Item {
    /// What it is.
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

/// What an item is.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ItemKind {
    /// The system prompt.
    System {
        /// The prompt.
        text: String,
    },
    /// What Max is shown: context blocks and new inputs, and the pictures
    /// among them, after the text.
    User {
        /// What Max is shown.
        text: String,
        /// The pictures among it.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        images: Vec<Image>,
    },
    /// What the model wrote.
    Assistant {
        /// As the model wrote it.
        text: String,
    },
    /// The readable part of reasoning, if any; the rest is in `opaque`.
    Reasoning {
        /// What of the reasoning can be read, if any.
        text: Option<String>,
    },
    /// A tool call the model wrote.
    ToolCall(ToolCall),
    /// What a tool call came to.
    ToolResult {
        /// The call it answers.
        call: CallId,
        /// What the tool gave.
        output: ToolOutput,
    },
}

/// A picture the model is shown: which medium of which row. The item
/// holds only the reference; `max` finds the version made for the model
/// when it sends a request, so a row's picture can still be downloading
/// when the row is shown.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Image {
    /// A picture or a sticker.
    pub kind: MediaKind,
    /// The row it is in.
    pub message: MessageId,
    /// Which of the row's media it is, from 0.
    pub ordinal: u16,
}

impl Image {
    /// What the text names it by: `image#123.0`.
    #[must_use]
    pub fn handle(&self) -> String {
        format!("{}#{}.{}", self.kind, self.message, self.ordinal)
    }
}

impl ItemKind {
    /// Text Max is shown, with no pictures.
    pub fn user(text: impl Into<String>) -> Self {
        Self::User {
            text: text.into(),
            images: Vec::new(),
        }
    }
}

impl Item {
    /// An item `max` or the core wrote, not the model.
    #[must_use]
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
    /// The provider's id for the call.
    pub id: CallId,
    /// The tool it names.
    pub name: String,
    /// The arguments, as the model wrote them.
    pub arguments: String,
}

/// What a tool call gave the model.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolOutput {
    /// Its text, and the pictures and videos it shows.
    pub parts: Vec<Part>,
    /// Whether the call failed.
    pub error: bool,
    /// Estimated by `max`.
    pub tokens: u32,
}

impl ToolOutput {
    /// An output that is text alone.
    pub fn text(text: impl Into<String>, error: bool, tokens: u32) -> Self {
        Self {
            parts: vec![Part::Text { text: text.into() }],
            error,
            tokens,
        }
    }
}

/// A piece of a tool's output.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Part {
    /// Text.
    Text {
        /// As the tool gave it.
        text: String,
    },
    /// A picture.
    Media {
        /// The file.
        media: MediaRef,
    },
    /// An MP4 the model watches, sound and all; `seconds` long.
    Video {
        /// The file.
        media: MediaRef,
        /// How long it runs.
        seconds: u32,
    },
}

/// Which model said something, and in which protocol.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ModelTag {
    /// How it is spoken to.
    pub protocol: Protocol,
    /// The id sent to the API.
    pub model: String,
}

/// A provider's wire protocol.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Protocol {
    /// OpenAI's Responses.
    Responses,
    /// Chat Completions.
    Chat,
}

/// One model call's result.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ModelOutput {
    /// What the model produced, in order.
    pub items: Vec<Item>,
    /// What the call used.
    pub usage: Usage,
}

/// As the provider reported it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Usage {
    /// The whole request.
    pub input: u32,
    /// Of the input, how much the provider read from its cache.
    pub cached: u32,
    /// Including reasoning.
    pub output: u32,
    /// Of the output, how much was reasoning.
    pub reasoning: u32,
}

/// How a model call went in time, from sending the request, as max-llm
/// measured it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Timing {
    /// Until the model's first output: text, reasoning or a tool call.
    /// None when it gave none.
    pub first: Option<Duration>,
    /// Until the end of the answer.
    pub took: Duration,
    /// The longest anything took to arrive: the response's start, or the
    /// next event after one. It is what the stream's idle timeout cuts.
    pub quiet: Duration,
}
