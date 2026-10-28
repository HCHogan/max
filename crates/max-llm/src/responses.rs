//! OpenAI's Responses API, as cliproxy serves it.
//!
//! Requests are stateless: `store: false`, and reasoning comes back
//! encrypted so it can be replayed. The final items are taken whole from
//! `response.completed` and kept raw in `opaque`, so a replay is byte for
//! byte what the provider produced; the deltas before it only feed what
//! is said while it streams.

use max_core::ids::CallId;
use max_core::item::{Item, ItemKind, ModelOutput, ModelTag, ToolCall, Usage};
use max_core::run::Request;
use serde_json::{Map, Value, json};
use tracing::warn;

use crate::{Error, Event, Options, share_tokens, tool_text};

/// The request body.
pub fn body(request: &Request, options: &Options) -> Value {
    let mut instructions = Vec::new();
    let mut input = Vec::new();
    for item in &request.items {
        // Provider data from another model means nothing to this one.
        let ours = item.source.as_ref() == Some(&request.model);
        let raw = item.opaque.as_ref().filter(|_| ours);
        match &item.kind {
            ItemKind::System { text } => instructions.push(text.as_str()),
            ItemKind::User { text } => input.push(json!({ "role": "user", "content": text })),
            ItemKind::Assistant { text } => input.push(match raw {
                Some(raw) => raw.clone(),
                None => json!({ "role": "assistant", "content": text }),
            }),
            // Without its encrypted content, reasoning can't be replayed.
            ItemKind::Reasoning { .. } => input.extend(raw.cloned()),
            ItemKind::ToolCall(call) => input.push(match raw {
                Some(raw) => raw.clone(),
                None => json!({
                    "type": "function_call",
                    "call_id": call.id,
                    "name": call.name,
                    "arguments": call.arguments,
                }),
            }),
            ItemKind::ToolResult { call, output } => input.push(json!({
                "type": "function_call_output",
                "call_id": call,
                "output": tool_text(output),
            })),
        }
    }

    let mut body = Map::new();
    body.insert("model".into(), json!(request.model.model));
    if !instructions.is_empty() {
        body.insert("instructions".into(), json!(instructions.join("\n\n")));
    }
    body.insert("input".into(), Value::Array(input));
    body.insert("stream".into(), json!(true));
    body.insert("store".into(), json!(false));
    body.insert("include".into(), json!(["reasoning.encrypted_content"]));
    if let Some(max) = request.max_output {
        body.insert("max_output_tokens".into(), json!(max));
    }
    if let Some(effort) = &options.effort {
        body.insert(
            "reasoning".into(),
            json!({ "effort": effort, "summary": "auto" }),
        );
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
                // Strict is the default here, and it would make every
                // optional parameter required.
                json!({
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": crate::schema(tool),
                    "strict": false,
                })
            })
            .collect();
        body.insert("tools".into(), Value::Array(tools));
        body.insert("tool_choice".into(), json!("auto"));
    }
    Value::Object(body)
}

/// Reads a streamed response, one event's data at a time.
#[derive(Debug)]
pub struct Parser {
    model: ModelTag,
    output: Option<ModelOutput>,
}

impl Parser {
    pub fn new(model: ModelTag) -> Self {
        Self {
            model,
            output: None,
        }
    }

    /// The response is complete; nothing after this matters.
    pub fn finished(&self) -> bool {
        self.output.is_some()
    }

    pub fn event(&mut self, data: &str) -> Result<Vec<Event>, Error> {
        let event: Value = serde_json::from_str(data).map_err(Error::malformed)?;
        let text = |field: &str| event[field].as_str().unwrap_or_default().to_owned();
        match event["type"].as_str().unwrap_or_default() {
            "response.output_text.delta" => Ok(vec![Event::Text(text("delta"))]),
            "response.output_item.added" if event["item"]["type"] == "function_call" => {
                Ok(vec![Event::ToolCall {
                    name: event["item"]["name"]
                        .as_str()
                        .unwrap_or_default()
                        .to_owned(),
                }])
            }
            "response.completed" => {
                self.output = Some(self.complete(&event["response"]));
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

    fn complete(&self, response: &Value) -> ModelOutput {
        let usage = usage(&response["usage"]);
        let mut items: Vec<Item> = response["output"]
            .as_array()
            .map(Vec::as_slice)
            .unwrap_or_default()
            .iter()
            .filter_map(|raw| {
                let kind = kind(raw)?;
                Some(Item {
                    kind,
                    source: Some(self.model.clone()),
                    opaque: Some(raw.clone()),
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

fn usage(usage: &Value) -> Usage {
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
