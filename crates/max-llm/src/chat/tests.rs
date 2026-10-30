use std::collections::BTreeSet;

use max_core::ids::MessageId;
use max_core::item::{Image, Part, Protocol, ToolOutput};
use max_core::message::{MediaKind, MediaRef};
use max_core::tools::TOOLS;

use super::*;

fn model(name: &str) -> ModelTag {
    ModelTag {
        protocol: Protocol::Chat,
        model: name.into(),
    }
}

fn from(model: &ModelTag, kind: ItemKind, raw: Option<Value>) -> Item {
    Item {
        kind,
        source: Some(model.clone()),
        opaque: raw,
        tokens: 0,
    }
}

fn call(id: &str, arguments: &str) -> ToolCall {
    ToolCall {
        id: CallId(id.into()),
        name: "run_code".into(),
        arguments: arguments.into(),
    }
}

fn result(id: &str) -> Item {
    Item::new(
        ItemKind::ToolResult {
            call: CallId(id.into()),
            output: ToolOutput::text("1", false, 1),
        },
        1,
    )
}

#[test]
fn a_request() {
    let deepseek = model("deepseek-pro");
    let flash = model("gemini-3.8-flash");
    let signed = json!({ "extra_content": { "google": { "thought_signature": "sig" } } });
    let request = Request {
        model: deepseek.clone(),
        items: vec![
            Item::new(
                ItemKind::System {
                    text: "你是 Max。".into(),
                },
                5,
            ),
            Item::new(ItemKind::user("[1] 小明：算一下"), 5),
            // This model's call: reasoning fields go back on the message.
            from(
                &deepseek,
                ItemKind::Reasoning {
                    text: Some("先算".into()),
                },
                Some(json!({ "message": { "reasoning_content": "先算" } })),
            ),
            from(&deepseek, ItemKind::Assistant { text: "好".into() }, None),
            from(&deepseek, ItemKind::ToolCall(call("c1", "{}")), None),
            result("c1"),
            // Another model's: its reasoning and signature go.
            from(
                &flash,
                ItemKind::Reasoning { text: None },
                Some(json!({ "message": { "x": 1 } })),
            ),
            from(&flash, ItemKind::ToolCall(call("c2", "{}")), Some(signed)),
            result("c2"),
            // Cut off midway: the core's own item, no source.
            Item::new(
                ItemKind::Assistant {
                    text: "结果是".into(),
                },
                3,
            ),
        ],
        tools: &TOOLS,
        max_output: None,
        roster: BTreeSet::new(),
    };
    let options = Options {
        effort: Some("high".into()),
        temperature: Some(0.6),
        ..Options::default()
    };
    let body = body(&request, &options, &Pictures::default());
    let tool_call = |id: &str| json!({ "id": id, "type": "function", "function": { "name": "run_code", "arguments": "{}" } });
    assert_eq!(
        body["messages"],
        json!([
            { "role": "system", "content": "你是 Max。" },
            { "role": "user", "content": "[1] 小明：算一下" },
            { "role": "assistant", "content": "好", "reasoning_content": "先算", "tool_calls": [tool_call("c1")] },
            { "role": "tool", "tool_call_id": "c1", "content": "1" },
            { "role": "assistant", "content": "", "tool_calls": [tool_call("c2")] },
            { "role": "tool", "tool_call_id": "c2", "content": "1" },
            { "role": "assistant", "content": "结果是" },
        ])
    );
    assert_eq!(body["stream_options"], json!({ "include_usage": true }));
    assert_eq!(body["reasoning_effort"], "high");
    assert_eq!(body["temperature"], 0.6);
    assert!(body.get("max_tokens").is_none());
    assert_eq!(body["tools"][0]["function"]["name"], "run_code");
}

#[test]
fn signatures_and_inline_thinking_go_back_to_their_model() {
    let flash = model("gemini-3.8-flash");
    let signed = json!({ "extra_content": { "google": { "thought_signature": "sig" } } });
    let request = Request {
        model: flash.clone(),
        items: vec![
            from(
                &flash,
                ItemKind::Reasoning {
                    text: Some("想想".into()),
                },
                Some(json!({ "inline": true })),
            ),
            from(&flash, ItemKind::ToolCall(call("c1", "{}")), Some(signed)),
        ],
        tools: &[],
        max_output: Some(100),
        roster: BTreeSet::new(),
    };
    let body = body(&request, &Options::default(), &Pictures::default());
    let message = &body["messages"][0];
    assert_eq!(message["content"], "<think>\n想想\n</think>\n\n");
    assert_eq!(
        message["tool_calls"][0]["extra_content"]["google"]["thought_signature"],
        "sig"
    );
    assert_eq!(body["max_tokens"], 100);
    assert!(body.get("tools").is_none());
}

/// A row with two pictures, of which max could read only the first, and a
/// block with a picture max couldn't read.
fn with_pictures(model: ModelTag) -> (Request, Pictures) {
    let image = |kind, message, ordinal| Image {
        kind,
        message: MessageId(message),
        ordinal,
    };
    let row = ItemKind::User {
        text: "[新消息]\n[10:00 小明 #7]: [image#7.0][sticker#7.1]".into(),
        images: vec![
            image(MediaKind::Image, 7, 0),
            image(MediaKind::Sticker, 7, 1),
        ],
    };
    let unread = ItemKind::User {
        text: "易变".into(),
        images: vec![image(MediaKind::Image, 3, 0)],
    };
    let request = Request {
        model,
        items: vec![Item::new(unread, 1), Item::new(row, 1)],
        tools: &[],
        max_output: None,
        roster: BTreeSet::new(),
    };
    let url = "data:image/jpeg;base64,AAAA".to_owned();
    let pictures = Pictures([("image#7.0".to_owned(), url)].into());
    (request, pictures)
}

#[test]
fn pictures_follow_their_handles() {
    let (request, pictures) = with_pictures(model("qwen3.8-27b"));
    let messages = body(&request, &Options::default(), &pictures)["messages"].clone();
    let row = json!([
        { "type": "text", "text": "[新消息]\n[10:00 小明 #7]: [image#7.0][sticker#7.1]" },
        { "type": "text", "text": "[image#7.0]" },
        { "type": "image_url", "image_url": { "url": "data:image/jpeg;base64,AAAA" } },
    ]);
    assert_eq!(messages[0]["content"], "易变");
    assert_eq!(messages[1]["content"], row);

    // A breakpoint ends the whole block, pictures and all.
    let mut request = request;
    request.items.push(Item::new(ItemKind::user("后来"), 1));
    let options = Options {
        cache_breakpoints: true,
        ..Options::default()
    };
    let messages = body(&request, &options, &pictures)["messages"].clone();
    let mut marked = row;
    marked[2]["prompt_cache_breakpoint"] = json!({ "mode": "explicit" });
    assert_eq!(messages[1]["content"], marked);
    assert_eq!(messages[2]["content"], "后来");
}

#[test]
fn cache_breakpoints_end_the_stable_blocks() {
    let qwen = model("qwen3.8-27b");
    let user = |text: &str| Item::new(ItemKind::user(text), 1);
    let request = Request {
        model: qwen.clone(),
        items: vec![
            Item::new(
                ItemKind::System {
                    text: "你是 Max。".into(),
                },
                1,
            ),
            user("摘要"),
            user("尾巴"),
            user("易变"),
            from(&qwen, ItemKind::ToolCall(call("c1", "{}")), None),
            result("c1"),
            user("[新消息]"),
        ],
        tools: &[],
        max_output: None,
        roster: BTreeSet::new(),
    };
    let options = Options {
        cache_breakpoints: true,
        ..Options::default()
    };
    let marked = |text: &str| json!([{ "type": "text", "text": text, "prompt_cache_breakpoint": { "mode": "explicit" } }]);
    let messages = body(&request, &options, &Pictures::default())["messages"].clone();
    let contents: Vec<&Value> = messages
        .as_array()
        .unwrap()
        .iter()
        .filter(|message| message["role"] == "user")
        .map(|message| &message["content"])
        .collect();
    assert_eq!(
        contents,
        [
            &marked("摘要"),
            &marked("尾巴"),
            &json!("易变"),
            &json!("[新消息]")
        ]
    );
    let plain = body(&request, &Options::default(), &Pictures::default());
    assert_eq!(plain["messages"][1]["content"], "摘要");
}

fn chunk(delta: Value) -> String {
    json!({ "choices": [{ "index": 0, "delta": delta, "finish_reason": null }] }).to_string()
}

fn finish(reason: &str) -> String {
    json!({ "choices": [{ "index": 0, "delta": {}, "finish_reason": reason }] }).to_string()
}

fn run(parser: &mut Parser, data: &[String]) -> Vec<String> {
    data.iter()
        .flat_map(|data| parser.event(data).unwrap())
        .collect()
}

#[test]
fn reasoning_then_text() {
    let mut parser = Parser::new(model("deepseek-pro"));
    let usage = json!({
        "choices": [],
        "usage": {
            "prompt_tokens": 900, "completion_tokens": 50, "prompt_cache_hit_tokens": 768,
            "completion_tokens_details": { "reasoning_tokens": 30 },
        },
    });
    let events = run(
        &mut parser,
        &[
            chunk(json!({ "role": "assistant", "content": null, "reasoning_content": "用户" })),
            chunk(json!({ "reasoning_content": "打招呼" })),
            chunk(json!({ "content": "早" })),
            chunk(json!({ "content": "啊" })),
            finish("stop"),
            usage.to_string(),
            "[DONE]".into(),
        ],
    );
    assert_eq!(events, ["早", "啊"]);
    assert!(parser.finished());
    let output = parser.finish().unwrap();
    assert_eq!(
        output.usage,
        Usage {
            input: 900,
            cached: 768,
            output: 50,
            reasoning: 30
        }
    );
    assert_eq!(
        output.items[0].kind,
        ItemKind::Reasoning {
            text: Some("用户打招呼".into())
        }
    );
    assert_eq!(
        output.items[0].opaque,
        Some(json!({ "message": { "reasoning_content": "用户打招呼" } }))
    );
    assert_eq!(
        output.items[1].kind,
        ItemKind::Assistant {
            text: "早啊".into()
        }
    );
    assert_eq!((output.items[0].tokens, output.items[1].tokens), (30, 20));
}

#[test]
fn an_answer_starts_with_its_first_output() {
    let started = |data: &[String]| {
        let mut parser = Parser::new(model("deepseek-pro"));
        run(&mut parser, data);
        parser.started()
    };
    let role = chunk(json!({ "role": "assistant", "content": null }));
    assert!(!started(&[
        role.clone(),
        chunk(json!({ "content": "\n " }))
    ]));
    assert!(started(&[
        role.clone(),
        chunk(json!({ "reasoning_content": "用户" }))
    ]));
    assert!(started(&[
        role.clone(),
        chunk(json!({ "content": "<thi" }))
    ]));
    assert!(started(&[role, chunk(json!({ "content": "早" }))]));
    let call = json!({ "index": 0, "id": "c1", "function": { "name": "shell", "arguments": "" } });
    assert!(started(&[chunk(json!({ "tool_calls": [call] }))]));
}

#[test]
fn tool_calls_in_pieces() {
    let mut parser = Parser::new(model("gemini-3.8-flash"));
    let events = run(
        &mut parser,
        &[
            chunk(json!({ "tool_calls": [{
                "index": 0, "id": "c1", "type": "function",
                "function": { "name": "run_code", "arguments": "{\"co" },
                "extra_content": { "google": { "thought_signature": "sig" } },
            }] })),
            chunk(
                json!({ "tool_calls": [{ "index": 0, "function": { "arguments": "de\":1}" } }] }),
            ),
            chunk(
                json!({ "tool_calls": [{ "index": 1, "id": "c2", "function": { "name": "shell", "arguments": "{}" } }] }),
            ),
            finish("tool_calls"),
        ],
    );
    assert!(events.is_empty(), "{events:?}");
    // No [DONE] from this provider: the stream just ends.
    assert!(!parser.finished());
    let output = parser.finish().unwrap();
    assert_eq!(
        output.items[0].kind,
        ItemKind::ToolCall(call("c1", "{\"code\":1}"))
    );
    assert_eq!(
        output.items[0].opaque,
        Some(json!({ "extra_content": { "google": { "thought_signature": "sig" } } }))
    );
    assert_eq!(output.items[1].opaque, None);
    assert_eq!(output.items.len(), 2);
}

#[test]
fn inline_thinking_is_not_said() {
    let mut parser = Parser::new(model("minimax-m3"));
    let events = run(
        &mut parser,
        &["\n", "<thi", "nk>先想", "想</th", "ink>\n\n早", "啊"]
            .map(|piece| chunk(json!({ "content": piece })))
            .into_iter()
            .chain([finish("stop"), "[DONE]".into()])
            .collect::<Vec<_>>(),
    );
    assert_eq!(events, ["早", "啊"]);
    let output = parser.finish().unwrap();
    assert_eq!(
        output.items[0],
        Item {
            kind: ItemKind::Reasoning {
                text: Some("先想想".into())
            },
            source: Some(model("minimax-m3")),
            opaque: Some(json!({ "inline": true })),
            tokens: 0,
        }
    );
    assert_eq!(
        output.items[1].kind,
        ItemKind::Assistant {
            text: "早啊".into()
        }
    );

    // Text that only looks like the start of a tag is said once it isn't.
    let mut parser = Parser::new(model("minimax-m3"));
    let events = run(
        &mut parser,
        &[
            chunk(json!({ "content": "<" })),
            chunk(json!({ "content": "3" })),
        ],
    );
    assert_eq!(events, ["<3"]);
}

#[test]
fn reasoning_written_as_the_answer_is_not_said() {
    let heard = |pieces: &[&str]| {
        let mut parser = Parser::new(model("vertex/gemini-4-argon"));
        let mut chunks: Vec<String> = pieces
            .iter()
            .map(|piece| chunk(json!({ "content": piece })))
            .collect();
        chunks.extend([finish("stop"), "[DONE]".into()]);
        let events = run(&mut parser, &chunks);
        (events, parser.finish())
    };
    for opening in [
        ["Thin", "king Process:\n\n1.  **Analyze", " the Input**"],
        ["**Thought", " Process**", "\n- 先看"],
        ["## 思考过程", "：\n1. 判", "定"],
    ] {
        let (events, output) = heard(&opening);
        assert!(events.is_empty(), "{opening:?}");
        assert!(matches!(output, Err(Error::Aloud)), "{opening:?}");
    }
    // Text that only starts like one is said once it isn't.
    for (pieces, said) in [
        (&["Thin", "k twice"][..], "Think twice"),
        (
            &["Thinking Process: 先", "想"][..],
            "Thinking Process: 先想",
        ),
        (
            &["Thought processes\n", "都慢"][..],
            "Thought processes\n都慢",
        ),
    ] {
        let (events, output) = heard(pieces);
        assert_eq!(events.concat(), said);
        assert!(output.is_ok());
    }
    assert!(Error::Aloud.retryable());
}

#[test]
fn ends_that_are_not_complete() {
    let mut parser = Parser::new(model("deepseek-pro"));
    run(&mut parser, &[chunk(json!({ "content": "早" }))]);
    assert!(matches!(parser.finish(), Err(Error::Truncated)));

    let mut parser = Parser::new(model("deepseek-pro"));
    run(
        &mut parser,
        &[chunk(json!({ "content": "早" })), finish("length")],
    );
    assert_eq!(
        parser.finish().unwrap_err().to_string(),
        "the response stopped early: length"
    );

    let mut parser = Parser::new(model("deepseek-pro"));
    let overloaded = json!({ "error": { "code": "server_overloaded", "message": "busy" } });
    assert!(
        parser
            .event(&overloaded.to_string())
            .unwrap_err()
            .retryable()
    );
    assert!(matches!(parser.event("data"), Err(Error::Malformed(_))));
}

/// A program's result with two pictures, of which the request carries
/// only the first.
fn shown(call: &str) -> Item {
    let blob = |sha256: &str| Part::Media {
        media: MediaRef::Blob(sha256.into()),
    };
    let output = ToolOutput {
        parts: vec![
            Part::Text {
                text: "返回值：\n截好了".into(),
            },
            blob("aa"),
            blob("bb"),
        ],
        error: false,
        tokens: 1,
    };
    Item::new(
        ItemKind::ToolResult {
            call: CallId(call.into()),
            output,
        },
        1,
    )
}

#[test]
fn programs_pictures_follow_their_results() {
    let qwen = model("qwen3.8-27b");
    let request = Request {
        model: qwen.clone(),
        items: vec![
            from(&qwen, ItemKind::ToolCall(call("call_1", "{}")), None),
            from(&qwen, ItemKind::ToolCall(call("call_2", "{}")), None),
            shown("call_1"),
            shown("call_2"),
            Item::new(ItemKind::user("后来"), 1),
        ],
        tools: &[],
        max_output: None,
        roster: BTreeSet::new(),
    };
    let url = "data:image/png;base64,AA";
    let pictures = Pictures([("aa".to_owned(), url.to_owned())].into());
    let messages = body(&request, &Options::default(), &pictures)["messages"].clone();
    let text = |n| format!("返回值：\n截好了\n[图 {n}，见下]\n[这张图省略了，要看再 max.image]");
    assert_eq!(messages[1]["content"], text(1));
    assert_eq!(messages[2]["content"], text(2));
    assert_eq!(
        messages[3],
        json!({ "role": "user", "content": [
            { "type": "text", "text": "[图 1]" },
            { "type": "image_url", "image_url": { "url": url } },
            { "type": "text", "text": "[图 2]" },
            { "type": "image_url", "image_url": { "url": url } },
        ] })
    );
    assert_eq!(messages[4]["content"], "后来");
    assert_eq!(messages.as_array().unwrap().len(), 5);

    // At the end of the request, too.
    let mut request = request;
    request.items.pop();
    let messages = body(&request, &Options::default(), &pictures)["messages"].clone();
    assert_eq!(messages[3]["role"], "user");
    assert_eq!(messages.as_array().unwrap().len(), 4);
}
