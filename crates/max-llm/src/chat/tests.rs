use std::collections::BTreeSet;
use std::sync::Arc;

use max_core::item::{Protocol, ToolOutput};
use max_core::tools::TOOLS;

use super::*;

/// The body as the provider reads it.
fn sent(request: &Request, options: &Options, pictures: &Pictures) -> Value {
    serde_json::to_value(body(request, options, pictures)).unwrap()
}

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
        items: [
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
        ]
        .map(Arc::new)
        .into(),
        tools: &*TOOLS,
        max_output: None,
        roster: BTreeSet::new(),
    };
    let options = Options {
        effort: Some("high".into()),
        temperature: Some(0.6),
        ..Options::default()
    };
    let body = sent(&request, &options, &Pictures::default());
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
