//! A response read on its way past, for a call Max didn't make: a
//! background agent's, which max forwards to the provider and back as the
//! bytes came. Its usage is read as the protocol's parser reads Max's own,
//! its tool calls by name, and when the model began to answer.

use std::collections::BTreeMap;
use std::mem;

use max_core::item::{Protocol, Usage};
use serde_json::Value;

use crate::{chat, responses};

/// The longest line read; a longer one is skipped. `response.completed`
/// carries the whole output.
const LONGEST: usize = 16 << 20;

/// Reads a streamed response a piece at a time, as server-sent events.
#[derive(Debug)]
pub struct Meter {
    protocol: Protocol,
    /// The line so far; dropped once it is too long.
    line: Vec<u8>,
    dropping: bool,
    /// The event's `data` lines so far, joined.
    data: Option<String>,
    usage: Usage,
    started: bool,
    completed: bool,
    /// The tools called, by where the call is in the answer.
    calls: BTreeMap<u64, String>,
}

impl Meter {
    pub fn new(protocol: Protocol) -> Self {
        Self {
            protocol,
            line: Vec::new(),
            dropping: false,
            data: None,
            usage: Usage::default(),
            started: false,
            completed: false,
            calls: BTreeMap::new(),
        }
    }

    /// Reads the response's next piece.
    pub fn push(&mut self, bytes: &[u8]) {
        let mut pieces = bytes.split(|&byte| byte == b'\n').peekable();
        while let Some(piece) = pieces.next() {
            if !self.dropping {
                if self.line.len() + piece.len() > LONGEST {
                    self.dropping = true;
                    self.line.clear();
                } else {
                    self.line.extend_from_slice(piece);
                }
            }
            // Every piece but the last ended at a line feed.
            if pieces.peek().is_some() {
                let mut line = mem::take(&mut self.line);
                if !mem::take(&mut self.dropping) {
                    if line.last() == Some(&b'\r') {
                        line.pop();
                    }
                    self.field(&line);
                }
            }
        }
    }

    /// The model has begun to answer: text, reasoning or a tool call.
    pub fn started(&self) -> bool {
        self.started
    }

    /// What the provider said the call used: nothing until it says.
    pub fn usage(&self) -> Usage {
        self.usage
    }

    /// The tools the model called, in order; none if the response didn't
    /// complete, since then they don't run.
    pub fn tools(&self) -> Vec<String> {
        if !self.completed {
            return Vec::new();
        }
        let named = self.calls.values().filter(|name| !name.is_empty());
        named.cloned().collect()
    }

    /// One line of the stream.
    fn field(&mut self, line: &[u8]) {
        if line.is_empty() {
            if let Some(data) = self.data.take() {
                self.event(&data);
            }
            return;
        }
        let Some(value) = line.strip_prefix(b"data:") else {
            // Another field, or a comment.
            return;
        };
        let value = value.strip_prefix(b" ").unwrap_or(value);
        let value = String::from_utf8_lossy(value);
        match &mut self.data {
            Some(data) => {
                data.push('\n');
                data.push_str(&value);
            }
            None => self.data = Some(value.into_owned()),
        }
    }

    fn event(&mut self, data: &str) {
        if data.trim() == "[DONE]" {
            self.completed = true;
            return;
        }
        let Ok(event) = serde_json::from_str::<Value>(data) else {
            return;
        };
        match self.protocol {
            Protocol::Chat => self.chunk(&event),
            Protocol::Responses => self.response(&event),
        }
    }

    fn chunk(&mut self, chunk: &Value) {
        if chunk["usage"].is_object() {
            self.usage = chat::usage(&chunk["usage"]);
        }
        let choice = &chunk["choices"][0];
        if choice["finish_reason"].is_string() {
            self.completed = true;
        }
        let delta = &choice["delta"];
        let wrote = |field: &str| {
            delta[field]
                .as_str()
                .is_some_and(|text| !text.trim().is_empty())
        };
        self.started |= wrote("content") || chat::REASONING.iter().any(|field| wrote(field));
        let calls = delta["tool_calls"].as_array().map(Vec::as_slice);
        for (position, call) in calls.unwrap_or_default().iter().enumerate() {
            self.started = true;
            let index = call["index"]
                .as_u64()
                .unwrap_or(u64::try_from(position).unwrap_or_default());
            let name = self.calls.entry(index).or_default();
            if let Some(piece) = call["function"]["name"].as_str() {
                name.push_str(piece);
            }
        }
    }

    fn response(&mut self, event: &Value) {
        let kind = event["type"].as_str().unwrap_or_default();
        self.started |= kind.starts_with("response.output_item.");
        if !matches!(
            kind,
            "response.completed" | "response.incomplete" | "response.failed"
        ) {
            return;
        }
        let response = &event["response"];
        if response["usage"].is_object() {
            self.usage = responses::usage(&response["usage"]);
        }
        if kind != "response.completed" {
            return;
        }
        self.completed = true;
        let output = response["output"].as_array().map(Vec::as_slice);
        let calls = output.unwrap_or_default().iter();
        let calls = calls.filter(|item| item["type"] == "function_call");
        for (index, call) in (0..).zip(calls) {
            let name = call["name"].as_str().unwrap_or_default();
            self.calls.insert(index, name.to_owned());
        }
    }
}

#[cfg(test)]
mod tests;
