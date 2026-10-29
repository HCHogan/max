use super::*;
use crate::item::{Image, Protocol, ToolCall, Usage};
use crate::message::MediaKind;

fn spec(window: u32, max_output: Option<u32>) -> RunSpec {
    RunSpec {
        model: ModelTag {
            protocol: Protocol::Responses,
            model: "m".into(),
        },
        window,
        max_output,
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
    }
}

fn messages(id: i64, tokens: u32) -> Input {
    let text = format!("[10:00 小明 #{id}]: 消息{id}");
    Input::Messages {
        ids: vec![MessageId(id)],
        item: Item::new(ItemKind::user(text), tokens),
        people: Vec::new(),
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
            ItemKind::System { text }
            | ItemKind::User { text, .. }
            | ItemKind::Assistant { text } => text.clone(),
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
    assert!(run.idle());
    assert!(run.unhandled().is_empty());
    assert_eq!(run.outcome(), Outcome::Answered);
}

#[test]
fn people_shown_mid_run_can_be_mentioned() {
    let mut run = Run::new(spec(400_000, None), base(100), vec![Input::Wake(wake(1))]);
    assert_eq!(call_model(&mut run).roster, [PrincipalId(12)].into());
    let Input::Messages { ids, item, .. } = messages(2, 10) else {
        unreachable!()
    };
    let people = vec![PrincipalId(30)];
    run.input(Input::Messages { ids, item, people }).unwrap();
    run.input(Input::Wake(wake(2))).unwrap();
    run.model_output(says("[mention#30] 你好")).unwrap();
    assert_eq!(
        call_model(&mut run).roster,
        [PrincipalId(12), PrincipalId(30)].into()
    );
}

#[test]
fn chatter_waits_for_a_trigger() {
    let mut run = Run::new(spec(400_000, None), base(100), vec![]);
    call_model(&mut run);
    run.model_output(says("[silence]")).unwrap();
    assert_eq!(run.outcome(), Outcome::Silent);
    run.input(messages(2, 5)).unwrap();
    assert_idle(&mut run);
    run.input(messages(3, 5)).unwrap();
    assert_idle(&mut run);
    run.input(Input::Wake(wake(3))).unwrap();
    let request = call_model(&mut run);
    assert_eq!(
        texts(&request).last().unwrap(),
        "[新消息]\n[10:00 小明 #2]: 消息2\n[10:00 小明 #3]: 消息3"
    );
}

#[test]
fn pictures_follow_the_new_rows_they_came_with() {
    let image = |kind, message, ordinal| Image {
        kind,
        message: MessageId(message),
        ordinal,
    };
    let with = |id: i64, images: Vec<Image>| {
        let text = format!("[10:00 小明 #{id}]: [image#{id}.0]");
        Input::Messages {
            ids: vec![MessageId(id)],
            item: Item::new(ItemKind::User { text, images }, 900),
            people: Vec::new(),
        }
    };
    let mut run = Run::new(spec(400_000, None), base(100), vec![]);
    call_model(&mut run);
    run.model_output(says("[silence]")).unwrap();
    run.input(with(2, vec![image(MediaKind::Image, 2, 0)]))
        .unwrap();
    run.input(messages(3, 5)).unwrap();
    let four = vec![
        image(MediaKind::Image, 4, 0),
        image(MediaKind::Sticker, 4, 1),
    ];
    run.input(with(4, four)).unwrap();
    run.input(Input::Wake(wake(4))).unwrap();
    let request = call_model(&mut run);
    let last = request.items.last().unwrap();
    let ItemKind::User { images, .. } = &last.kind else {
        panic!("{last:?}")
    };
    let handles: Vec<String> = images.iter().map(Image::handle).collect();
    assert_eq!(handles, ["image#2.0", "image#4.0", "sticker#4.1"]);
    assert_eq!(last.tokens, 1805);
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

#[test]
fn malformed_calls_get_an_error_and_never_run() {
    let mut run = Run::new(spec(400_000, None), base(100), vec![]);
    call_model(&mut run);
    run.model_output(calls(&[("a", "send_message"), ("b", "shell")]))
        .unwrap();
    assert_eq!(run_tools(&mut run), [CallId("b".into())]);
    run.tool_result(CallId("b".into()), result(5)).unwrap();
    let request = call_model(&mut run);
    assert_eq!(
        texts(&request)[1..],
        [
            "call a",
            "call b",
            "result a error=true",
            "result b error=false"
        ]
    );
    // Only malformed calls: straight back to the model.
    run.model_output(calls(&[("c", "nope")])).unwrap();
    call_model(&mut run);
}

#[test]
fn what_doesnt_fit_is_rejected_and_changes_nothing() {
    let mut run = Run::new(spec(400_000, None), base(100), vec![]);
    assert_eq!(run.model_output(says("x")), Err(Rejected::NoModelCall));
    assert_eq!(
        run.tool_result(CallId("a".into()), result(1)),
        Err(Rejected::UnknownCall)
    );
    assert!(run.record().transcript.is_empty());
    assert_eq!(texts(&call_model(&mut run)), ["人设"]);
}

#[test]
fn the_record_is_what_the_model_saw_and_said() {
    let mut run = Run::new(spec(400_000, None), base(100), vec![Input::Wake(wake(1))]);
    call_model(&mut run);
    run.model_output(calls(&[("a", "shell")])).unwrap();
    run_tools(&mut run);
    run.tool_result(CallId("a".into()), result(5)).unwrap();
    run.input(messages(2, 5)).unwrap();
    let request = call_model(&mut run);
    let record = run.record();
    let shown: Vec<&Item> = record.base.items.iter().chain(record.transcript).collect();
    assert_eq!(shown, request.items.iter().collect::<Vec<_>>());
    // The model's output is in it once.
    run.model_output(says("好")).unwrap();
    let json = serde_json::to_value(run.record()).unwrap();
    assert_eq!(json["transcript"].as_array().unwrap().len(), 4);
    assert_eq!(json["spec"]["window"], 400_000);
}

#[test]
fn the_limit_counts_waiting_inputs() {
    // Window 10k: the core may grow 5k past its 1k base.
    let mut run = Run::new(spec(10_000, None), base(1_000), vec![Input::Wake(wake(1))]);
    call_model(&mut run);
    run.model_output(calls(&[("a", "shell")])).unwrap(); // measured: 1,010
    run_tools(&mut run);
    run.tool_result(CallId("a".into()), result(3_000)).unwrap();
    assert!(!run.at_limit());
    run.input(messages(2, 2_000)).unwrap();
    run.input(Input::Wake(wake(2))).unwrap();
    assert!(run.at_limit());
    // Neither trigger has been handled.
    let ids: Vec<_> = run
        .unhandled()
        .into_iter()
        .flat_map(|wake| wake.ids)
        .collect();
    assert_eq!(ids, [MessageId(1), MessageId(2)]);
    // A base that leaves no room is at the limit from the start.
    let full = Run::new(spec(10_000, None), base(9_000), vec![Input::Wake(wake(1))]);
    assert!(full.at_limit());
}

#[test]
fn a_trigger_is_handled_at_the_next_output_without_tools() {
    let mut run = Run::new(spec(400_000, None), base(100), vec![Input::Wake(wake(1))]);
    call_model(&mut run);
    run.input(Input::Wake(wake(2))).unwrap();
    run.model_output(calls(&[("a", "shell")])).unwrap();
    run_tools(&mut run);
    run.tool_result(CallId("a".into()), result(5)).unwrap();
    call_model(&mut run);
    // The model has seen both but hasn't finished with them.
    assert_eq!(run.unhandled().len(), 2);
    run.model_output(says("好")).unwrap();
    assert!(run.unhandled().is_empty());
    run.input(Input::Wake(wake(3))).unwrap();
    assert_eq!(run.unhandled(), [wake(3)]);
}

#[test]
fn interrupt_closes_open_calls() {
    let mut run = Run::new(spec(400_000, None), base(100), vec![]);
    call_model(&mut run);
    run.model_output(calls(&[("a", "shell"), ("b", "shell")]))
        .unwrap();
    run_tools(&mut run);
    run.tool_result(CallId("a".into()), result(5)).unwrap();
    run.interrupt().unwrap();
    assert!(!run.busy());
    assert_idle(&mut run);
    assert_eq!(run.outcome(), Outcome::Interrupted);
    assert_eq!(run.input(messages(2, 5)), Err(Rejected::Ended));
    let transcript = run.transcript.iter().filter_map(|item| match &item.kind {
        ItemKind::ToolResult { call, output } => Some((call.0.as_str(), output.error)),
        _ => None,
    });
    assert_eq!(transcript.collect::<Vec<_>>(), [("a", false), ("b", true)]);
}

#[test]
fn a_cut_off_call_keeps_what_was_said() {
    let mut run = Run::new(spec(400_000, None), base(100), vec![]);
    call_model(&mut run);
    run.partial_output("说到一半".into(), 4).unwrap();
    run.fail(FailReason::Model {
        error: "reset".into(),
    })
    .unwrap();
    assert_eq!(
        run.outcome(),
        Outcome::Failed {
            reason: FailReason::Model {
                error: "reset".into()
            }
        }
    );
    assert!(run.said());
}
