use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, BufReader, DuplexStream, Lines};
use tokio::sync::mpsc::{UnboundedSender, unbounded_channel};
use tokio::time::Instant;

use super::*;

/// pi's side of a job: what the driver asks, what pi says.
struct Fake {
    asked: Lines<BufReader<DuplexStream>>,
    says: UnboundedSender<Vec<u8>>,
}

impl Fake {
    /// The next command; null once stdin is closed.
    async fn asked(&mut self) -> Value {
        match self.asked.next_line().await.unwrap() {
            Some(line) => serde_json::from_str(&line).unwrap(),
            None => Value::Null,
        }
    }

    fn say(&self, record: Value) {
        let _ = self.says.send(record.to_string().into_bytes());
    }

    fn answer(&self, command: &Value, data: Value) {
        self.say(json!({
            "id": command["id"], "type": "response", "command": command["type"],
            "success": true, "data": data,
        }));
    }

    /// Takes the steering mode and the prompt: the prompt.
    async fn started(&mut self) -> Value {
        let mode = self.asked().await;
        assert_eq!(mode["type"], "set_steering_mode");
        assert_eq!(mode["mode"], "all");
        self.answer(&mode, Value::Null);
        let prompt = self.asked().await;
        assert_eq!(prompt["type"], "prompt");
        self.answer(&prompt, json!({ "disposition": "started" }));
        prompt
    }

    fn called(&self, input: u32, error: Option<&str>) {
        let stop = if error.is_some() { "error" } else { "stop" };
        self.say(json!({ "type": "message_end", "message": {
            "role": "assistant", "content": [], "stopReason": stop, "errorMessage": error,
            "usage": { "input": input, "output": 10, "cacheRead": 0, "cacheWrite": 0, "reasoning": 0 },
        }}));
    }

    /// Settles, and answers for the last text with `text`.
    async fn settle(&mut self, aborted: bool, text: Option<&str>) {
        self.say(json!({ "type": "agent_settled", "aborted": aborted }));
        let asked = self.asked().await;
        assert_eq!(asked["type"], "get_last_assistant_text");
        self.answer(&asked, json!({ "text": text }));
        assert_eq!(self.asked().await, Value::Null, "stdin is closed");
    }
}

#[derive(Default)]
struct Seen {
    calls: Vec<Usage>,
    tools: Vec<String>,
}

impl Watch for Seen {
    async fn called(&mut self, usage: Usage) {
        self.calls.push(usage);
    }

    fn tool(&mut self, name: &str) {
        self.tools.push(name.to_owned());
    }
}

/// A job of `task` against the fake that `pi` plays, with `steers`.
async fn job<F>(
    task: &str,
    within: Duration,
    steers: Vec<String>,
    pi: impl FnOnce(Fake) -> F,
) -> (Ending, Seen)
where
    F: Future<Output = ()>,
{
    let (input, theirs) = tokio::io::duplex(1 << 16);
    let (says, mut records) = unbounded_channel();
    let (steering, mut steered) = unbounded_channel();
    for steer in steers {
        steering.send(steer).unwrap();
    }
    let fake = Fake {
        asked: BufReader::new(theirs).lines(),
        says,
    };
    let mut seen = Seen::default();
    let deadline = Instant::now() + within;
    let driven = drive(input, &mut records, &mut steered, task, deadline, &mut seen);
    let (ending, ()) = tokio::join!(driven, pi(fake));
    (ending, seen)
}

const LONG: Duration = Duration::from_secs(60);

#[tokio::test]
async fn a_job_reports_its_last_text() {
    let (ending, seen) = job("查一下", LONG, vec![], |mut pi| async move {
        let prompt = pi.started().await;
        assert_eq!(prompt["message"], "查一下");
        pi.called(100, None);
        pi.say(json!({ "type": "tool_execution_start", "toolName": "bash", "args": {} }));
        pi.called(200, None);
        pi.settle(false, Some("查到了")).await;
    })
    .await;
    assert_eq!(
        ending,
        Ending {
            how: How::Done,
            text: Some("查到了".into())
        }
    );
    let inputs: Vec<u32> = seen.calls.iter().map(|usage| usage.input).collect();
    assert_eq!(inputs, [100, 200]);
    assert_eq!(seen.tools, ["bash"]);
}

#[tokio::test]
async fn a_dialog_is_dismissed() {
    let (ending, _) = job("查一下", LONG, vec![], |mut pi| async move {
        pi.started().await;
        pi.say(json!({ "type": "extension_ui_request", "id": "d-1", "method": "confirm" }));
        let answer = pi.asked().await;
        assert_eq!(answer["type"], "extension_ui_response");
        assert_eq!(answer["id"], "d-1");
        assert_eq!(answer["cancelled"], true);
        pi.settle(false, Some("好了")).await;
    })
    .await;
    assert_eq!(ending.how, How::Done);
}

#[tokio::test]
async fn steers_go_on_to_pi() {
    let steers = vec!["顺便看看日志".to_owned()];
    let (ending, _) = job("查一下", LONG, steers, |mut pi| async move {
        pi.started().await;
        let steer = pi.asked().await;
        assert_eq!(steer["type"], "steer");
        assert_eq!(steer["message"], "顺便看看日志");
        pi.called(100, None);
        pi.settle(false, Some("都看了")).await;
    })
    .await;
    assert_eq!(ending.how, How::Done);
}

#[tokio::test]
async fn a_job_out_of_time_is_aborted_and_says_how_far_it_got() {
    let within = Duration::from_millis(100);
    let (ending, _) = job("查一下", within, vec![], |mut pi| async move {
        pi.started().await;
        let clear = pi.asked().await;
        assert_eq!(clear["type"], "clear_queue");
        let abort = pi.asked().await;
        assert_eq!(abort["type"], "abort");
        pi.settle(true, Some("做了一半")).await;
    })
    .await;
    assert_eq!(
        ending,
        Ending {
            how: How::OutOfTime,
            text: Some("做了一半".into())
        }
    );
}

#[tokio::test]
async fn a_failed_model_call_fails_the_job_unless_a_retry_got_through() {
    let (ending, _) = job("查一下", LONG, vec![], |mut pi| async move {
        pi.started().await;
        pi.called(0, Some("429 Resource exhausted"));
        pi.settle(false, None).await;
    })
    .await;
    assert_eq!(
        ending,
        Ending {
            how: How::Failed("429 Resource exhausted".into()),
            text: None
        }
    );

    let (ending, _) = job("查一下", LONG, vec![], |mut pi| async move {
        pi.started().await;
        pi.called(0, Some("429 Resource exhausted"));
        pi.called(100, None);
        pi.settle(false, Some("好了")).await;
    })
    .await;
    assert_eq!(ending.how, How::Done);
}

#[tokio::test]
async fn a_refused_prompt_fails_the_job() {
    let (ending, _) = job("查一下", LONG, vec![], |mut pi| async move {
        let mode = pi.asked().await;
        pi.answer(&mode, Value::Null);
        let prompt = pi.asked().await;
        pi.say(json!({
            "id": prompt["id"], "type": "response", "command": "prompt",
            "success": false, "error": "No API key",
        }));
    })
    .await;
    assert_eq!(ending.how, How::Failed("No API key".into()));
}

#[tokio::test]
async fn pi_gone_fails_the_job() {
    let (ending, _) = job("查一下", LONG, vec![], |mut pi| async move {
        pi.started().await;
        drop(pi);
    })
    .await;
    assert_eq!(ending.how, How::Failed(GONE.into()));
}
