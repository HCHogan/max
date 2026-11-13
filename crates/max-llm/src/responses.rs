//! OpenAI's Responses API, as cliproxy serves it.
//!
//! Requests are stateless: `store: false`, and reasoning comes back
//! encrypted so it can be replayed. The final items are taken whole from
//! `response.completed` and kept raw in `opaque`, so a replay is byte for
//! byte what the provider produced; the deltas before it only feed what
//! is said while it streams.

use std::borrow::Cow;

use max_core::ids::CallId;
use max_core::item::{Image, Item, ItemKind, ModelOutput, ModelTag, ToolCall, ToolOutput, Usage};
use max_core::run::Request;
use serde::Serialize;
use serde_json::Value;
use serde_json::value::RawValue;
use tracing::warn;

use crate::{
    DataUrl, Error, Joined, Options, Pictures, Piece, pieces, plain, schema, share_tokens,
    tool_pieces,
};

/// What a tool result says where a video was: Responses takes none.
const NO_VIDEO: &str = "[这里有一段视频，这个模型看不了]";

/// A request body. It borrows the request and its pictures, and is
/// written straight from them.
#[derive(Serialize)]
pub struct Body<'a> {
    model: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    instructions: Option<Joined<&'a str>>,
    input: Vec<Input<'a>>,
    stream: bool,
    store: bool,
    include: [&'static str; 1],
    #[serde(skip_serializing_if = "Option::is_none")]
    max_output_tokens: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reasoning: Option<Reasoning<'a>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    temperature: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    top_p: Option<f64>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    tools: Vec<Tool<'a>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tool_choice: Option<&'static str>,
}

#[derive(Serialize)]
#[serde(untagged)]
enum Input<'a> {
    /// As the provider sent it.
    Raw(&'a Value),
    Message {
        role: &'static str,
        content: Content<'a>,
    },
    Typed(Typed<'a>),
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Typed<'a> {
    FunctionCall {
        call_id: &'a CallId,
        name: &'a str,
        arguments: &'a str,
    },
    FunctionCallOutput {
        call_id: &'a CallId,
        output: Content<'a>,
    },
}

#[derive(Serialize)]
#[serde(untagged)]
enum Content<'a> {
    Text(&'a str),
    Lines(Joined<Cow<'a, str>>),
    Parts(Vec<Part<'a>>),
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Part<'a> {
    InputText {
        text: Cow<'a, str>,
    },
    InputImage {
        image_url: DataUrl<'a>,
        detail: &'static str,
    },
}

#[derive(Serialize)]
struct Reasoning<'a> {
    effort: &'a str,
    summary: &'static str,
}

#[derive(Serialize)]
struct Tool<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    name: &'a str,
    description: &'a str,
    parameters: &'static RawValue,
    strict: bool,
}

/// The request body.
pub fn body<'a>(request: &'a Request, options: &'a Options, pictures: &'a Pictures) -> Body<'a> {
    let mut instructions = Vec::new();
    let mut input = Vec::new();
    for item in &request.items {
        // Provider data from another model means nothing to this one.
        let ours = item.source.as_ref() == Some(&request.model);
        let raw = item.opaque.as_ref().filter(|_| ours);
        match &item.kind {
            ItemKind::System { text } => instructions.push(text.as_str()),
            ItemKind::User { text, images } => input.push(Input::Message {
                role: "user",
                content: user_content(text, images, pictures),
            }),
            ItemKind::Assistant { text } => input.push(match raw {
                Some(raw) => Input::Raw(raw),
                None => Input::Message {
                    role: "assistant",
                    content: Content::Text(text),
                },
            }),
            // Without its encrypted content, reasoning can't be replayed.
            ItemKind::Reasoning { .. } => input.extend(raw.map(Input::Raw)),
            ItemKind::ToolCall(call) => input.push(match raw {
                Some(raw) => Input::Raw(raw),
                None => Input::Typed(Typed::FunctionCall {
                    call_id: &call.id,
                    name: &call.name,
                    arguments: &call.arguments,
                }),
            }),
            ItemKind::ToolResult { call, output } => {
                input.push(Input::Typed(Typed::FunctionCallOutput {
                    call_id: call,
                    output: tool_output(output, pictures),
                }));
            }
        }
    }
    // Strict is the default here, and it would make every optional
    // parameter required.
    let tools: Vec<Tool<'_>> = request
        .tools
        .iter()
        .map(|tool| Tool {
            kind: "function",
            name: tool.name,
            description: &tool.description,
            parameters: schema(tool),
            strict: false,
        })
        .collect();
    Body {
        model: &request.model.model,
        instructions: (!instructions.is_empty()).then_some(Joined(instructions, "\n\n")),
        input,
        stream: true,
        store: false,
        include: ["reasoning.encrypted_content"],
        max_output_tokens: request.max_output,
        reasoning: options.effort.as_deref().map(|effort| Reasoning {
            effort,
            summary: "auto",
        }),
        temperature: options.temperature,
        top_p: options.top_p,
        tool_choice: (!tools.is_empty()).then_some("auto"),
        tools,
    }
}

fn user_content<'a>(text: &'a str, images: &'a [Image], pictures: &'a Pictures) -> Content<'a> {
    match pieces(text, images, pictures) {
        None => Content::Text(text),
        Some(pieces) => Content::Parts(pieces.into_iter().map(wire).collect()),
    }
}

/// A tool result's output: its text, or with pictures, its pieces.
fn tool_output<'a>(output: &'a ToolOutput, pictures: &'a Pictures) -> Content<'a> {
    match plain(tool_pieces(output, pictures)) {
        Ok(texts) => Content::Lines(Joined(texts, "\n")),
        Err(pieces) => Content::Parts(pieces.into_iter().map(wire).collect()),
    }
}

fn wire(piece: Piece<'_>) -> Part<'_> {
    match piece {
        Piece::Text(text) => Part::InputText { text },
        Piece::Picture(medium) => Part::InputImage {
            image_url: DataUrl(medium),
            detail: "auto",
        },
        // tools.video refuses on a model that doesn't watch videos.
        Piece::Video(_) => Part::InputText {
            text: NO_VIDEO.into(),
        },
    }
}

/// Reads a streamed response, one event's data at a time.
#[derive(Debug)]
pub struct Parser {
    model: ModelTag,
    started: bool,
    output: Option<ModelOutput>,
}

impl Parser {
    pub fn new(model: ModelTag) -> Self {
        Self {
            model,
            started: false,
            output: None,
        }
    }

    /// The model has begun to answer: an output item, reasoning included,
    /// has started.
    pub fn started(&self) -> bool {
        self.started
    }

    /// The response is complete; nothing after this matters.
    pub fn finished(&self) -> bool {
        self.output.is_some()
    }

    /// One event: the text in it to be said.
    pub fn event(&mut self, data: &str) -> Result<Vec<String>, Error> {
        let mut event: Value = serde_json::from_str(data).map_err(Error::malformed)?;
        let text = |field: &str| event[field].as_str().unwrap_or_default().to_owned();
        let kind = event["type"].as_str().unwrap_or_default();
        self.started |= kind.starts_with("response.output_item.");
        match kind {
            "response.output_text.delta" => Ok(vec![text("delta")]),
            "response.completed" => {
                self.output = Some(self.complete(event["response"].take()));
                Ok(Vec::new())
            }
            "response.incomplete" => {
                let reason = &event["response"]["incomplete_details"]["reason"];
                Err(Error::Incomplete(
                    reason.as_str().unwrap_or("unknown").to_owned(),
                ))
            }
            "response.failed" => Err(Error::provider(&event["response"]["error"])),
            "error" => Err(Error::provider(&event)),
            _ => Ok(Vec::new()),
        }
    }

    /// The stream has ended.
    pub fn finish(self) -> Result<ModelOutput, Error> {
        self.output.ok_or(Error::Truncated)
    }

    fn complete(&self, mut response: Value) -> ModelOutput {
        let usage = usage(&response["usage"]);
        let output = match response["output"].take() {
            Value::Array(output) => output,
            _ => Vec::new(),
        };
        let mut items: Vec<Item> = output
            .into_iter()
            .filter_map(|raw| {
                let kind = kind(&raw)?;
                Some(Item {
                    kind,
                    source: Some(self.model.clone()),
                    opaque: Some(raw),
                    tokens: 0,
                })
            })
            .collect();
        share_tokens(&mut items, &usage);
        ModelOutput { items, usage }
    }
}

fn kind(raw: &Value) -> Option<ItemKind> {
    let texts = |list: &Value, types: &[&str], field: &str| -> Vec<String> {
        list.as_array()
            .map(Vec::as_slice)
            .unwrap_or_default()
            .iter()
            .filter(|part| types.iter().any(|t| part["type"] == *t))
            .filter_map(|part| part[field].as_str().map(str::to_owned))
            .collect()
    };
    match raw["type"].as_str().unwrap_or_default() {
        "reasoning" => {
            let mut text = texts(&raw["summary"], &["summary_text"], "text");
            if text.is_empty() {
                text = texts(&raw["content"], &["reasoning_text"], "text");
            }
            let text = Some(text.join("\n\n")).filter(|text| !text.is_empty());
            Some(ItemKind::Reasoning { text })
        }
        "message" => {
            let mut text = texts(&raw["content"], &["output_text"], "text");
            text.extend(texts(&raw["content"], &["refusal"], "refusal"));
            Some(ItemKind::Assistant {
                text: text.concat(),
            })
        }
        "function_call" => Some(ItemKind::ToolCall(ToolCall {
            id: CallId(raw["call_id"].as_str().unwrap_or_default().to_owned()),
            name: raw["name"].as_str().unwrap_or_default().to_owned(),
            arguments: raw["arguments"].as_str().unwrap_or_default().to_owned(),
        })),
        other => {
            warn!(r#type = other, "dropping an output item Max doesn't use");
            None
        }
    }
}

pub(crate) fn usage(usage: &Value) -> Usage {
    let count = |value: &Value| u32::try_from(value.as_u64().unwrap_or(0)).unwrap_or(u32::MAX);
    Usage {
        input: count(&usage["input_tokens"]),
        cached: count(&usage["input_tokens_details"]["cached_tokens"]),
        output: count(&usage["output_tokens"]),
        reasoning: count(&usage["output_tokens_details"]["reasoning_tokens"]),
    }
}

#[cfg(test)]
mod tests;
