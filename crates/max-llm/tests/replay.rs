//! Responses recorded from real providers with `examples/record.rs`: the
//! model is asked for 2⁶⁴, calls `run_code`, gets the number back and
//! answers. Each one is read the way a live call would be, and the first
//! step's items are lowered again to check what would be sent back.

#![expect(
    clippy::unwrap_used,
    reason = "the helpers are part of the tests and fail them by panicking"
)]

use std::collections::BTreeSet;

use max_core::ids::CallId;
use max_core::item::{Item, ItemKind, ModelOutput, ModelTag, Protocol, ToolOutput};
use max_core::run::Request;
use max_core::tools::TOOLS;
use max_llm::{Call, Event, Options, chat, responses};
use serde_json::Value;

/// What a recorded response said as it streamed, and what it came to.
struct Replayed {
    said: String,
    announced: Vec<String>,
    output: ModelOutput,
}

async fn replay(model: &ModelTag, name: &str) -> Replayed {
    let path = format!("{}/tests/recorded/{name}.sse", env!("CARGO_MANIFEST_DIR"));
    let recorded = std::fs::read(&path).unwrap();
    let mut call = Call::replay(model.clone(), recorded);
    let mut said = String::new();
    let mut announced = Vec::new();
    while let Some(event) = call.next().await.unwrap() {
        match event {
            Event::Text(text) => said.push_str(&text),
            Event::ToolCall { name } => announced.push(name),
        }
    }
    let output = call.finish().unwrap();
    let tokens: u32 = output.items.iter().map(|item| item.tokens).sum();
    let reasons = output
        .items
        .iter()
        .any(|item| matches!(item.kind, ItemKind::Reasoning { .. }));
    let hidden = if reasons { 0 } else { output.usage.reasoning };
    assert_eq!(tokens, output.usage.output - hidden, "{name}");
    assert!(
        output
            .items
            .iter()
            .all(|item| item.source.as_ref() == Some(model))
    );
    Replayed {
        said,
        announced,
        output,
    }
}

/// Replays both steps of an exchange and returns the first step's items
/// lowered back for the same model.
async fn exchange(model: &ModelTag, name: &str) -> (ModelOutput, Value) {
    let first = replay(model, &format!("{name}-1")).await;
    let calls: Vec<_> = first
        .output
        .items
        .iter()
        .filter_map(|item| match &item.kind {
            ItemKind::ToolCall(call) => Some(call.clone()),
            _ => None,
        })
        .collect();
    let [call] = calls.as_slice() else {
        panic!("{name}: expected one call, got {calls:?}");
    };
    assert_eq!(call.name, "run_code");
    let arguments: Value = serde_json::from_str(&call.arguments).unwrap();
    assert!(arguments["code"].as_str().unwrap().contains("64"));
    assert_eq!(first.announced, ["run_code"]);
    assert_eq!(first.said, "");

    let second = replay(model, &format!("{name}-2")).await;
    let answers: Vec<&str> = second
        .output
        .items
        .iter()
        .filter_map(|item| match &item.kind {
            ItemKind::Assistant { text } => Some(text.as_str()),
            _ => None,
        })
        .collect();
    let [answer] = answers.as_slice() else {
        panic!("{name}: expected one answer, got {answers:?}");
    };
    assert_eq!(second.said.trim_start(), *answer);
    assert!(answer.replace(',', "").contains("18446744073709551616"));
    assert!(second.announced.is_empty());

    let mut items = vec![Item::new(
        ItemKind::User {
            text: "[1] 小明：2 的 64 次方是多少？".into(),
        },
        20,
    )];
    items.extend(first.output.items.iter().cloned());
    items.push(Item::new(
        ItemKind::ToolResult {
            call: CallId(call.id.0.clone()),
            output: ToolOutput::text("18446744073709551616", false, 8),
        },
        8,
    ));
    let request = Request {
        model: model.clone(),
        items,
        tools: &TOOLS,
        max_output: None,
        roster: BTreeSet::new(),
    };
    let body = match model.protocol {
        Protocol::Responses => responses::body(&request, &Options::default()),
        Protocol::Chat => chat::body(&request, &Options::default()),
    };
    (first.output, body)
}

fn chat_model(name: &str) -> ModelTag {
    ModelTag {
        protocol: Protocol::Chat,
        model: name.into(),
    }
}

#[tokio::test]
async fn gpt_through_cliproxy() {
    let luna = ModelTag {
        protocol: Protocol::Responses,
        model: "gpt-5.6-luna".into(),
    };
    let (first, body) = exchange(&luna, "responses-luna").await;
    let reasoning = &first.items[0];
    assert!(
        matches!(&reasoning.kind, ItemKind::Reasoning { text: Some(text) } if !text.is_empty())
    );
    assert_eq!(first.usage.reasoning, reasoning.tokens);
    // Back exactly as it came, encrypted reasoning and all.
    let input = body["input"].as_array().unwrap();
    assert_eq!(Some(&input[1]), reasoning.opaque.as_ref());
    assert!(input[1]["encrypted_content"].as_str().is_some());
    assert_eq!(input[2]["type"], "function_call");
    assert_eq!(input[3]["type"], "function_call_output");
}

#[tokio::test]
async fn deepseek() {
    let (first, body) = exchange(&chat_model("deepseek-v4-pro"), "chat-deepseek").await;
    assert!(matches!(
        first.items[0].kind,
        ItemKind::Reasoning { text: Some(_) }
    ));
    let message = &body["messages"][1];
    assert_eq!(message["role"], "assistant");
    assert!(
        message["reasoning_content"]
            .as_str()
            .unwrap()
            .contains("64")
    );
    assert_eq!(message["tool_calls"][0]["function"]["name"], "run_code");
}

#[tokio::test]
async fn gemini_through_cliproxy() {
    let (first, body) = exchange(&chat_model("gemini-3.8-flash-high"), "chat-gemini").await;
    assert!(matches!(
        first.items[0].kind,
        ItemKind::Reasoning { text: Some(_) }
    ));
    assert!(body["messages"][1]["reasoning_content"].is_string());
}

#[tokio::test]
async fn qwen_on_vllm() {
    let qwen = chat_model("qwen3.8-27b");
    let (first, body) = exchange(&qwen, "chat-qwen").await;
    assert!(matches!(
        first.items[0].kind,
        ItemKind::Reasoning { text: Some(_) }
    ));
    assert_eq!(body["messages"][2]["role"], "tool");
    // The second step reused the cached prefix.
    let second = replay(&qwen, "chat-qwen-2").await;
    assert!(second.output.usage.cached > 0);
}
