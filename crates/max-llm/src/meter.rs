//! A response read on its way past, for a call Max didn't make: one from
//! a VM, a background agent's or a program's, which max forwards to the
//! provider and back as the bytes came. Its usage is read as the
//! protocol's parser reads Max's own, and when the model began to answer.
//! An answer that isn't streamed, one JSON object, has its usage too.

use std::mem;

use max_core::item::{Protocol, Usage};
use serde_json::Value;

use crate::{chat, responses};

/// The longest line read; a longer one is skipped. `response.completed`
/// carries the whole output. An answer that isn't streamed is no longer.
const LONGEST: usize = 16 << 20;

/// Reads a response a piece at a time: server-sent events, or one JSON
/// object, which is what an answer that isn't streamed begins as.
#[derive(Debug)]
pub struct Meter {
    protocol: Protocol,
    /// Whether the answer has begun, and said which of the two it is.
    begun: bool,
    /// The answer so far, if it is one object and not events.
    whole: Option<Vec<u8>>,
    /// The line so far; dropped once it is too long.
    line: Vec<u8>,
    dropping: bool,
    /// The event's `data` lines so far, joined.
    data: Option<String>,
    usage: Usage,
    started: bool,
}

impl Meter {
    pub fn new(protocol: Protocol) -> Self {
        Self {
            protocol,
            begun: false,
            whole: None,
            line: Vec::new(),
            dropping: false,
            data: None,
            usage: Usage::default(),
            started: false,
        }
    }

    /// Reads the response's next piece.
    pub fn push(&mut self, mut bytes: &[u8]) {
        if !self.begun {
            // No event begins with a brace.
            let Some(at) = bytes.iter().position(|byte| !byte.is_ascii_whitespace()) else {
                return;
            };
            bytes = &bytes[at..];
            self.begun = true;
            if bytes[0] == b'{' {
                self.whole = Some(Vec::new());
            }
        }
        if let Some(whole) = &mut self.whole {
            if whole.len() + bytes.len() > LONGEST {
                self.dropping = true;
                whole.clear();
            } else if !self.dropping {
                whole.extend_from_slice(bytes);
            }
            return;
        }
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

    /// What the provider said the call used: nothing until it says, which
    /// an answer that isn't streamed does once it has all come.
    pub fn usage(&self) -> Usage {
        let Some(whole) = &self.whole else {
            return self.usage;
        };
        let Ok(answer) = serde_json::from_slice::<Value>(whole) else {
            return Usage::default();
        };
        let usage = &answer["usage"];
        match self.protocol {
            _ if !usage.is_object() => Usage::default(),
            Protocol::Chat => chat::usage(usage),
            Protocol::Responses => responses::usage(usage),
        }
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
        let delta = &chunk["choices"][0]["delta"];
        let wrote = |field: &str| {
            delta[field]
                .as_str()
                .is_some_and(|text| !text.trim().is_empty())
        };
        let called = delta["tool_calls"]
            .as_array()
            .is_some_and(|calls| !calls.is_empty());
        self.started |=
            called || wrote("content") || chat::REASONING.iter().any(|field| wrote(field));
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
    }
}

#[cfg(test)]
mod tests;
