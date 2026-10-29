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

pub const MAX_TOOLS: [MaxTool; 7] = [
    MaxTool {
        name: "context_read",
        description: "读消息或摘要的全文，一页一页地读；也能读一条消息和它前后的几条。上下文里太长的消息只有开头，后面写着“全文见 #id”。",
        input: r#"{"type":"object","properties":{"id":{"type":"integer","description":"消息的编号，#123 就是 123"},"before":{"type":"integer","minimum":0,"maximum":50,"description":"连同它前面几条，默认 0"},"after":{"type":"integer","minimum":0,"maximum":50,"description":"连同它后面几条，默认 0"},"summary":{"type":"integer","description":"摘要的编号，summary#45 就是 45；和 id 二选一"},"page":{"type":"integer","minimum":1,"description":"第几页，默认 1"}},"additionalProperties":false}"#,
        output: r#"{"type":"object","properties":{"text":{"type":"string"},"page":{"type":"integer"},"pages":{"type":"integer"}},"required":["text","page","pages"]}"#,
        declaration: "/** 读消息或摘要的全文。上下文里太长的消息只有开头，后面写着“全文见 #id”。\n  \
        { id } 读这一条；加上 before、after（各最多 50）就是它连同前后各几条，一行一条，和上下文里一样，太长的照样只有开头。\n  \
        { summary } 读一段摘要的全文，末尾写着它总结的是 #几 到 #几。一页不超过上下文里一条消息的上限，pages 是总页数。 */\n\
        context_read(args: { id: number; before?: number; after?: number; page?: number } | { summary: number; page?: number }): Promise<{ text: string; page: number; pages: number }>;",
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
        limit 1 到 10，默认 5。一次运行最多搜 20 次，要搜好几样就 Promise.all。要读全文，用 shell 跑 webread <url>。 */\n\
        web_search(args: { query: string; limit?: number }): Promise<{ results: { title: string; url: string; snippet: string; published?: string }[] }>;",
        per_run: Some(20),
    },
    MaxTool {
        name: "send_image",
        description: "把 /work 下的一张图发到本群，比如画的图表、截的图、下载的图片。",
        input: r#"{"type":"object","properties":{"path":{"type":"string","minLength":1,"description":"/work 下的路径，相对路径从 /work 算"},"caption":{"type":"string","description":"图下面的说明，可以不写"}},"required":["path"],"additionalProperties":false}"#,
        output: r#"{"type":"object","properties":{"handle":{"type":"string"}},"required":["handle"]}"#,
        declaration: "/** 把 /work 下的一张图发到本群：画的图表、截的图、下载的图片。PNG、JPEG、GIF、WebP，最大 10 MiB；路径上不能有符号链接。\n  \
        caption 是图下面的一句说明，和图在同一条消息里。发出去了才返回，handle 是这条消息里那张图的句柄。一次运行最多发 5 张。\n  \
        记录里已有的图和表情包不用这个，直接在回复里写它的句柄。 */\n\
        send_image(args: { path: string; caption?: string }): Promise<{ handle: string }>;",
        per_run: Some(5),
    },
    MaxTool {
        name: "recall_message",
        description: "撤回本群发出 2 分钟内的一条消息：你自己的，或者你是群管理员时普通成员的。",
        input: r#"{"type":"object","properties":{"id":{"type":"integer","description":"消息的编号，#123 就是 123"}},"required":["id"],"additionalProperties":false}"#,
        output: r#"{"type":"object","properties":{"recalled":{"type":"integer"}},"required":["recalled"]}"#,
        declaration: "/** 撤回本群的一条消息，id 是行首 #编号 里的数字。撤不撤由你判断：刷屏、广告、违规内容，或者有人请你撤、理由正当时再用，撤完简短说一声。\n  \
        QQ 只让撤发出 2 分钟内的：你自己说的（一段是一条，一次回复分成几段的要一段一段撤）；你是群管理员时还有普通成员的，群主和管理员的撤不了。私聊里只能撤你自己的。\n  \
        QQ 撤了才返回；撤不了会抛错，说明原因。记录里会多一行你的 [unsend#id]，QQ 没撤的标着（没发出去）。一次运行最多撤 10 条。 */\n\
        recall_message(args: { id: number }): Promise<{ recalled: number }>;",
        per_run: Some(10),
    },
    MaxTool {
        name: "mute_member",
        description: "在本群禁言一个普通成员，或者解除禁言；要你是群管理员。",
        input: r#"{"type":"object","properties":{"member":{"type":"integer","description":"[mention#编号] 里的数字"},"seconds":{"type":"integer","minimum":0,"maximum":2592000,"description":"禁多少秒，0 是解除，最多 30 天"}},"required":["member","seconds"],"additionalProperties":false}"#,
        output: r#"{"type":"object","properties":{"member":{"type":"integer"},"until":{"type":["string","null"]}},"required":["member","until"]}"#,
        declaration: "/** 在本群禁言一个人，或者解除。member 是 [mention#编号] 里的数字；seconds 是从现在起禁多少秒，0 是解除，最多 2592000（30 天）。禁不禁、禁多久由你判断：刷屏、广告、骂人，或者有人请你禁、理由正当时再用，禁完或解完在群里简短说一声。\n  \
        QQ 只让群管理员禁言普通成员：群主、管理员、你自己都禁不了，私聊里没有禁言；没在本群说过话的人也禁不了。对禁着的人再禁，是把结束时间改成从现在起 seconds 秒。\n  \
        QQ 办了才返回，until 是禁到几点，解除时是 null；办不了会抛错，说明原因。记录里不会多一行。一次运行最多 5 次。 */\n\
        mute_member(args: { member: number; seconds: number }): Promise<{ member: number; until: string | null }>;",
        per_run: Some(5),
    },
    MaxTool {
        name: "find_stickers",
        description: "在表情包库里按意思找表情包，返回句柄和描述，只找不发。",
        input: r#"{"type":"object","properties":{"query":{"type":"string","minLength":1,"description":"想表达什么，比如“无语”“幸灾乐祸”“翻白眼的猫”"},"limit":{"type":"integer","minimum":1,"maximum":10,"description":"几条，默认 5"}},"required":["query"],"additionalProperties":false}"#,
        output: r#"{"type":"object","properties":{"stickers":{"type":"array","items":{"type":"object","properties":{"handle":{"type":"string"},"description":{"type":"string"}},"required":["handle","description"]}}},"required":["stickers"]}"#,
        declaration: "/** 在表情包库里按意思找表情包：库里是各个群里见过的表情包，按描述和 query 的意思远近排，近的在前。\n  \
        只找不发：挑一个合适的，把 handle 照抄进回复，写成 [sticker#…]，就发出去了；都不合适就不发。limit 1 到 10，默认 5。一次运行最多找 5 次。 */\n\
        find_stickers(args: { query: string; limit?: number }): Promise<{ stickers: { handle: string; description: string }[] }>;",
        per_run: Some(5),
    },
    MaxTool {
        name: "context_search",
        description: "按关键词搜本会话的聊天记录：原始消息（连同图片和表情包的描述）和摘要。返回命中处的片段，和读原文用的 context_read 参数。",
        input: r#"{"type":"object","properties":{"query":{"type":"string","minLength":1,"description":"空格隔开的关键词，最多 8 个"},"limit":{"type":"integer","minimum":1,"maximum":30,"description":"几条，默认 10"},"from":{"type":"string","description":"YYYY-MM-DD，从这天起"},"to":{"type":"string","description":"YYYY-MM-DD，到这天为止"}},"required":["query"],"additionalProperties":false}"#,
        output: r#"{"type":"object","properties":{"results":{"type":"array","items":{"type":"object","properties":{"kind":{"type":"string","enum":["message","summary"]},"ref":{"type":"string"},"time":{"type":"string"},"text":{"type":"string"},"read":{"type":"object"}},"required":["kind","ref","time","text","read"]}}},"required":["results"]}"#,
        declaration: "/** 搜本会话的聊天记录：原始消息（连同图片和表情包的描述）和摘要。上下文里没有的旧事、谁以前说过什么，先搜再答。\n  \
        query 是空格隔开的关键词，最多 8 个，按原文找、不分大小写，不是按意思找：中文词写短点（两三个字），换个说法要自己再搜。\n  \
        命中的词多的在前，一样多的新的在前；消息和摘要各最多占 limit 的三分之二，另一种不够时补满。limit 默认 10，最多 30。from、to 是日期，都含当天。\n  \
        text 是命中处附近的一段；read 原样传给 context_read，读这条消息连同前后各 10 条，或者摘要全文。撤回的消息不搜；/clear --all 清掉的只是不在上下文里，照样能搜。一次运行最多搜 20 次。 */\n\
        context_search(args: { query: string; limit?: number; from?: string; to?: string }): Promise<{ results: { kind: \"message\" | \"summary\"; ref: string; time: string; text: string; read: { id: number; before: number; after: number } | { summary: number } }[] }>;",
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
