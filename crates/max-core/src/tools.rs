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
        description: "在本群的 VM 里用 Node 运行一段 JavaScript。code 是 async 函数体，return 的值就是结果，\
            console 输出另外带回。程序里用 tools.<名字>(args) 调 Max 的工具，见系统提示里的声明。\
            默认限时 120 秒，timeout_ms 最多 600000。结果和输出各自超过 16 KiB 只返回头尾，全文存在 /work/.max/out/ 下。",
        parameters: r#"{"type":"object","properties":{"code":{"type":"string","description":"async 函数体"},"args":{"description":"程序里读到的 args"},"timeout_ms":{"type":"integer","minimum":1}},"required":["code"]}"#,
    },
    ToolSpec {
        name: "shell",
        description: "在本群的 VM 里用 bash -lc 运行一条命令，返回退出码和合并的输出。\
            默认限时 120 秒，timeout_ms 最多 600000。输出超过 16 KiB 只返回头尾各 8 KiB，\
            全文存在结果里给出的 /work/.max/out/ 下的文件里。命令没有输入，别跑交互式程序。",
        parameters: r#"{"type":"object","properties":{"command":{"type":"string"},"workdir":{"type":"string","description":"默认 /work"},"timeout_ms":{"type":"integer","minimum":1}},"required":["command"]}"#,
    },
];

/// A Max tool: what a program calls as `tools.<name>(args)`, through the
/// MCP service. The system prompt shows each one's declaration, so the
/// list is fixed too.
#[derive(Debug)]
pub struct MaxTool {
    pub name: &'static str,
    pub description: &'static str,
    /// JSON Schemas.
    pub input: &'static str,
    pub output: &'static str,
    /// TypeScript, for the system prompt.
    pub declaration: &'static str,
    /// The most calls one run may make.
    pub per_run: Option<u32>,
}

pub const MAX_TOOLS: [MaxTool; 2] = [
    MaxTool {
        name: "context_read",
        description: "读一条消息的全文，一页一页地读。上下文里太长的消息只有开头，后面写着“全文见 #id”。",
        input: r#"{"type":"object","properties":{"id":{"type":"integer","description":"消息的编号，#123 就是 123"},"page":{"type":"integer","minimum":1,"description":"第几页，默认 1"}},"required":["id"],"additionalProperties":false}"#,
        output: r#"{"type":"object","properties":{"text":{"type":"string"},"page":{"type":"integer"},"pages":{"type":"integer"}},"required":["text","page","pages"]}"#,
        declaration: "/** 读一条消息的全文。上下文里太长的消息只有开头，后面写着“全文见 #id”。\n  一页不超过上下文里一条消息的上限，pages 是总页数。 */\n\
        context_read(args: { id: number; page?: number }): Promise<{ text: string; page: number; pages: number }>;",
        per_run: None,
    },
    MaxTool {
        name: "web_search",
        description: "搜索网页，返回前几条结果的标题、链接、摘要和发布日期。",
        input: r#"{"type":"object","properties":{"query":{"type":"string","minLength":1},"limit":{"type":"integer","minimum":1,"maximum":10,"description":"几条，默认 5"}},"required":["query"],"additionalProperties":false}"#,
        output: r#"{"type":"object","properties":{"results":{"type":"array","items":{"type":"object","properties":{"title":{"type":"string"},"url":{"type":"string"},"snippet":{"type":"string"},"published":{"type":"string","description":"YYYY-MM-DD"}},"required":["title","url","snippet"]}}},"required":["results"]}"#,
        // Always shown: when the Haskell version kept it in a skill, the model
        // answered from memory instead, and got plots and prices wrong.
        declaration: "/** 搜索网页，返回前几条结果的标题、链接、摘要和发布日期（知道的话）。事实、价格、新闻、剧情这类拿不准或可能过时的，先搜再答，别凭记忆。\n  \
        limit 1 到 10，默认 5。一次运行最多搜 20 次，要搜好几样就 Promise.all。要读全文，用 shell 在 VM 里抓。 */\n\
        web_search(args: { query: string; limit?: number }): Promise<{ results: { title: string; url: string; snippet: string; published?: string }[] }>;",
        per_run: Some(20),
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
        timeout_ms: Option<u64>,
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
    timeout_ms: Option<u64>,
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
            let RunCodeArgs {
                code,
                args,
                timeout_ms,
            } = serde_json::from_str(&call.arguments).map_err(malformed)?;
            if code.trim().is_empty() {
                return Err("run_code 的 code 是空的".to_owned());
            }
            Tool::RunCode {
                code,
                args,
                timeout_ms,
            }
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
    fn max_tool_schemas_are_json() {
        for tool in MAX_TOOLS {
            for schema in [tool.input, tool.output] {
                let schema: serde_json::Value = serde_json::from_str(schema).unwrap();
                assert_eq!(schema["type"], "object", "{}", tool.name);
            }
            assert!(tool.declaration.contains(&format!("\n{}(args", tool.name)));
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
