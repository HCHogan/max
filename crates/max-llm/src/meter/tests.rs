use max_core::item::{ItemKind, ModelTag};

use super::*;
use crate::Call;

/// The responses `tests/replay.rs` reads, recorded from real providers.
const RECORDED: [&str; 8] = [
    "chat-deepseek-1",
    "chat-deepseek-2",
    "chat-gemini-1",
    "chat-gemini-2",
    "chat-qwen-1",
    "chat-qwen-2",
    "responses-luna-1",
    "responses-luna-2",
];

/// `bytes` as they might come over the wire: cut anywhere.
fn metered(protocol: Protocol, bytes: &[u8]) -> Meter {
    let mut meter = Meter::new(protocol);
    for piece in bytes.chunks(7) {
        meter.push(piece);
    }
    meter
}

#[tokio::test]
async fn a_forwarded_call_counts_as_maxs_own_would() {
    for name in RECORDED {
        let path = format!("{}/tests/recorded/{name}.sse", env!("CARGO_MANIFEST_DIR"));
        let recorded = std::fs::read(&path).unwrap();
        let protocol = if name.starts_with("chat") {
            Protocol::Chat
        } else {
            Protocol::Responses
        };
        let model = ModelTag {
            protocol,
            model: "m".into(),
        };
        let mut call = Call::replay(model, recorded.clone());
        while call.next().await.unwrap().is_some() {}
        let output = call.finish().unwrap();
        let called: Vec<String> = output
            .items
            .iter()
            .filter_map(|item| match &item.kind {
                ItemKind::ToolCall(call) => Some(call.name.clone()),
                _ => None,
            })
            .collect();

        let meter = metered(protocol, &recorded);
        assert_eq!(meter.usage(), output.usage, "{name}");
        assert_eq!(meter.tools(), called, "{name}");
        assert!(meter.started(), "{name}");
    }
}

#[test]
fn lines_end_either_way_and_a_cut_answer_called_nothing() {
    let crlf = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"ba\"}}]}}]}\r\n\r\n\
                : a comment\r\n\
                data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"sh\"}}]}}],\r\n\
                data: \"usage\":{\"prompt_tokens\":10,\"completion_tokens\":2}}\r\n\r\n";
    let cut = metered(Protocol::Chat, crlf.as_bytes());
    assert!(cut.started());
    assert_eq!(cut.usage().input, 10);
    assert_eq!(cut.tools(), Vec::<String>::new());

    let done = format!("{crlf}data: [DONE]\n\n");
    assert_eq!(metered(Protocol::Chat, done.as_bytes()).tools(), ["bash"]);
}
