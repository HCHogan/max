use super::*;
use crate::item::{Protocol, ToolCall, Usage};

fn spec(window: u32, max_output: Option<u32>) -> RunSpec {
    RunSpec {
        model: ModelTag {
            protocol: Protocol::Responses,
            model: "m".into(),
        },
        window,
        max_output,
        max_tools: vec![],
    }
}

fn base(tokens: u32) -> Context {
    Context {
        items: vec![Item::new(
            ItemKind::System {
                text: "人设".into(),
            },
            tokens,
        )],
        roster: [PrincipalId(12)].into(),
    }
}

fn wake(id: i64) -> Wake {
    Wake {
        ids: vec![MessageId(id)],
        reason: Reason::Direct,
        item: None,
        handed_over: None,
    }
}

fn messages(id: i64, tokens: u32) -> Input {
    let text = format!("[10:00 小明 #{id}]: 消息{id}");
    Input::Messages {
        ids: vec![MessageId(id)],
        item: Item::new(ItemKind::User { text }, tokens),
    }
}

fn from_model(kind: ItemKind) -> Item {
    Item {
        kind,
        source: Some(spec(0, None).model),
        opaque: None,
        tokens: 10,
    }
}

fn usage(input: u32) -> Usage {
    Usage {
        input,
        output: 10,
        ..Usage::default()
    }
}

fn says(text: &str) -> ModelOutput {
    ModelOutput {
        items: vec![from_model(ItemKind::Assistant { text: text.into() })],
        usage: usage(1000),
    }
}

fn calls(calls: &[(&str, &str)]) -> ModelOutput {
    let items = calls
        .iter()
        .map(|(id, name)| {
            let arguments = r#"{"command": "ls", "code": "return 1"}"#.into();
            let call = ToolCall {
                id: CallId((*id).into()),
                name: (*name).into(),
                arguments,
            };
            from_model(ItemKind::ToolCall(call))
        })
        .collect();
    ModelOutput {
        items,
        usage: usage(1000),
    }
}

fn result(tokens: u32) -> ToolOutput {
    ToolOutput::text("ok", false, tokens)
}

fn call_model(run: &mut Run) -> Request {
    match run.next_step() {
        Step::CallModel(request) => request,
        other => panic!("expected a model call, got {other:?}"),
    }
}

fn run_tools(run: &mut Run) -> Vec<CallId> {
    match run.next_step() {
        Step::RunTools(calls) => calls.into_iter().map(|call| call.id).collect(),
        other => panic!("expected tools, got {other:?}"),
    }
}

fn assert_idle(run: &mut Run) {
    assert!(matches!(run.next_step(), Step::Idle));
}

fn texts(request: &Request) -> Vec<String> {
    request
        .items
        .iter()
        .map(|item| match &item.kind {
            ItemKind::System { text } | ItemKind::User { text } | ItemKind::Assistant { text } => {
                text.clone()
            }
            ItemKind::ToolCall(call) => format!("call {}", call.id),
            ItemKind::ToolResult { call, output } => {
                format!("result {call} error={}", output.error)
            }
            ItemKind::Reasoning { .. } => "reasoning".into(),
        })
        .collect()
}

#[test]
fn the_limit() {
    // 400k window, 128k output: 252k available; 100k of base leaves 152k,
    // where half the window alone would allow 200k.
    assert_eq!(spec(400_000, Some(128_000)).limit(100_000), 152_000);
    assert_eq!(spec(400_000, Some(128_000)).limit(10_000), 200_000);
    assert_eq!(spec(10_000, None).limit(1_000), 5_000);
    assert_eq!(spec(10_000, None).limit(9_000), 0);
}

#[test]
fn answers_and_goes_idle() {
    let mut run = Run::new(spec(400_000, None), base(100), vec![Input::Wake(wake(1))]);
    assert_eq!(texts(&call_model(&mut run)), ["人设"]);
    assert!(run.busy());
    assert_idle(&mut run);
    run.model_output(says("好")).unwrap();
    assert_idle(&mut run);
}

#[test]
fn inputs_wait_for_the_tool_batch() {
    let mut run = Run::new(spec(400_000, None), base(100), vec![]);
    call_model(&mut run);
    run.model_output(calls(&[("a", "shell"), ("b", "run_code")]))
        .unwrap();
    assert_eq!(
        run_tools(&mut run),
        [CallId("a".into()), CallId("b".into())]
    );
    run.input(messages(2, 5)).unwrap();
    run.input(Input::Wake(wake(2))).unwrap();
    run.tool_result(CallId("b".into()), result(5)).unwrap();
    assert!(run.busy());
    assert_idle(&mut run);
    run.tool_result(CallId("a".into()), result(5)).unwrap();
    let request = call_model(&mut run);
    assert_eq!(
        texts(&request)[1..],
        [
            "call a",
            "call b",
            "result b error=false",
            "result a error=false",
            "[新消息]\n[10:00 小明 #2]: 消息2",
        ]
    );
}
