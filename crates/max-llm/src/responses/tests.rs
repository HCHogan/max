use std::collections::BTreeSet;

use max_core::ids::MessageId;
use max_core::item::{Image, Part, Protocol, ToolOutput};
use max_core::message::{MediaKind, MediaRef};
use max_core::tools::TOOLS;

use super::*;

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
        id: CallId(id.into()),
        name: "run_code".into(),
        arguments: r#"{"code":"return 1"}"#.into(),
    }
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
    let (request, pictures) = with_pictures(luna());
    let body = body(&request, &Options::default(), &pictures);
    assert_eq!(
        body["input"],
        json!([
            { "role": "user", "content": "易变" },
            { "role": "user", "content": [
                { "type": "input_text", "text": "[新消息]\n[10:00 小明 #7]: [image#7.0][sticker#7.1]" },
                { "type": "input_text", "text": "[image#7.0]" },
                { "type": "input_image", "image_url": "data:image/jpeg;base64,AAAA", "detail": "auto" },
            ] },
        ])
    );
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
        items: vec![
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
                    call: CallId("call_9".into()),
                    output: ToolOutput::text("1", false, 1),
                },
                1,
            ),
        ],
        tools: &TOOLS,
        max_output: Some(8000),
        roster: BTreeSet::new(),
    };
    let options = Options {
        effort: Some("xhigh".into()),
        ..Options::default()
    };
    let body = body(&request, &options, &Pictures::default());
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
fn a_streamed_response() {
    let reasoning = json!({
        "type": "reasoning", "id": "rs_1", "encrypted_content": "gAAA",
        "summary": [{ "type": "summary_text", "text": "**Greeting**" }],
    });
    let message = json!({
        "type": "message", "id": "msg_1", "role": "assistant", "status": "completed",
        "content": [{ "type": "output_text", "text": "早啊", "annotations": [] }],
    });
    let function_call = json!({
        "type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "run_code",
        "arguments": "{\"code\":\"return 1\"}", "status": "completed",
    });
    let mut parser = Parser::new(luna());
    let created = json!({ "type": "response.created", "response": { "status": "in_progress" } });
    feed(&mut parser, &[created]);
    assert!(!parser.started());
    let events = feed(
        &mut parser,
        &[
            json!({ "type": "response.output_item.added", "item": { "type": "reasoning" } }),
            json!({ "type": "response.reasoning_summary_text.delta", "delta": "**Gre" }),
            json!({ "type": "response.output_text.delta", "delta": "早" }),
            json!({ "type": "response.output_text.delta", "delta": "啊" }),
            json!({ "type": "response.output_item.added", "item": { "type": "function_call", "name": "run_code" } }),
            json!({ "type": "response.function_call_arguments.delta", "delta": "{\"code\"" }),
        ],
    );
    assert_eq!(events, ["早", "啊"]);
    assert!(parser.started() && !parser.finished());
    let completed = json!({
        "type": "response.completed",
        "response": {
            "status": "completed",
            "output": [reasoning, message, function_call, { "type": "web_search_call", "id": "ws_1" }],
            "usage": {
                "input_tokens": 1200,
                "input_tokens_details": { "cached_tokens": 1024 },
                "output_tokens": 90,
                "output_tokens_details": { "reasoning_tokens": 64 },
            },
        },
    });
    assert!(feed(&mut parser, &[completed]).is_empty());
    assert!(parser.finished());

    let output = parser.finish().unwrap();
    assert_eq!(
        output.usage,
        Usage {
            input: 1200,
            cached: 1024,
            output: 90,
            reasoning: 64
        }
    );
    let kinds: Vec<&ItemKind> = output.items.iter().map(|item| &item.kind).collect();
    assert_eq!(
        kinds,
        [
            &ItemKind::Reasoning {
                text: Some("**Greeting**".into())
            },
            &ItemKind::Assistant {
                text: "早啊".into()
            },
            &ItemKind::ToolCall(call("call_1")),
        ]
    );
    assert_eq!(output.items[0].opaque, Some(reasoning));
    assert_eq!(output.items[2].opaque, Some(function_call));
    assert!(output.items.iter().all(|item| item.source == Some(luna())));
    let tokens: u32 = output.items.iter().map(|item| item.tokens).sum();
    assert_eq!((output.items[0].tokens, tokens), (64, 90));
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
    assert!(parser.event(&failed.to_string()).unwrap_err().retryable());
    let error = json!({ "type": "error", "code": "invalid_request_error", "message": "bad" });
    assert!(!parser.event(&error.to_string()).unwrap_err().retryable());
    assert!(matches!(parser.event("{"), Err(Error::Malformed(_))));
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
fn a_programs_pictures_go_in_its_output() {
    let request = Request {
        model: luna(),
        items: vec![shown("call_1")],
        tools: &[],
        max_output: None,
        roster: BTreeSet::new(),
    };
    let pictures = Pictures([("aa".to_owned(), "data:image/png;base64,AA".to_owned())].into());
    let body = body(&request, &Options::default(), &pictures);
    assert_eq!(
        body["input"][0]["output"],
        json!([
            { "type": "input_text", "text": "返回值：\n截好了" },
            { "type": "input_image", "image_url": "data:image/png;base64,AA", "detail": "auto" },
            { "type": "input_text", "text": "[这张图省略了，要看再 max.image]" },
        ])
    );
    // Without pictures to send, the output stays text.
    let body = super::body(&request, &Options::default(), &Pictures::default());
    assert_eq!(
        body["input"][0]["output"],
        "返回值：\n截好了\n[这张图省略了，要看再 max.image]\n[这张图省略了，要看再 max.image]"
    );
}
