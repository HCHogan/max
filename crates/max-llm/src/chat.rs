//! Chat Completions, as DeepSeek, vLLM, opencode and cliproxy's Gemini
//! serve it.
//!
//! One model call is one assistant message on the wire, so the items a
//! call produced are put back together into one. Providers add their own
//! fields to that message (`reasoning_content`, `reasoning`) and to tool
//! calls (Gemini's signatures in `extra_content`); those are kept raw in
//! `opaque` and merged back when the same model sees them again. Models
//! that write their reasoning inline, as a leading `<think>` block, get it
//! split off so it isn't said. An answer that opens with a heading of
//! reasoning, as Gemini's sometimes does when it skips thinking, isn't
//! said at all: the call fails, to be made again.
//!
//! A tool message holds only text, and some providers take nothing else
//! there; the pictures and videos tool results show follow them in a user
//! message. A video is a `video_url` part, as cliproxy takes it for Gemini.

use std::borrow::Cow;
use std::collections::BTreeMap;
use std::fmt;

use max_core::ids::CallId;
use max_core::item::{Image, Item, ItemKind, ModelOutput, ModelTag, ToolCall, Usage};
use max_core::run::Request;
use serde::ser::SerializeMap;
use serde::{Serialize, Serializer};
use serde_json::value::RawValue;
use serde_json::{Map, Value, json};

use crate::{
    DataUrl, Error, Joined, Options, Pictures, Piece, pieces, schema, share_tokens, tool_pieces,
};

const THINK: &str = "<think>";
const UNTHINK: &str = "</think>";
/// The fields of the message that providers stream reasoning in.
const REASONING: [&str; 2] = ["reasoning_content", "reasoning"];
/// Headings an answer that is reasoning written out opens with, in lower
/// case. Seen 2026-10-29: Gemini 4 Argon, with no thinking tokens, wrote
/// `Thinking Process:` and its numbered steps, and the group saw them.
const ALOUD: [&str; 3] = ["thinking process", "thought process", "思考过程"];

/// A request body. It borrows the request and its pictures, and is
/// written straight from them.
#[derive(Serialize)]
pub struct Body<'a> {
    model: &'a str,
    messages: Vec<Message<'a>>,
    stream: bool,
    stream_options: StreamOptions,
    #[serde(skip_serializing_if = "Option::is_none")]
    max_tokens: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reasoning_effort: Option<&'a str>,
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
struct StreamOptions {
    include_usage: bool,
}

#[derive(Serialize)]
#[serde(untagged)]
enum Message<'a> {
    Plain {
        role: &'static str,
        content: Content<'a>,
    },
    Tool {
        role: &'static str,
        tool_call_id: &'a CallId,
        content: Joined<Cow<'a, str>>,
    },
    Assistant(Assistant<'a>),
}

#[derive(Serialize)]
#[serde(untagged)]
enum Content<'a> {
    Text(&'a str),
    Parts(Vec<Part<'a>>),
}

#[derive(Serialize)]
struct Part<'a> {
    #[serde(flatten)]
    kind: PartKind<'a>,
    #[serde(skip_serializing_if = "Option::is_none")]
    prompt_cache_breakpoint: Option<Breakpoint>,
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum PartKind<'a> {
    Text { text: Cow<'a, str> },
    ImageUrl { image_url: Url<'a> },
    VideoUrl { video_url: Url<'a> },
}

#[derive(Serialize)]
struct Url<'a> {
    url: DataUrl<'a>,
}

#[derive(Serialize)]
struct Breakpoint {
    mode: &'static str,
}

#[derive(Serialize)]
struct Tool<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    function: Function<'a>,
}

#[derive(Serialize)]
struct Function<'a> {
    name: &'a str,
    description: &'a str,
    parameters: &'static RawValue,
}

/// The request body.
pub fn body<'a>(request: &'a Request, options: &'a Options, pictures: &'a Pictures) -> Body<'a> {
    let mut messages = Vec::new();
    let mut turn: Option<Assistant<'a>> = None;
    // The pictures and videos of the tool results so far in a row.
    let mut shown: Vec<Piece<'a>> = Vec::new();
    for (index, item) in request.items.iter().enumerate() {
        if !matches!(item.kind, ItemKind::ToolResult { .. }) && !shown.is_empty() {
            messages.push(pictures_shown(std::mem::take(&mut shown)));
        }
        let ours = item.source.as_ref() == Some(&request.model);
        let raw = item.opaque.as_ref().filter(|_| ours);
        // What a model wrote, as opposed to what Max shows it.
        let modeled = item.source.is_some()
            && matches!(
                item.kind,
                ItemKind::Assistant { .. } | ItemKind::Reasoning { .. } | ItemKind::ToolCall(_)
            );
        if !modeled {
            messages.extend(turn.take().map(Message::Assistant));
        }
        match &item.kind {
            ItemKind::System { text } => messages.push(Message::Plain {
                role: "system",
                content: Content::Text(text),
            }),
            ItemKind::User { text, images } => {
                // The base context's blocks are user items in a row, the
                // most volatile last; the end of each before it is a
                // stable prefix.
                let breakpoint = options.cache_breakpoints
                    && matches!(
                        request.items.get(index + 1).map(|next| &next.kind),
                        Some(ItemKind::User { .. })
                    );
                messages.push(Message::Plain {
                    role: "user",
                    content: user_content(text, images, pictures, breakpoint),
                });
            }
            ItemKind::Assistant { text } if modeled => {
                turn.get_or_insert_default().content.push(text);
            }
            ItemKind::Assistant { text } => messages.push(Message::Plain {
                role: "assistant",
                content: Content::Text(text),
            }),
            ItemKind::Reasoning { text } => {
                // Another model's reasoning means nothing to this one.
                if let Some(raw) = raw {
                    let turn = turn.get_or_insert_default();
                    if let Some(fields) = raw["message"].as_object() {
                        turn.fields.push(fields);
                    }
                    if raw["inline"] == true {
                        turn.think = text.as_deref();
                    }
                }
            }
            ItemKind::ToolCall(call) => {
                let extra = raw.and_then(Value::as_object);
                turn.get_or_insert_default()
                    .calls
                    .push(WireCall { call, extra });
            }
            ItemKind::ToolResult { call, output } => {
                let mut text = Vec::new();
                for piece in tool_pieces(output, pictures) {
                    match piece {
                        Piece::Text(said) => text.push(said),
                        Piece::Picture(_) => {
                            shown.push(piece);
                            text.push(format!("[图 {}，见下]", shown.len()).into());
                        }
                        Piece::Video(_) => {
                            shown.push(piece);
                            text.push(format!("[视频 {}，见下]", shown.len()).into());
                        }
                    }
                }
                messages.push(Message::Tool {
                    role: "tool",
                    tool_call_id: call,
                    content: Joined(text, "\n"),
                });
            }
        }
    }
    if !shown.is_empty() {
        messages.push(pictures_shown(shown));
    }
    messages.extend(turn.map(Message::Assistant));

    let tools: Vec<Tool<'_>> = request
        .tools
        .iter()
        .map(|tool| Tool {
            kind: "function",
            function: Function {
                name: tool.name,
                description: &tool.description,
                parameters: schema(tool),
            },
        })
        .collect();
    Body {
        model: &request.model.model,
        messages,
        stream: true,
        stream_options: StreamOptions {
            include_usage: true,
        },
        max_tokens: request.max_output,
        reasoning_effort: options.effort.as_deref(),
        temperature: options.temperature,
        top_p: options.top_p,
        tool_choice: (!tools.is_empty()).then_some("auto"),
        tools,
    }
}

fn user_content<'a>(
    text: &'a str,
    images: &'a [Image],
    pictures: &'a Pictures,
    breakpoint: bool,
) -> Content<'a> {
    let pieces = match pieces(text, images, pictures) {
        None if !breakpoint => return Content::Text(text),
        None => vec![Piece::Text(text.into())],
        Some(pieces) => pieces,
    };
    let mut parts: Vec<Part<'_>> = pieces.into_iter().map(part).collect();
    if breakpoint && let Some(last) = parts.last_mut() {
        last.prompt_cache_breakpoint = Some(Breakpoint { mode: "explicit" });
    }
    Content::Parts(parts)
}

/// The pictures and videos of tool results in a row, numbered as their
/// text names them.
fn pictures_shown(shown: Vec<Piece<'_>>) -> Message<'_> {
    let content = (1..)
        .zip(shown)
        .flat_map(|(n, piece)| {
            let label = match piece {
                Piece::Video(_) => format!("[视频 {n}]"),
                _ => format!("[图 {n}]"),
            };
            [part(Piece::Text(label.into())), part(piece)]
        })
        .collect();
    Message::Plain {
        role: "user",
        content: Content::Parts(content),
    }
}

/// A piece's part: text, or a picture's or a video's URL.
fn part(piece: Piece<'_>) -> Part<'_> {
    let kind = match piece {
        Piece::Text(text) => PartKind::Text { text },
        Piece::Picture(medium) => PartKind::ImageUrl {
            image_url: Url {
                url: DataUrl(medium),
            },
        },
        Piece::Video(medium) => PartKind::VideoUrl {
            video_url: Url {
                url: DataUrl(medium),
            },
        },
    };
    Part {
        kind,
        prompt_cache_breakpoint: None,
    }
}

/// One model call's items, on their way back to one message.
#[derive(Default)]
struct Assistant<'a> {
    content: Vec<&'a str>,
    think: Option<&'a str>,
    /// The provider's own fields, from each reasoning item's `message`.
    fields: Vec<&'a Map<String, Value>>,
    calls: Vec<WireCall<'a>>,
}

impl Serialize for Assistant<'_> {
    /// The provider's fields, a later item's over an earlier one's, then
    /// the message's own.
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut fields: Vec<(&str, &Value)> = Vec::new();
        for (name, value) in self.fields.iter().copied().flatten() {
            if ["role", "content", "tool_calls"].contains(&name.as_str()) {
                continue;
            }
            match fields.iter_mut().find(|(have, _)| *have == name) {
                Some(field) => field.1 = value,
                None => fields.push((name, value)),
            }
        }
        let mut map = serializer.serialize_map(None)?;
        for (name, value) in fields {
            map.serialize_entry(name, value)?;
        }
        map.serialize_entry("role", "assistant")?;
        map.serialize_entry("content", &Said(self))?;
        if !self.calls.is_empty() {
            map.serialize_entry("tool_calls", &self.calls)?;
        }
        map.end()
    }
}

/// What the assistant message says: its inline reasoning back in its
/// `<think>` block, and its text.
struct Said<'a>(&'a Assistant<'a>);

impl fmt::Display for Said<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if let Some(think) = self.0.think {
            write!(f, "{THINK}\n{think}\n{UNTHINK}\n\n")?;
        }
        self.0.content.iter().try_for_each(|text| f.write_str(text))
    }
}

impl Serialize for Said<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}

/// A tool call, with the fields its provider added: one of those with
/// the name of a field of the call's own takes its place.
struct WireCall<'a> {
    call: &'a ToolCall,
    extra: Option<&'a Map<String, Value>>,
}

#[derive(Serialize)]
struct Called<'a> {
    name: &'a str,
    arguments: &'a str,
}

impl Serialize for WireCall<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        const OWN: [&str; 3] = ["id", "type", "function"];
        let extra = |name: &str| self.extra.and_then(|extra| extra.get(name));
        let mut map = serializer.serialize_map(None)?;
        match extra("id") {
            Some(value) => map.serialize_entry("id", value)?,
            None => map.serialize_entry("id", &self.call.id)?,
        }
        match extra("type") {
            Some(value) => map.serialize_entry("type", value)?,
            None => map.serialize_entry("type", "function")?,
        }
        match extra("function") {
            Some(value) => map.serialize_entry("function", value)?,
            None => map.serialize_entry(
                "function",
                &Called {
                    name: &self.call.name,
                    arguments: &self.call.arguments,
                },
            )?,
        }
        for (name, value) in self.extra.into_iter().flatten() {
            if !OWN.contains(&name.as_str()) {
                map.serialize_entry(name, value)?;
            }
        }
        map.end()
    }
}

/// Reads a streamed response, one event's data at a time.
#[derive(Debug)]
pub struct Parser {
    model: ModelTag,
    think: Think,
    text: String,
    /// The message's other fields, strings concatenated across deltas.
    fields: Map<String, Value>,
    calls: BTreeMap<u64, Call>,
    finish_reason: Option<String>,
    done: bool,
    usage: Usage,
}

/// Where the content is relative to a leading `<think>` block.
#[derive(Debug)]
enum Think {
    /// Only whitespace, the start of `<think>` or the start of a heading
    /// in [`ALOUD`] so far, held back.
    Undecided(String),
    Inside(String),
    /// The answer opened with a heading in [`ALOUD`].
    Aloud,
    /// After the block, or there was none.
    Outside {
        reasoning: Option<String>,
    },
}

#[derive(Debug, Default)]
struct Call {
    id: String,
    name: String,
    arguments: String,
    extra: Map<String, Value>,
}

impl Parser {
    pub fn new(model: ModelTag) -> Self {
        Self {
            model,
            think: Think::Undecided(String::new()),
            text: String::new(),
            fields: Map::new(),
            calls: BTreeMap::new(),
            finish_reason: None,
            done: false,
            usage: Usage::default(),
        }
    }

    /// The provider said `[DONE]`; nothing after this matters.
    pub fn finished(&self) -> bool {
        self.done
    }

    /// The model has begun to answer: text, reasoning or a tool call.
    pub fn started(&self) -> bool {
        let reasoning = REASONING.iter().any(|field| {
            self.fields
                .get(*field)
                .and_then(Value::as_str)
                .is_some_and(|text| !text.is_empty())
        });
        let text = match &self.think {
            Think::Undecided(held) => !held.trim().is_empty(),
            Think::Inside(_) | Think::Aloud | Think::Outside { .. } => true,
        };
        reasoning || text || !self.calls.is_empty()
    }

    /// One chunk: the text in it to be said.
    pub fn event(&mut self, data: &str) -> Result<Vec<String>, Error> {
        if data.trim() == "[DONE]" {
            self.done = true;
            return Ok(Vec::new());
        }
        let chunk: Value = serde_json::from_str(data).map_err(Error::malformed)?;
        if chunk.get("error").is_some_and(|error| !error.is_null()) {
            return Err(Error::provider(&chunk));
        }
        if chunk["usage"].is_object() {
            self.usage = usage(&chunk["usage"]);
        }
        let mut events = Vec::new();
        let Some(choice) = chunk["choices"].get(0) else {
            return Ok(events);
        };
        if let Some(delta) = choice["delta"].as_object() {
            for (field, value) in delta {
                match field.as_str() {
                    "role" => {}
                    "content" => {
                        let text = self.content(value.as_str().unwrap_or_default());
                        if !text.is_empty() {
                            self.text.push_str(&text);
                            events.push(text);
                        }
                    }
                    "tool_calls" => {
                        let calls = value.as_array().map(Vec::as_slice).unwrap_or_default();
                        for (position, call) in calls.iter().enumerate() {
                            self.call(position, call);
                        }
                    }
                    _ => merge(&mut self.fields, field, value),
                }
            }
        }
        if let Some(reason) = choice["finish_reason"].as_str() {
            self.finish_reason = Some(reason.to_owned());
        }
        Ok(events)
    }

    /// The stream has ended.
    pub fn finish(self) -> Result<ModelOutput, Error> {
        match self.finish_reason.as_deref() {
            None if !self.done => return Err(Error::Truncated),
            Some(reason @ ("length" | "content_filter")) => {
                return Err(Error::Incomplete(reason.to_owned()));
            }
            _ => {}
        }
        if matches!(self.think, Think::Aloud) {
            return Err(Error::Aloud);
        }
        let model = self.model;
        let item = |kind, opaque| Item {
            kind,
            source: Some(model.clone()),
            opaque,
            tokens: 0,
        };
        let inline = match self.think {
            Think::Inside(think) => Some(think),
            Think::Outside { reasoning } => reasoning,
            Think::Undecided(_) | Think::Aloud => None,
        };
        let mut items = Vec::new();
        let text = REASONING
            .iter()
            .find_map(|field| self.fields.get(*field)?.as_str())
            .map(str::to_owned)
            .or(inline.clone())
            .map(|text| text.trim().to_owned())
            .filter(|text| !text.is_empty());
        if text.is_some() || !self.fields.is_empty() {
            let mut raw = Map::new();
            if !self.fields.is_empty() {
                raw.insert("message".into(), Value::Object(self.fields));
            }
            if inline.is_some() {
                raw.insert("inline".into(), json!(true));
            }
            items.push(item(ItemKind::Reasoning { text }, Some(Value::Object(raw))));
        }
        if !self.text.is_empty() {
            let text = self.text.trim_start().to_owned();
            items.push(item(ItemKind::Assistant { text }, None));
        }
        for (index, call) in self.calls {
            let id = Some(call.id)
                .filter(|id| !id.is_empty())
                .unwrap_or_else(|| format!("call_{index}"));
            let kind = ItemKind::ToolCall(ToolCall {
                id: CallId(id),
                name: call.name,
                arguments: call.arguments,
            });
            let extra = Some(Value::Object(call.extra)).filter(|extra| extra != &json!({}));
            items.push(item(kind, extra));
        }
        share_tokens(&mut items, &self.usage);
        Ok(ModelOutput {
            items,
            usage: self.usage,
        })
    }

    /// Visible text from a content delta, with a leading `<think>` block
    /// taken out; none once the answer opened with a heading of reasoning.
    fn content(&mut self, delta: &str) -> String {
        match &mut self.think {
            Think::Outside { .. } => delta.to_owned(),
            Think::Aloud => String::new(),
            Think::Undecided(held) => {
                held.push_str(delta);
                let start = held.trim_start();
                if let Some(rest) = start.strip_prefix(THINK) {
                    let rest = rest.to_owned();
                    self.think = Think::Inside(String::new());
                    self.content(&rest)
                } else if THINK.starts_with(start) {
                    String::new()
                } else {
                    match aloud(start) {
                        None => String::new(),
                        Some(true) => {
                            self.think = Think::Aloud;
                            String::new()
                        }
                        Some(false) => {
                            let text = std::mem::take(held);
                            self.think = Think::Outside { reasoning: None };
                            text
                        }
                    }
                }
            }
            Think::Inside(think) => {
                think.push_str(delta);
                let Some(end) = think.find(UNTHINK) else {
                    return String::new();
                };
                let after = think[end + UNTHINK.len()..].trim_start().to_owned();
                think.truncate(end);
                self.think = Think::Outside {
                    reasoning: Some(std::mem::take(think)),
                };
                after
            }
        }
    }

    /// A piece of a tool call.
    fn call(&mut self, position: usize, delta: &Value) {
        let index = delta["index"]
            .as_u64()
            .unwrap_or(u64::try_from(position).unwrap_or_default());
        let call = self.calls.entry(index).or_default();
        let Some(delta) = delta.as_object() else {
            return;
        };
        for (field, value) in delta {
            match (field.as_str(), value) {
                ("index" | "type", _) => {}
                ("id", Value::String(id)) => call.id.clone_from(id),
                ("function", Value::Object(function)) => {
                    if let Some(name) = function.get("name").and_then(Value::as_str) {
                        call.name.push_str(name);
                    }
                    if let Some(arguments) = function.get("arguments").and_then(Value::as_str) {
                        call.arguments.push_str(arguments);
                    }
                }
                _ => merge(&mut call.extra, field, value),
            }
        }
    }
}

/// Whether the content opens with a heading in [`ALOUD`] on a line of its
/// own, such as `Thinking Process:` or `**Thought Process**`; None while
/// that can't be told yet.
fn aloud(start: &str) -> Option<bool> {
    let start = start.trim_start_matches(['*', '#', ' ']);
    let (line, ended) = match start.split_once('\n') {
        Some((line, _)) => (line, true),
        None => (start, false),
    };
    let heading = line
        .trim_end_matches(['*', ':', '：', ' ', '\r'])
        .to_ascii_lowercase();
    if ALOUD.contains(&heading.as_str()) {
        return ended.then_some(true);
    }
    let started = ALOUD.iter().any(|aloud| aloud.starts_with(&heading));
    (ended || !started).then_some(false)
}

/// A delta field into what has accumulated: strings and arrays grow,
/// anything else is replaced.
fn merge(fields: &mut Map<String, Value>, field: &str, value: &Value) {
    match (fields.get_mut(field), value) {
        (_, Value::Null) => {}
        (Some(Value::String(old)), Value::String(new)) => old.push_str(new),
        (Some(Value::Array(old)), Value::Array(new)) => old.extend(new.iter().cloned()),
        _ => {
            fields.insert(field.to_owned(), value.clone());
        }
    }
}

fn usage(usage: &Value) -> Usage {
    let count = |value: &Value| u32::try_from(value.as_u64().unwrap_or(0)).unwrap_or(u32::MAX);
    let cached = &usage["prompt_tokens_details"]["cached_tokens"];
    Usage {
        input: count(&usage["prompt_tokens"]),
        // DeepSeek reports cache hits its own way.
        cached: count(if cached.is_null() {
            &usage["prompt_cache_hit_tokens"]
        } else {
            cached
        }),
        output: count(&usage["completion_tokens"]),
        reasoning: count(&usage["completion_tokens_details"]["reasoning_tokens"]),
    }
}

#[cfg(test)]
mod tests;
