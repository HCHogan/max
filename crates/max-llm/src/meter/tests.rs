use max_core::item::ModelTag;

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

        let meter = metered(protocol, &recorded);
        assert_eq!(meter.usage(), output.usage, "{name}");
        assert!(meter.started(), "{name}");
    }
}

#[test]
fn lines_end_either_way_and_a_field_goes_on_in_the_next() {
    let crlf = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"ba\"}}]}}]}\r\n\r\n\
                : a comment\r\n\
                data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"sh\"}}]}}],\r\n\
                data: \"usage\":{\"prompt_tokens\":10,\"completion_tokens\":2}}\r\n\r\n";
    let cut = metered(Protocol::Chat, crlf.as_bytes());
    assert!(cut.started());
    assert_eq!(cut.usage().input, 10);
    // Read to its end, it used the same.
    let done = format!("{crlf}data: [DONE]\n\n");
    assert_eq!(metered(Protocol::Chat, done.as_bytes()).usage().input, 10);
}

#[test]
fn an_answer_that_isnt_streamed_has_its_usage_too() {
    let chat = br#"
{"id":"c1","choices":[{"message":{"role":"assistant","content":"data: {}"}}],
 "usage":{"prompt_tokens":40,"completion_tokens":3,"prompt_tokens_details":{"cached_tokens":8}}}"#;
    let meter = metered(Protocol::Chat, chat);
    let used = Usage {
        input: 40,
        cached: 8,
        output: 3,
        reasoning: 0,
    };
    assert_eq!(meter.usage(), used);
    // It never began, as far as anyone watching the pieces could tell.
    assert!(!meter.started());

    let response = br#"{"id":"r1","output":[],"usage":{"input_tokens":70,"output_tokens":5,"output_tokens_details":{"reasoning_tokens":2}}}"#;
    let meter = metered(Protocol::Responses, response);
    let used = Usage {
        input: 70,
        cached: 0,
        output: 5,
        reasoning: 2,
    };
    assert_eq!(meter.usage(), used);

    // An error, or one cut short, used nothing anyone can read.
    for bytes in [&br#"{"error":{"message":"no"}}"#[..], &response[..40]] {
        assert_eq!(
            metered(Protocol::Responses, bytes).usage(),
            Usage::default()
        );
    }
}
