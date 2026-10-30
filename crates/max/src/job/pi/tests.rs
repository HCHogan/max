use super::*;

/// pi 1.4's stdout in runs recorded 2026-10-29, trimmed: no streaming
/// updates, no system prompt, no messages at `agent_end`.
const STEER: &str = include_str!("../fixtures/steer.jsonl");
const ABORT: &str = include_str!("../fixtures/abort.jsonl");
const MCP: &str = include_str!("../fixtures/mcp.jsonl");

fn records(fixture: &str) -> Vec<Record> {
    fixture
        .lines()
        .map(|line| parse(line.as_bytes()).unwrap())
        .collect()
}

fn calls(records: &[Record]) -> Vec<Usage> {
    records
        .iter()
        .filter_map(|record| match record {
            Record::Called { usage, error: None } => Some(*usage),
            _ => None,
        })
        .collect()
}

#[test]
fn a_run_with_steers_is_read() {
    let records = records(STEER);
    let calls = calls(&records);
    assert_eq!(calls.len(), 4);
    assert_eq!(
        calls[0],
        Usage {
            input: 1644,
            cached: 0,
            output: 71,
            reasoning: 52
        }
    );
    let tools: Vec<&Record> = records
        .iter()
        .filter(|record| matches!(record, Record::Tool(_)))
        .collect();
    assert_eq!(tools, [&Record::Tool("bash".into()); 3]);
    // The spike's ids weren't numbers.
    assert_eq!(
        records.last(),
        Some(&Record::Response {
            id: None,
            error: None,
            data: json!({ "text": "三个命令分别按顺序执行成功，输出了 `one`、`two` 和 `three`。DONE" }),
        })
    );
    let settled: Vec<&Record> = records
        .iter()
        .filter(|record| matches!(record, Record::Settled { .. }))
        .collect();
    assert_eq!(settled, [&Record::Settled { aborted: false }]);
}

#[test]
fn an_aborted_run_settles_aborted() {
    let records = records(ABORT);
    assert!(records.contains(&Record::Settled { aborted: true }));
    let abort = records.iter().rev().find_map(|record| match record {
        Record::Response { id, error, .. } => Some((*id, error.clone())),
        _ => None,
    });
    assert_eq!(abort, Some((None, None)));
}

#[test]
fn a_run_with_max_tools_is_read() {
    let records = records(MCP);
    assert!(records.contains(&Record::Tool("mcp__max__context_search".into())));
    assert_eq!(calls(&records).len(), 2);
}

#[test]
fn responses_carry_the_commands_id_and_error() {
    let ok = r#"{"id":"7","type":"response","command":"get_last_assistant_text","success":true,"data":{"text":"好"}}"#;
    assert_eq!(
        parse(ok.as_bytes()).unwrap(),
        Record::Response {
            id: Some(7),
            error: None,
            data: json!({ "text": "好" }),
        }
    );
    let refused =
        br#"{"id":"2","type":"response","command":"prompt","success":false,"error":"No model"}"#;
    assert_eq!(
        parse(refused).unwrap(),
        Record::Response {
            id: Some(2),
            error: Some("No model".into()),
            data: Value::Null,
        }
    );
}

#[test]
fn a_failed_call_says_why() {
    let failed = br#"{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"429 Resource exhausted","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}}}"#;
    assert_eq!(
        parse(failed).unwrap(),
        Record::Called {
            usage: Usage::default(),
            error: Some("429 Resource exhausted".into()),
        }
    );
}

#[test]
fn the_cache_counts_in_the_whole_request() {
    let cached = br#"{"type":"message_end","message":{"role":"assistant","stopReason":"stop","usage":{"input":100,"output":20,"cacheRead":900,"cacheWrite":50,"reasoning":5}}}"#;
    assert_eq!(
        parse(cached).unwrap(),
        Record::Called {
            usage: Usage {
                input: 1050,
                cached: 900,
                output: 20,
                reasoning: 5
            },
            error: None,
        }
    );
}

#[test]
fn dialogs_are_dismissed_questions_answered_and_notices_told() {
    let confirm =
        br#"{"type":"extension_ui_request","id":"d-1","method":"confirm","title":"Run it?"}"#;
    assert_eq!(parse(confirm).unwrap(), Record::Dialog("d-1".into()));
    let dismissed: Value = serde_json::from_str(&Ask::Dismiss("d-1").line(9)).unwrap();
    assert_eq!(
        dismissed,
        json!({ "id": "d-1", "type": "extension_ui_response", "cancelled": true })
    );
    // pi 1.4, ask_max's question.
    let input = r#"{"type":"extension_ui_request","id":"q-1","method":"input","title":"今晚选哪家店？","placeholder":""}"#.as_bytes();
    assert_eq!(
        parse(input).unwrap(),
        Record::Question {
            id: "q-1".into(),
            text: "今晚选哪家店？".into()
        }
    );
    let answered: Value = serde_json::from_str(&Ask::Answer("q-1", "海底捞").line(9)).unwrap();
    assert_eq!(
        answered,
        json!({ "id": "q-1", "type": "extension_ui_response", "value": "海底捞" })
    );
    // pi 1.4, its MCP server unreachable.
    let notify = br#"{"type":"extension_ui_request","id":"n-1","method":"notify","message":"MCP servers need attention:\n  max: failed","notifyType":"warning"}"#;
    assert_eq!(
        parse(notify).unwrap(),
        Record::Notice("MCP servers need attention:\n  max: failed".into())
    );
}

#[test]
fn commands_are_a_line_each() {
    let line = Ask::Steer("先看\n第二行").line(3);
    assert!(
        line.ends_with('\n') && !line.trim_end().contains('\n'),
        "{line}"
    );
    let command: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(
        command,
        json!({ "id": "3", "type": "steer", "message": "先看\n第二行" })
    );
}

#[test]
fn lines_are_cut_only_at_lf() {
    let mut lines = Lines::default();
    let mut seen = Vec::new();
    let mut push = |data: &[u8]| lines.push(data, |line| seen.push(line.to_vec()));
    push(b"{\"a\":\"x\xe2\x80\xa8y\"}\r\n{\"b\"");
    push(b":1}\n\n");
    assert_eq!(
        seen,
        [
            b"{\"a\":\"x\xe2\x80\xa8y\"}".to_vec(),
            b"{\"b\":1}".to_vec(),
            Vec::new()
        ]
    );
}

#[test]
fn a_line_too_long_is_dropped() {
    let mut lines = Lines::default();
    let mut seen = Vec::new();
    let long = vec![b'x'; LONGEST];
    lines.push(&long, |line| seen.push(line.len()));
    lines.push(b"more\nshort\n", |line| seen.push(line.len()));
    let mut once = long.clone();
    once.extend_from_slice(b"y\nok\n");
    lines.push(&once, |line| seen.push(line.len()));
    assert_eq!(seen, [5, 2]);
}
