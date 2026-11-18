//! The model's two tools. They are the same in every request, so the
//! request prefix stays cached: `run_code` runs a program that can call
//! Max's tools, `shell` runs a command. Both run in the group's VM, where
//! anything may call every tool of Max's.

use std::sync::LazyLock;

use serde::Deserialize;

use crate::ids::CallId;
use crate::item::ToolCall;
use crate::limits::{BACKGROUND_TIME, BACKGROUND_TIME_MAX, RUN_TIME, RUN_TIME_MAX, SHOWN_BYTES};

/// The tools' names, as the model calls them.
pub const RUN_CODE: &str = "run_code";
pub const SHELL: &str = "shell";

#[derive(Debug)]
pub struct ToolSpec {
    pub name: &'static str,
    /// Written from [`limits`](crate::limits), once.
    pub description: String,
    /// JSON Schema.
    pub parameters: &'static str,
}

pub static TOOLS: LazyLock<[ToolSpec; 2]> = LazyLock::new(|| {
    let run = RUN_TIME.as_secs();
    let run_max = RUN_TIME_MAX.as_millis();
    let shown = SHOWN_BYTES >> 10;
    let half = shown / 2;
    let background = BACKGROUND_TIME.as_secs() / 3600;
    let background_max = BACKGROUND_TIME_MAX.as_millis();
    [
        ToolSpec {
            name: RUN_CODE,
            description: format!(
                "Runs JavaScript with Node in this chat's VM. code is the body of an async function: \
                what it returns is the result, and console output comes back beside it. The program calls \
                Max's tools as tools.<name>(args); see their declarations in the system prompt. \
                {run} seconds by default, timeout_ms at most {run_max}. A result or an output over \
                {shown} KiB comes back as its head and tail, the whole of it stored under /work/.max/out/."
            ),
            parameters: r#"{"type":"object","properties":{"code":{"type":"string","description":"the body of an async function"},"args":{"description":"what the program reads as args"},"timeout_ms":{"type":"integer","minimum":1}},"required":["code"]}"#,
        },
        ToolSpec {
            name: SHELL,
            description: format!(
                "Runs a command with bash -lc in this chat's VM: its exit status and its output, stdout and \
                stderr together. {run} seconds by default, timeout_ms at most {run_max}. An output over \
                {shown} KiB comes back as {half} KiB of its head and as much of its tail, the whole of it in \
                the file under /work/.max/out/ that the result names. The command gets no input: run nothing \
                interactive. A command not done at its limit is stopped. With background true it runs in the \
                background instead, as a unit of the VM's systemd whose name, max-job-…, comes back at once; \
                {background} hours by default, timeout_ms at most {background_max}; when it ends, its exit \
                status and the end of its output come back to you as [max-job-… 完成]."
            ),
            parameters: r#"{"type":"object","properties":{"command":{"type":"string"},"workdir":{"type":"string","description":"/work by default"},"timeout_ms":{"type":"integer","minimum":1},"background":{"type":"boolean","description":"run in the background and tell you when it ends; false by default"}},"required":["command"]}"#,
        },
    ]
});

/// A tool call that is well formed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Call {
    pub id: CallId,
    pub tool: Tool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Tool {
    RunCode {
        code: String,
        args: Option<serde_json::Value>,
        timeout_ms: Option<u64>,
    },
    Shell {
        command: String,
        workdir: Option<String>,
        timeout_ms: Option<u64>,
        /// Runs on after the call returns; its end wakes Max.
        background: bool,
    },
}

#[derive(Deserialize)]
struct RunCodeArgs {
    code: String,
    args: Option<serde_json::Value>,
    timeout_ms: Option<u64>,
}

#[derive(Deserialize)]
struct ShellArgs {
    command: String,
    workdir: Option<String>,
    timeout_ms: Option<u64>,
    #[serde(default)]
    background: bool,
}

impl Tool {
    /// The name the model calls it by.
    pub fn name(&self) -> &'static str {
        match self {
            Self::RunCode { .. } => RUN_CODE,
            Self::Shell { .. } => SHELL,
        }
    }
}

/// What is wrong with a tool call, worded for the model: a malformed call
/// gets it as its result and is never run.
#[derive(Debug, thiserror::Error)]
pub enum Malformed {
    /// The arguments aren't the tool's: what serde says of them.
    #[error("{tool}'s arguments are wrong: {error}")]
    Arguments {
        tool: &'static str,
        error: serde_json::Error,
    },
    /// The code or the command is blank.
    #[error("{tool}: {field} is empty")]
    Empty {
        tool: &'static str,
        field: &'static str,
    },
    #[error("there is no tool named {0}: only {RUN_CODE} and {SHELL}")]
    Unknown(String),
}

/// The call, or what is wrong with it.
pub fn parse(call: &ToolCall) -> Result<Call, Malformed> {
    let arguments = |tool| move |error| Malformed::Arguments { tool, error };
    let empty = |tool, field| Malformed::Empty { tool, field };
    let tool = match call.name.as_str() {
        RUN_CODE => {
            let RunCodeArgs {
                code,
                args,
                timeout_ms,
            } = serde_json::from_str(&call.arguments).map_err(arguments(RUN_CODE))?;
            if code.trim().is_empty() {
                return Err(empty(RUN_CODE, "code"));
            }
            Tool::RunCode {
                code,
                args,
                timeout_ms,
            }
        }
        SHELL => {
            let ShellArgs {
                command,
                workdir,
                timeout_ms,
                background,
            } = serde_json::from_str(&call.arguments).map_err(arguments(SHELL))?;
            if command.trim().is_empty() {
                return Err(empty(SHELL, "command"));
            }
            Tool::Shell {
                command,
                workdir,
                timeout_ms,
                background,
            }
        }
        other => return Err(Malformed::Unknown(other.to_owned())),
    };
    Ok(Call {
        id: call.id.clone(),
        tool,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(name: &str, arguments: &str) -> ToolCall {
        ToolCall {
            id: CallId("c1".into()),
            name: name.into(),
            arguments: arguments.into(),
        }
    }

    #[test]
    fn well_formed_calls() {
        assert_eq!(
            parse(&call(
                "run_code",
                r#"{"code": "return 1", "args": {"n": 2}}"#
            ))
            .unwrap()
            .tool,
            Tool::RunCode {
                code: "return 1".into(),
                args: Some(serde_json::json!({"n": 2})),
                timeout_ms: None,
            }
        );
        assert_eq!(
            parse(&call("shell", r#"{"command": "ls", "timeout_ms": 500}"#))
                .unwrap()
                .tool,
            Tool::Shell {
                command: "ls".into(),
                workdir: None,
                timeout_ms: Some(500),
                background: false,
            }
        );
        assert_eq!(
            parse(&call("shell", r#"{"command": "make", "background": true}"#))
                .unwrap()
                .tool,
            Tool::Shell {
                command: "make".into(),
                workdir: None,
                timeout_ms: None,
                background: true,
            }
        );
    }

    #[test]
    fn malformed_calls() {
        for (name, arguments) in [
            ("run_code", "{\"code\": "),
            ("run_code", r#"{"source": "x"}"#),
            ("run_code", r#"{"code": "  "}"#),
            ("shell", r#"{"command": "ls", "timeout_ms": -1}"#),
            ("shell", r#"{"command": "ls", "background": "yes"}"#),
            ("shell", r#"["ls"]"#),
            ("send_message", "{}"),
        ] {
            let error = parse(&call(name, arguments)).unwrap_err();
            assert!(!error.to_string().is_empty());
        }
    }
}
