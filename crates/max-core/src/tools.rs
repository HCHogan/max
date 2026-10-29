//! The model's two tools. They are the same in every request, so the
//! request prefix stays cached: `run_code` runs a program that can call
//! Max's tools, `shell` runs a command. Both run in the group's VM. Which
//! Max tools a program may call is up to the run's spec, not the tool list.

use serde::{Deserialize, Serialize};

use crate::ids::CallId;
use crate::item::ToolCall;

#[derive(Debug)]
pub struct ToolSpec {
    pub name: &'static str,
    pub description: &'static str,
    /// JSON Schema.
    pub parameters: &'static str,
}

pub const TOOLS: [ToolSpec; 2] = [
    ToolSpec {
        name: "run_code",
        description: "在本群的 VM 里运行一段 JavaScript。code 是 async 函数体，return 的值就是结果。\
            程序里用 tools.<名字>(args) 调 Max 的工具，见系统提示里的声明。",
        parameters: r#"{"type":"object","properties":{"code":{"type":"string","description":"async 函数体"},"args":{"description":"程序里读到的 args"}},"required":["code"]}"#,
    },
    ToolSpec {
        name: "shell",
        description: "在本群的 VM 里用 bash -lc 运行一条命令，返回退出码和合并的输出。\
            默认限时 120 秒，timeout_ms 最多 600000。输出超过 16 KiB 只返回头尾各 8 KiB，\
            全文存在结果里给出的 /work/.max/out/ 下的文件里。命令没有输入，别跑交互式程序。",
        parameters: r#"{"type":"object","properties":{"command":{"type":"string"},"workdir":{"type":"string","description":"默认 /work"},"timeout_ms":{"type":"integer","minimum":1}},"required":["command"]}"#,
    },
];

/// A tool call that is well formed.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Call {
    pub id: CallId,
    pub tool: Tool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Tool {
    RunCode {
        code: String,
        args: Option<serde_json::Value>,
    },
    Shell {
        command: String,
        workdir: Option<String>,
        timeout_ms: Option<u64>,
    },
}

#[derive(Deserialize)]
struct RunCodeArgs {
    code: String,
    args: Option<serde_json::Value>,
}

#[derive(Deserialize)]
struct ShellArgs {
    command: String,
    workdir: Option<String>,
    timeout_ms: Option<u64>,
}

/// The call, or what to tell the model about its mistake. A malformed call
/// gets that as its result and is never run.
pub fn parse(call: &ToolCall) -> Result<Call, String> {
    let malformed = |e: serde_json::Error| format!("{} 的参数不对：{e}", call.name);
    let tool = match call.name.as_str() {
        "run_code" => {
            let RunCodeArgs { code, args } =
                serde_json::from_str(&call.arguments).map_err(malformed)?;
            if code.trim().is_empty() {
                return Err("run_code 的 code 是空的".to_owned());
            }
            Tool::RunCode { code, args }
        }
        "shell" => {
            let ShellArgs {
                command,
                workdir,
                timeout_ms,
            } = serde_json::from_str(&call.arguments).map_err(malformed)?;
            if command.trim().is_empty() {
                return Err("shell 的 command 是空的".to_owned());
            }
            Tool::Shell {
                command,
                workdir,
                timeout_ms,
            }
        }
        other => return Err(format!("没有 {other} 这个工具，只有 run_code 和 shell")),
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
    fn schemas_are_json() {
        for tool in TOOLS {
            let schema: serde_json::Value = serde_json::from_str(tool.parameters).unwrap();
            assert_eq!(schema["type"], "object", "{}", tool.name);
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
            ("shell", r#"["ls"]"#),
            ("send_message", "{}"),
        ] {
            let error = parse(&call(name, arguments)).unwrap_err();
            assert!(!error.is_empty());
        }
    }
}
