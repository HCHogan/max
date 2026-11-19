use std::collections::BTreeSet;
use std::sync::Arc;

use max_core::item::{Protocol, ToolOutput};
use max_core::tools::TOOLS;

use serde_json::json;

use super::*;

/// The body as the provider reads it.
fn sent(request: &Request, options: &Options, pictures: &Pictures) -> Value {
    serde_json::to_value(body(request, options, pictures)).unwrap()
}

fn luna() -> ModelTag {
    ModelTag {
        protocol: Protocol::Responses,
        model: "gpt-5.6-luna".into(),
    }
}

fn from(model: &ModelTag, kind: ItemKind, raw: Value) -> Item {
    Item {
        kind,
        source: Some(model.clone()),
        opaque: Some(raw),
        tokens: 0,
    }
}

fn call(id: &str) -> ToolCall {
    ToolCall {
        id: CallId::new(id),
        name: "run_code".into(),
        arguments: r#"{"code":"return 1"}"#.into(),
    }
}

#[test]
fn a_request() {
    let other = ModelTag {
        protocol: Protocol::Chat,
        model: "deepseek-pro".into(),
    };
    let reasoning =
        json!({ "type": "reasoning", "id": "rs_1", "summary": [], "encrypted_content": "gAAA" });
    let message = json!({
        "type": "message", "id": "msg_1", "role": "assistant", "status": "completed",
        "content": [{ "type": "output_text", "text": "早", "annotations": [] }],
    });
    let request = Request {
        model: luna(),
        items: [
            Item::new(
                ItemKind::System {
                    text: "你是 Max。".into(),
                },
                5,
            ),
            Item::new(
                ItemKind::System {
                    text: "群规".into(),
                },
                2,
            ),
            Item::new(ItemKind::user("[1] 小明：早"), 5),
            from(
                &luna(),
                ItemKind::Reasoning { text: None },
                reasoning.clone(),
            ),
            from(
                &luna(),
                ItemKind::Assistant { text: "早".into() },
                message.clone(),
            ),
            // Another model's: its reasoning goes, its call is rebuilt.
            from(
                &other,
                ItemKind::Reasoning {
                    text: Some("想想".into()),
                },
                json!({}),
            ),
            from(
                &other,
                ItemKind::ToolCall(call("call_9")),
                json!({ "x": 1 }),
            ),
            Item::new(
                ItemKind::ToolResult {
                    call: CallId::new("call_9"),
                    output: ToolOutput::text("1", false, 1),
                },
                1,
            ),
        ]
        .map(Arc::new)
        .into(),
        tools: &*TOOLS,
        max_output: Some(8000),
        roster: BTreeSet::new(),
    };
    let options = Options {
        effort: Some("xhigh".into()),
        session: Some("max-7".into()),
        ..Options::default()
    };
    let body = sent(&request, &options, &Pictures::default());
    assert_eq!(body["instructions"], "你是 Max。\n\n群规");
    assert_eq!(
        body["input"],
        json!([
            { "role": "user", "content": "[1] 小明：早" },
            reasoning,
            message,
            { "type": "function_call", "call_id": "call_9", "name": "run_code", "arguments": "{\"code\":\"return 1\"}" },
            { "type": "function_call_output", "call_id": "call_9", "output": "1" },
        ])
    );
    assert_eq!(body["store"], false);
    assert_eq!(body["stream"], true);
    assert_eq!(body["include"], json!(["reasoning.encrypted_content"]));
    assert_eq!(body["max_output_tokens"], 8000);
    assert_eq!(body["prompt_cache_key"], "max-7");
    assert_eq!(
        body["reasoning"],
        json!({ "effort": "xhigh", "summary": "auto" })
    );
    assert_eq!(body["tools"][0]["name"], "run_code");
    assert_eq!(body["tools"][0]["parameters"]["required"], json!(["code"]));
    assert_eq!(body["tools"][0]["strict"], false);
    assert!(body.get("temperature").is_none());
}

fn feed(parser: &mut Parser, events: &[Value]) -> Vec<String> {
    events
        .iter()
        .flat_map(|event| parser.event(&event.to_string()).unwrap())
        .collect()
}

#[test]
fn ends_that_are_not_complete() {
    let mut parser = Parser::new(luna());
    feed(
        &mut parser,
        &[json!({ "type": "response.output_text.delta", "delta": "早" })],
    );
    assert!(matches!(parser.finish(), Err(Error::Truncated)));

    let mut parser = Parser::new(luna());
    let incomplete = json!({
        "type": "response.incomplete",
        "response": { "incomplete_details": { "reason": "max_output_tokens" } },
    });
    let error = parser.event(&incomplete.to_string()).unwrap_err();
    assert_eq!(
        error.to_string(),
        "the response stopped early: max_output_tokens"
    );

    let failed = json!({
        "type": "response.failed",
        "response": { "error": { "code": "server_error", "message": "try again" } },
    });
    assert!(
        parser
            .event(&failed.to_string())
            .unwrap_err()
            .is_retryable()
    );
    let error = json!({ "type": "error", "code": "invalid_request_error", "message": "bad" });
    assert!(!parser.event(&error.to_string()).unwrap_err().is_retryable());
    assert!(matches!(parser.event("{"), Err(Error::Malformed(_))));
}
