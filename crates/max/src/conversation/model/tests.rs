use std::sync::Arc;

use max_core::message::DraftNode;
use tokio::sync::mpsc;

use super::*;
use crate::llm::testing::{Answer, Script, models};

fn request(chosen: &Chosen) -> Request {
    Request {
        model: chosen.tag.clone(),
        items: Vec::new(),
        tools: &[],
        max_output: None,
        roster: Default::default(),
    }
}

/// Runs a call to its end and gives back what it sent: each `Said` as its
/// text, then the result.
async fn run(script: &Arc<Script>) -> (Vec<String>, Result<(), String>) {
    let chosen = models(script).turn(None, None).unwrap();
    let (tx, mut rx) = mpsc::unbounded_channel();
    call(chosen.clone(), request(&chosen), TaskId(1), tx).await;
    let mut said = Vec::new();
    while let Ok(event) = rx.try_recv() {
        match event {
            Event::Said { task, segment } => {
                assert_eq!(task, TaskId(1));
                let [DraftNode::Text { text }] = &segment.draft.nodes[..] else {
                    panic!("{segment:?}");
                };
                said.push(text.clone());
            }
            Event::ModelDone { task, out } => {
                assert_eq!(task, TaskId(1));
                assert!(rx.try_recv().is_err(), "an event after ModelDone");
                return (said, out.map(|_| ()));
            }
            other => panic!("{other:?}"),
        }
    }
    panic!("no ModelDone");
}

fn unavailable() -> max_llm::Error {
    max_llm::Error::Status {
        status: 503,
        body: "busy".into(),
    }
}

#[tokio::test(start_paused = true)]
async fn messages_as_they_stream() {
    let script = Arc::new(Script::default());
    script.push(Answer::Says(vec!["在的\n".into(), "\n说吧".into()]));
    let (said, out) = run(&script).await;
    assert_eq!(said, ["在的", "说吧"]);
    assert_eq!(out, Ok(()));
}

#[tokio::test(start_paused = true)]
async fn retried_while_nothing_is_said() {
    let script = Arc::new(Script::default());
    script.push(Answer::Fails(unavailable()));
    script.push(Answer::Breaks(Vec::new()));
    script.push(Answer::says("好了"));
    let (said, out) = run(&script).await;
    assert_eq!((said, out), (vec!["好了".to_owned()], Ok(())));
    assert_eq!(script.calls(), 3);

    let script = Arc::new(Script::default());
    for _ in 0..3 {
        script.push(Answer::Fails(unavailable()));
    }
    let (said, out) = run(&script).await;
    assert!(said.is_empty());
    assert!(out.unwrap_err().contains("503"));
    assert_eq!(script.calls(), 3, "the first try and two retries");
}

#[tokio::test(start_paused = true)]
async fn not_retried_once_something_is_said() {
    let script = Arc::new(Script::default());
    script.push(Answer::Breaks(vec!["第一段\n\n".into(), "第二".into()]));
    script.push(Answer::says("不该有这次"));
    let (said, out) = run(&script).await;
    assert_eq!(said, ["第一段"]);
    assert!(out.is_err());
    assert_eq!(script.calls(), 1);

    let script = Arc::new(Script::default());
    script.push(Answer::Fails(max_llm::Error::Status {
        status: 400,
        body: "bad request".into(),
    }));
    let (_, out) = run(&script).await;
    assert!(out.is_err());
    assert_eq!(script.calls(), 1, "a 400 isn't retried");
}

#[tokio::test(start_paused = true)]
async fn an_aborted_call_still_ends() {
    let script = Arc::new(Script::default());
    script.push(Answer::Hangs);
    let chosen = models(&script).turn(None, None).unwrap();
    let (tx, mut rx) = mpsc::unbounded_channel();
    let task = call(chosen.clone(), request(&chosen), TaskId(7), tx);
    let cut = tokio::time::timeout(Duration::from_secs(60), task).await;
    assert!(cut.is_err());
    let Ok(Event::ModelDone { task, out }) = rx.try_recv() else {
        panic!("no ModelDone");
    };
    assert_eq!(task, TaskId(7));
    assert!(out.is_err());
}

#[test]
fn backing_off() {
    let waits: Vec<u64> = (0..6).map(|n| backoff(n).as_secs()).collect();
    assert_eq!(waits, [1, 2, 4, 8, 8, 8]);
}
