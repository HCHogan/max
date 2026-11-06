use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, BufReader, DuplexStream, Lines};
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel};
use tokio::sync::oneshot;
use tokio::time::Instant;

use super::*;
use max_core::limits::JOB_TIME;

/// pi's side of a job: what the driver asks, what pi says, and ask_max's
/// questions; and Max's, the questions the driver passes on and the
/// steers that answer them.
struct Fake {
    asked: Lines<BufReader<DuplexStream>>,
    says: UnboundedSender<Vec<u8>>,
    asking: UnboundedSender<Question>,
    told: UnboundedReceiver<String>,
    steering: UnboundedSender<String>,
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

    /// ask_max's question, as `/job/ask` hands it on: where the answer
    /// comes.
    fn put(&self, question: &str) -> oneshot::Receiver<Option<String>> {
        let (answer, answered) = oneshot::channel();
        let text = question.to_owned();
        self.asking.send(Question { text, answer }).unwrap();
        answered
    }

    /// The same, once the driver has passed it on to Max.
    async fn ask(&mut self, question: &str) -> oneshot::Receiver<Option<String>> {
        let answered = self.put(question);
        assert_eq!(self.told.recv().await.unwrap(), question);
        answered
    }

    fn called(&self, error: Option<&str>) {
        let stop = if error.is_some() { "error" } else { "stop" };
        self.say(json!({ "type": "message_end", "message": {
            "role": "assistant", "content": [], "stopReason": stop, "errorMessage": error,
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

/// Max's side: the questions the driver passes on.
struct Seen {
    questions: UnboundedSender<String>,
}

impl Watch for Seen {
    fn asks(&mut self, question: &str) {
        let _ = self.questions.send(question.to_owned());
    }
}

/// A job of `task` against the fake that `pi` plays.
async fn job<F>(task: &str, within: Duration, pi: impl FnOnce(Fake) -> F) -> Ending
where
    F: Future<Output = ()>,
{
    let (input, theirs) = tokio::io::duplex(1 << 16);
    let (says, mut records) = unbounded_channel();
    let (steering, mut steered) = unbounded_channel();
    let (asking, mut questions) = unbounded_channel();
    let (telling, told) = unbounded_channel();
    let fake = Fake {
        asked: BufReader::new(theirs).lines(),
        says,
        asking,
        told,
        steering,
    };
    let mut seen = Seen { questions: telling };
    let deadline = Instant::now() + within;
    let driven = drive(
        input,
        &mut records,
        &mut steered,
        &mut questions,
        task,
        deadline,
        &mut seen,
    );
    let (ending, ()) = tokio::join!(driven, pi(fake));
    ending
}

const LONG: Duration = Duration::from_secs(60);

#[tokio::test]
async fn a_job_reports_its_last_text() {
    let ending = job("查一下", LONG, |mut pi| async move {
        let prompt = pi.started().await;
        assert_eq!(prompt["message"], "查一下");
        pi.called(None);
        pi.called(None);
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
}

#[tokio::test]
async fn a_dialog_is_dismissed() {
    let ending = job("查一下", LONG, |mut pi| async move {
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
async fn a_question_goes_to_max_and_the_next_steer_answers_it() {
    let ending = job("订餐厅", LONG, |mut pi| async move {
        pi.started().await;
        let answer = pi.ask("选火锅还是烧烤？").await;
        pi.steering.send("火锅".into()).unwrap();
        assert_eq!(answer.await.unwrap(), Some("火锅".into()));
        // Answered: the next is a steer again.
        pi.steering.send("要包间".into()).unwrap();
        let steer = pi.asked().await;
        assert_eq!(steer["type"], "steer");
        assert_eq!(steer["message"], "要包间");
        pi.settle(false, Some("订了火锅包间")).await;
    })
    .await;
    assert_eq!(ending.how, How::Done);
}

#[tokio::test]
async fn one_question_at_a_time_and_one_withdrawn_takes_no_answer() {
    let ending = job("订餐厅", LONG, |mut pi| async move {
        pi.started().await;
        let first = pi.ask("选火锅还是烧烤？").await;
        assert_eq!(pi.put("几个人？").await.unwrap(), None);
        // pi aborted ask_max: what Max says next is a steer.
        drop(first);
        pi.steering.send("火锅".into()).unwrap();
        let steer = pi.asked().await;
        assert_eq!(steer["type"], "steer");
        assert_eq!(steer["message"], "火锅");
        pi.settle(false, Some("订了火锅")).await;
    })
    .await;
    assert_eq!(ending.how, How::Done);
}

#[tokio::test(start_paused = true)]
async fn an_unanswered_question_is_given_up_on_after_a_while() {
    let ending = job("订餐厅", JOB_TIME, |mut pi| async move {
        pi.started().await;
        let asked = Instant::now();
        let answer = pi.ask("选火锅还是烧烤？").await;
        assert_eq!(answer.await.unwrap(), None);
        assert_eq!(asked.elapsed(), QUESTION_WAIT);
        pi.settle(false, Some("自己选了火锅")).await;
    })
    .await;
    assert_eq!(ending.how, How::Done);
}

#[tokio::test(start_paused = true)]
async fn a_job_waiting_on_max_is_still_told_to_wrap_up() {
    let within = WARNING + Duration::from_secs(60);
    let ending = job("订餐厅", within, |mut pi| async move {
        pi.started().await;
        let answer = pi.ask("选火锅还是烧烤？").await;
        assert_eq!(answer.await.unwrap(), None);
        let steer = pi.asked().await;
        assert_eq!(steer["message"], wrap_up_message());
        pi.settle(false, Some("没等到，先报这些")).await;
    })
    .await;
    assert_eq!(ending.how, How::Done);
}

#[tokio::test]
async fn a_job_out_of_time_is_aborted_and_says_how_far_it_got() {
    let within = Duration::from_millis(100);
    let ending = job("查一下", within, |mut pi| async move {
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

#[tokio::test(start_paused = true)]
async fn a_job_is_told_to_wrap_up_before_its_time_is_up() {
    let ending = job("查一下", JOB_TIME, |mut pi| async move {
        pi.started().await;
        let told = Instant::now();
        let steer = pi.asked().await;
        assert_eq!(steer["type"], "steer");
        assert_eq!(steer["message"], wrap_up_message());
        assert_eq!(told.elapsed(), JOB_TIME - WARNING);
        pi.called(None);
        pi.settle(false, Some("查到一半，先报这些")).await;
    })
    .await;
    assert_eq!(ending.how, How::Done);
}

#[tokio::test]
async fn a_failed_model_call_fails_the_job_unless_a_retry_got_through() {
    let ending = job("查一下", LONG, |mut pi| async move {
        pi.started().await;
        pi.called(Some("429 Resource exhausted"));
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

    let ending = job("查一下", LONG, |mut pi| async move {
        pi.started().await;
        pi.called(Some("429 Resource exhausted"));
        pi.called(None);
        pi.settle(false, Some("好了")).await;
    })
    .await;
    assert_eq!(ending.how, How::Done);
}

#[tokio::test]
async fn a_refused_prompt_fails_the_job() {
    let ending = job("查一下", LONG, |mut pi| async move {
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
    let ending = job("查一下", LONG, |mut pi| async move {
        pi.started().await;
        drop(pi);
    })
    .await;
    assert_eq!(ending.how, How::Failed(GONE.into()));
}
