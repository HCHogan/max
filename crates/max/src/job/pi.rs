//! pi's RPC mode, as much of it as a background agent needs: a command
//! a line on pi's stdin, a record a line on its stdout, each a JSON
//! object, split only on LF. See "后台 agent" in docs/rust-rewrite.md.

use max_core::item::Usage;
use serde_json::{Value, json};
use tracing::warn;

/// The longest record kept. `agent_end` carries every message of the
/// run, which max doesn't read.
const LONGEST: usize = 16 << 20;

/// What max asks pi.
#[derive(Clone, Copy, Debug)]
pub enum Ask<'a> {
    /// Steers that queue up during a tool call all go in before the next
    /// model call, not one a call.
    SteerAll,
    Prompt(&'a str),
    Steer(&'a str),
    /// Drops the steers not yet delivered, which `Abort` would go on with.
    ClearQueue,
    /// Answered once pi has settled.
    Abort,
    /// The text of the last assistant message, the report.
    LastText,
    /// Answers the dialog with this id: nobody is there to.
    Dismiss(&'a str),
    /// Answers the question with this id, with Max's words.
    Answer(&'a str, &'a str),
}

impl Ask<'_> {
    /// The command's line, with `id`.
    pub fn line(self, id: u64) -> String {
        let id = id.to_string();
        let command = match self {
            Ask::SteerAll => json!({ "id": id, "type": "set_steering_mode", "mode": "all" }),
            Ask::Prompt(message) => json!({ "id": id, "type": "prompt", "message": message }),
            Ask::Steer(message) => json!({ "id": id, "type": "steer", "message": message }),
            Ask::ClearQueue => json!({ "id": id, "type": "clear_queue" }),
            Ask::Abort => json!({ "id": id, "type": "abort" }),
            Ask::LastText => json!({ "id": id, "type": "get_last_assistant_text" }),
            Ask::Dismiss(dialog) => {
                json!({ "id": dialog, "type": "extension_ui_response", "cancelled": true })
            }
            Ask::Answer(question, value) => {
                json!({ "id": question, "type": "extension_ui_response", "value": value })
            }
        };
        format!("{command}\n")
    }
}

/// What pi says, as far as max cares.
#[derive(Clone, Debug, PartialEq)]
pub enum Record {
    /// The answer to the command with `id`; `error` if it failed.
    Response {
        id: Option<u64>,
        error: Option<String>,
        data: Value,
    },
    /// A model call ended; `error` if it failed.
    Called {
        usage: Usage,
        error: Option<String>,
    },
    /// A tool call began.
    Tool(String),
    /// pi won't go on by itself: no retry, no queued message.
    Settled {
        aborted: bool,
    },
    /// pi asks the user, and waits for the answer.
    Dialog(String),
    /// The agent asks Max, with `ask_max`, and waits for the answer: an
    /// input dialog, the question its title.
    Question {
        id: String,
        text: String,
    },
    /// pi tells the user, such as that an MCP server is unreachable.
    Notice(String),
    Other,
}

pub fn parse(line: &[u8]) -> serde_json::Result<Record> {
    let record: Value = serde_json::from_slice(line)?;
    let text = |value: &Value| value.as_str().map(str::to_owned);
    Ok(match record["type"].as_str() {
        Some("response") => Record::Response {
            id: record["id"].as_str().and_then(|id| id.parse().ok()),
            error: (record["success"] != true)
                .then(|| text(&record["error"]).unwrap_or_else(|| "pi 没说为什么".to_owned())),
            data: record["data"].clone(),
        },
        Some("message_end") if record["message"]["role"] == "assistant" => {
            let message = &record["message"];
            Record::Called {
                usage: usage(&message["usage"]),
                error: (message["stopReason"] == "error").then(|| {
                    text(&message["errorMessage"]).unwrap_or_else(|| "模型调用失败".to_owned())
                }),
            }
        }
        Some("tool_execution_start") => Record::Tool(text(&record["toolName"]).unwrap_or_default()),
        Some("agent_settled") => Record::Settled {
            aborted: record["aborted"] == true,
        },
        Some("extension_ui_request") => match record["method"].as_str() {
            Some("input") => Record::Question {
                id: text(&record["id"]).unwrap_or_default(),
                text: text(&record["title"]).unwrap_or_default(),
            },
            Some("select" | "confirm" | "editor") => {
                Record::Dialog(text(&record["id"]).unwrap_or_default())
            }
            Some("notify") => Record::Notice(text(&record["message"]).unwrap_or_default()),
            _ => Record::Other,
        },
        _ => Record::Other,
    })
}

/// pi counts what the cache read or wrote apart from `input`; max's
/// `input` is the whole request.
fn usage(usage: &Value) -> Usage {
    let count = |key: &str| {
        usage[key]
            .as_u64()
            .map_or(0, |n| u32::try_from(n).unwrap_or(u32::MAX))
    };
    let cached = count("cacheRead");
    Usage {
        input: count("input")
            .saturating_add(cached)
            .saturating_add(count("cacheWrite")),
        cached,
        output: count("output"),
        reasoning: count("reasoning"),
    }
}

/// Cuts pi's stdout into lines as it arrives. A line longer than
/// [`LONGEST`] is dropped.
#[derive(Debug, Default)]
pub struct Lines {
    partial: Vec<u8>,
    dropping: bool,
}

impl Lines {
    /// Hands each line `data` completes to `line`, without its LF or CR.
    pub fn push(&mut self, mut data: &[u8], mut line: impl FnMut(&[u8])) {
        while let Some(end) = data.iter().position(|&byte| byte == b'\n') {
            let (head, rest) = data.split_at(end);
            if self.dropping {
            } else if self.partial.len() + head.len() > LONGEST {
                warn!("dropped a record of pi's longer than {LONGEST} bytes");
            } else {
                self.partial.extend_from_slice(head);
                line(self.partial.strip_suffix(b"\r").unwrap_or(&self.partial));
            }
            self.partial.clear();
            self.dropping = false;
            data = &rest[1..];
        }
        if self.dropping {
            return;
        }
        if self.partial.len() + data.len() > LONGEST {
            warn!("dropped a record of pi's longer than {LONGEST} bytes");
            self.partial.clear();
            self.dropping = true;
        } else {
            self.partial.extend_from_slice(data);
        }
    }
}

#[cfg(test)]
mod tests;
