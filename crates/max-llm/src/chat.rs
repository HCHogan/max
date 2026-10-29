//! Chat Completions, as DeepSeek, vLLM, opencode and cliproxy's Gemini
//! serve it.
//!
//! One model call is one assistant message on the wire, so the items a
//! call produced are put back together into one. Providers add their own
//! fields to that message (`reasoning_content`, `reasoning`) and to tool
//! calls (Gemini's signatures in `extra_content`); those are kept raw in
//! `opaque` and merged back when the same model sees them again. Models
//! that write their reasoning inline, as a leading `<think>` block, get it
//! split off so it isn't said.

use std::collections::BTreeMap;

use max_core::ids::CallId;
use max_core::item::{Item, ItemKind, ModelOutput, ModelTag, ToolCall, Usage};
use max_core::run::Request;
use serde_json::{Map, Value, json};

use crate::{Error, Event, Options, share_tokens, tool_text};

const THINK: &str = "<think>";
const UNTHINK: &str = "</think>";

/// The request body.
pub fn body(request: &Request, options: &Options) -> Value {
    let mut messages = Vec::new();
    let mut turn: Option<Assistant> = None;
    for (index, item) in request.items.iter().enumerate() {
        let ours = item.source.as_ref() == Some(&request.model);
        let raw = item.opaque.as_ref().filter(|_| ours);
        // What a model wrote, as opposed to what Max shows it.
        let modeled = item.source.is_some()
            && matches!(
                item.kind,
                ItemKind::Assistant { .. } | ItemKind::Reasoning { .. } | ItemKind::ToolCall(_)
            );
        if !modeled {
            messages.extend(turn.take().map(Assistant::message));
        }
        match &item.kind {
            ItemKind::System { text } => {
                messages.push(json!({ "role": "system", "content": text }))
            }
            // The base context's blocks are user items in a row, the most
            // volatile last; the end of each before it is a stable prefix.
            ItemKind::User { text, .. }
                if options.cache_breakpoints
                    && matches!(
                        request.items.get(index + 1).map(|next| &next.kind),
                        Some(ItemKind::User { .. })
                    ) =>
            {
                messages.push(json!({
                    "role": "user",
                    "content": [{
                        "type": "text",
                        "text": text,
                        "prompt_cache_breakpoint": { "mode": "explicit" },
                    }],
                }));
            }
            ItemKind::User { text, .. } => {
                messages.push(json!({ "role": "user", "content": text }))
            }
            ItemKind::Assistant { text } if modeled => {
                turn.get_or_insert_default().content.push_str(text);
            }
            ItemKind::Assistant { text } => {
                messages.push(json!({ "role": "assistant", "content": text }));
            }
            ItemKind::Reasoning { text } => {
                // Another model's reasoning means nothing to this one.
                if let Some(raw) = raw {
                    let turn = turn.get_or_insert_default();
                    if let Some(fields) = raw["message"].as_object() {
                        turn.fields.extend(fields.clone());
                    }
                    if raw["inline"] == true {
                        turn.think = text.clone();
                    }
                }
            }
            ItemKind::ToolCall(call) => {
                let mut wire = json!({
                    "id": call.id,
                    "type": "function",
                    "function": { "name": call.name, "arguments": call.arguments },
                });
                if let (Some(extra), Some(wire)) =
                    (raw.and_then(Value::as_object), wire.as_object_mut())
                {
                    wire.extend(extra.clone());
                }
                turn.get_or_insert_default().calls.push(wire);
            }
            ItemKind::ToolResult { call, output } => messages.push(json!({
                "role": "tool",
                "tool_call_id": call,
                "content": tool_text(output),
            })),
        }
    }
    messages.extend(turn.map(Assistant::message));

    let mut body = Map::new();
    body.insert("model".into(), json!(request.model.model));
    body.insert("messages".into(), Value::Array(messages));
    body.insert("stream".into(), json!(true));
    body.insert("stream_options".into(), json!({ "include_usage": true }));
    if let Some(max) = request.max_output {
        body.insert("max_tokens".into(), json!(max));
    }
    if let Some(effort) = &options.effort {
        body.insert("reasoning_effort".into(), json!(effort));
    }
    if let Some(temperature) = options.temperature {
        body.insert("temperature".into(), json!(temperature));
    }
    if let Some(top_p) = options.top_p {
        body.insert("top_p".into(), json!(top_p));
    }
    if !request.tools.is_empty() {
        let tools: Vec<Value> = request
            .tools
            .iter()
            .map(|tool| {
                json!({
                    "type": "function",
                    "function": {
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": crate::schema(tool),
                    },
                })
            })
            .collect();
        body.insert("tools".into(), Value::Array(tools));
        body.insert("tool_choice".into(), json!("auto"));
    }
    Value::Object(body)
}

/// One model call's items, on their way back to one message.
#[derive(Default)]
struct Assistant {
    content: String,
    think: Option<String>,
    fields: Map<String, Value>,
    calls: Vec<Value>,
}

impl Assistant {
    fn message(self) -> Value {
        let content = match self.think {
            Some(think) => format!("{THINK}\n{think}\n{UNTHINK}\n\n{}", self.content),
            None => self.content,
        };
        let mut message = self.fields;
        message.insert("role".into(), json!("assistant"));
        message.insert("content".into(), json!(content));
        if !self.calls.is_empty() {
            message.insert("tool_calls".into(), Value::Array(self.calls));
        }
        Value::Object(message)
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
    /// Only whitespace or the start of `<think>` so far, held back.
    Undecided(String),
    Inside(String),
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

    pub fn event(&mut self, data: &str) -> Result<Vec<Event>, Error> {
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
                            events.push(Event::Text(text));
                        }
                    }
                    "tool_calls" => {
                        let calls = value.as_array().map(Vec::as_slice).unwrap_or_default();
                        for (position, call) in calls.iter().enumerate() {
                            events.extend(self.call(position, call));
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
            Think::Undecided(_) => None,
        };
        let mut items = Vec::new();
        let text = ["reasoning_content", "reasoning"]
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
    /// taken out.
    fn content(&mut self, delta: &str) -> String {
        match &mut self.think {
            Think::Outside { .. } => delta.to_owned(),
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
                    let text = std::mem::take(held);
                    self.think = Think::Outside { reasoning: None };
                    text
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

    /// A piece of a tool call; announces the call once its name is known.
    fn call(&mut self, position: usize, delta: &Value) -> Option<Event> {
        let index = delta["index"]
            .as_u64()
            .unwrap_or(u64::try_from(position).unwrap_or_default());
        let call = self.calls.entry(index).or_default();
        let unnamed = call.name.is_empty();
        for (field, value) in delta.as_object()? {
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
        (unnamed && !call.name.is_empty()).then(|| Event::ToolCall {
            name: call.name.clone(),
        })
    }
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
