//! The model's two tools. They are the same in every request, so the
//! request prefix stays cached: `run_code` runs a program that can call
//! Max's tools, `shell` runs a command. Both run in the group's VM. Which
//! Max tools a program may call is up to the run's spec, not the tool list.

use std::sync::LazyLock;

use serde::{Deserialize, Serialize};

use crate::ids::CallId;
use crate::item::ToolCall;
use crate::limits::{BACKGROUND_TIME, BACKGROUND_TIME_MAX, RUN_TIME, RUN_TIME_MAX, SHOWN_BYTES};

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
    let background = BACKGROUND_TIME.as_secs() / 60;
    let background_max = BACKGROUND_TIME_MAX.as_millis();
    [
        ToolSpec {
            name: "run_code",
            description: format!(
                "在本群的 VM 里用 Node 运行一段 JavaScript。code 是 async 函数体，return 的值就是结果，\
                console 输出另外带回。程序里用 tools.<名字>(args) 调 Max 的工具，见系统提示里的声明。\
                默认限时 {run} 秒，timeout_ms 最多 {run_max}。结果和输出各自超过 {shown} KiB 只返回头尾，全文存在 /work/.max/out/ 下。"
            ),
            parameters: r#"{"type":"object","properties":{"code":{"type":"string","description":"async 函数体"},"args":{"description":"程序里读到的 args"},"timeout_ms":{"type":"integer","minimum":1}},"required":["code"]}"#,
        },
        ToolSpec {
            name: "shell",
            description: format!(
                "在本群的 VM 里用 bash -lc 运行一条命令，返回退出码和合并的输出。\
                默认限时 {run} 秒，timeout_ms 最多 {run_max}。输出超过 {shown} KiB 只返回头尾各 {half} KiB，\
                全文存在结果里给出的 /work/.max/out/ 下的文件里。命令没有输入，别跑交互式程序。\
                background 为 true 时命令在后台跑，马上返回一个 job 编号；默认限时 {background} 分钟，timeout_ms 最多 {background_max}；\
                跑完了，退出码和输出作为 [job#N 完成] 回到你这里。"
            ),
            parameters: r#"{"type":"object","properties":{"command":{"type":"string"},"workdir":{"type":"string","description":"默认 /work"},"timeout_ms":{"type":"integer","minimum":1},"background":{"type":"boolean","description":"在后台跑，跑完再告诉你；默认 false"}},"required":["command"]}"#,
        },
    ]
});

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
        /// Runs on after the call returns; its end wakes Max.
        #[serde(default)]
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
                background,
            } = serde_json::from_str(&call.arguments).map_err(malformed)?;
            if command.trim().is_empty() {
                return Err("shell 的 command 是空的".to_owned());
            }
            Tool::Shell {
                command,
                workdir,
                timeout_ms,
                background,
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
        for tool in TOOLS.iter() {
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

    /// Calls recorded before `background` came read as they ran.
    #[test]
    fn a_recorded_shell_call_runs_in_the_foreground() {
        let tool: Tool = serde_json::from_str(
            r#"{"type": "shell", "command": "ls", "workdir": null, "timeout_ms": null}"#,
        )
        .unwrap();
        assert!(matches!(
            tool,
            Tool::Shell {
                background: false,
                ..
            }
        ));
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
            assert!(!error.is_empty());
        }
    }
}
