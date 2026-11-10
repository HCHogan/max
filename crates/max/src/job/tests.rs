use std::time::Duration;

use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel};
use tokio::sync::oneshot;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

use super::*;
use max_core::limits::JOB_TIME;

/// The harness's side of a job, as its plugin calls; and Max's, the
/// questions the driver passes on and the steers.
struct Fake {
    hooks: UnboundedSender<Hook>,
    exit: Option<oneshot::Sender<Exit>>,
    stop: CancellationToken,
    told: UnboundedReceiver<String>,
    steering: UnboundedSender<String>,
}

impl Fake {
    /// A turn has ended: what it is told.
    async fn turn(&self) -> Turn {
        let (reply, replied) = oneshot::channel();
        self.hooks.send(Hook::Turn(reply)).unwrap();
        replied.await.unwrap()
    }

    /// The steers a turn's end takes.
    async fn steers(&self) -> Vec<String> {
        let turn = self.turn().await;
        assert!(!turn.stop);
        turn.steers
    }

    /// ask_max's question, as `/job/ask` hands it on: where the answer
    /// comes.
    fn put(&self, question: &str) -> oneshot::Receiver<Option<String>> {
        let (answer, answered) = oneshot::channel();
        let text = question.to_owned();
        self.hooks
            .send(Hook::Ask(Question { text, answer }))
            .unwrap();
        answered
    }

    /// The same, once the driver has passed it on to Max.
    async fn ask(&mut self, question: &str) -> oneshot::Receiver<Option<String>> {
        let answered = self.put(question);
        assert_eq!(self.told.recv().await.unwrap(), question);
        answered
    }

    fn steer(&self, steer: &str) {
        self.steering.send(steer.to_owned()).unwrap();
    }

    fn report(&self, text: Option<&str>, error: Option<&str>) {
        let report = Report {
            text: text.map(str::to_owned),
            error: error.map(str::to_owned),
        };
        self.hooks.send(Hook::Report(report)).unwrap();
    }

    /// The harness's process ends.
    fn exit(&mut self, status: Option<u32>, out: &str, err: &str) {
        let exit = Exit {
            status,
            out: out.to_owned(),
            err: err.to_owned(),
        };
        self.exit.take().unwrap().send(exit).unwrap();
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

/// A job against the fake harness `agent` plays.
async fn job<F>(within: Duration, agent: impl FnOnce(Fake) -> F) -> Ending
where
    F: Future<Output = ()>,
{
    let (hooks, mut hooked) = unbounded_channel();
    let (exit, mut exited) = oneshot::channel();
    let (steering, mut steered) = unbounded_channel();
    let (telling, told) = unbounded_channel();
    let stop = CancellationToken::new();
    let fake = Fake {
        hooks,
        exit: Some(exit),
        stop: stop.clone(),
        told,
        steering,
    };
    let mut seen = Seen { questions: telling };
    let deadline = Instant::now() + within;
    let driven = drive(
        &mut hooked,
        &mut steered,
        &mut exited,
        &stop,
        deadline,
        &mut seen,
    );
    let (ending, ()) = tokio::join!(driven, agent(fake));
    ending
}

const LONG: Duration = Duration::from_secs(60);

fn done(text: &str) -> Ending {
    Ending {
        how: How::Done,
        text: Some(text.to_owned()),
        unsent: 0,
    }
}

#[tokio::test]
async fn a_job_ends_with_its_report() {
    let ending = job(LONG, |agent| async move {
        assert_eq!(agent.turn().await, Turn::default());
        agent.report(Some("查到了"), None);
    })
    .await;
    assert_eq!(ending, done("查到了"));
}

#[tokio::test]
async fn steers_wait_for_a_turns_end_and_come_in_order() {
    let ending = job(LONG, |agent| async move {
        agent.steer("先看 A");
        agent.steer("再看 B");
        assert_eq!(agent.steers().await, ["先看 A", "再看 B"]);
        assert!(agent.steers().await.is_empty());
        // A turn's end that went before its answer took none.
        agent.steer("还有 C");
        let (reply, replied) = oneshot::channel();
        agent.hooks.send(Hook::Turn(reply)).unwrap();
        drop(replied);
        assert_eq!(agent.steers().await, ["还有 C"]);
        agent.report(Some("看完了"), None);
    })
    .await;
    assert_eq!(ending, done("看完了"));
}

#[tokio::test]
async fn steers_left_when_the_agent_reports_are_counted() {
    let ending = job(LONG, |agent| async move {
        agent.steer("再查一个");
        agent.report(Some("好了"), None);
        agent.steer("还有一个");
    })
    .await;
    assert_eq!(ending.text.as_deref(), Some("好了"));
    assert_eq!(ending.unsent, 2);
}

#[tokio::test]
async fn a_question_goes_to_max_and_the_next_steer_answers_it() {
    let ending = job(LONG, |mut agent| async move {
        let answer = agent.ask("选火锅还是烧烤？").await;
        agent.steer("火锅");
        assert_eq!(answer.await.unwrap(), Some("火锅".into()));
        // Answered: the next is a steer again.
        agent.steer("要包间");
        assert_eq!(agent.steers().await, ["要包间"]);
        agent.report(Some("订了火锅包间"), None);
    })
    .await;
    assert_eq!(ending, done("订了火锅包间"));
}

#[tokio::test]
async fn one_question_at_a_time_and_one_withdrawn_takes_no_answer() {
    let ending = job(LONG, |mut agent| async move {
        let first = agent.ask("选火锅还是烧烤？").await;
        assert_eq!(agent.put("几个人？").await.unwrap(), None);
        // The agent aborted ask_max: what Max says next is a steer.
        drop(first);
        agent.steer("火锅");
        assert_eq!(agent.steers().await, ["火锅"]);
        agent.report(Some("订了火锅"), None);
    })
    .await;
    assert_eq!(ending.how, How::Done);
}

#[tokio::test(start_paused = true)]
async fn an_unanswered_question_is_given_up_on_after_a_while() {
    let ending = job(JOB_TIME, |mut agent| async move {
        let asked = Instant::now();
        let answer = agent.ask("选火锅还是烧烤？").await;
        assert_eq!(answer.await.unwrap(), None);
        assert_eq!(asked.elapsed(), QUESTION_WAIT);
        agent.report(Some("自己选了火锅"), None);
    })
    .await;
    assert_eq!(ending.how, How::Done);
}

#[tokio::test(start_paused = true)]
async fn a_job_is_told_to_wrap_up_before_its_time_is_up() {
    let ending = job(JOB_TIME, |agent| async move {
        // tokio::join! may poll this before the driver.
        tokio::time::sleep(JOB_TIME - WARNING + Duration::from_secs(1)).await;
        assert_eq!(agent.steers().await, [wrap_up_message()]);
        agent.report(Some("查到一半，先报这些"), None);
    })
    .await;
    assert_eq!(ending.how, How::Done);
}

#[tokio::test(start_paused = true)]
async fn a_wrap_up_not_taken_in_isnt_counted_as_maxs() {
    let ending = job(JOB_TIME, |agent| async move {
        agent.steer("再查一个");
        tokio::time::sleep(JOB_TIME - WARNING + Duration::from_secs(1)).await;
        agent.report(Some("先报这些"), None);
    })
    .await;
    assert_eq!(ending.unsent, 1);
}

#[tokio::test(start_paused = true)]
async fn a_job_waiting_on_max_is_still_told_to_wrap_up() {
    let within = WARNING + Duration::from_secs(60);
    let ending = job(within, |mut agent| async move {
        let answer = agent.ask("选火锅还是烧烤？").await;
        assert_eq!(answer.await.unwrap(), None);
        assert_eq!(agent.steers().await, [wrap_up_message()]);
        agent.report(Some("没等到，先报这些"), None);
    })
    .await;
    assert_eq!(ending.how, How::Done);
}

#[tokio::test(start_paused = true)]
async fn a_job_out_of_time_is_stopped_and_says_how_far_it_got() {
    let within = Duration::from_millis(100);
    let ending = job(within, |mut agent| async move {
        let answer = agent.ask("选火锅还是烧烤？").await;
        agent.stop.cancelled().await;
        assert_eq!(answer.await.unwrap(), None);
        // Queued steers are dropped; later ones and questions aren't taken.
        agent.steer("太晚了");
        assert_eq!(agent.put("几个人？").await.unwrap(), None);
        let turn = agent.turn().await;
        assert!(turn.stop && turn.steers.is_empty(), "{turn:?}");
        agent.report(Some("做了一半"), Some("The operation was aborted."));
    })
    .await;
    assert_eq!(
        ending,
        Ending {
            how: How::OutOfTime,
            text: Some("做了一半".into()),
            unsent: 1,
        }
    );
}

#[tokio::test(start_paused = true)]
async fn a_job_that_doesnt_stop_is_given_up_on() {
    let within = Duration::from_millis(100);
    let ending = job(within, |agent| async move {
        agent.stop.cancelled().await;
        // Neither reporting nor ending: the harness, all of it, is still
        // there.
        tokio::time::sleep(GRACE * 2).await;
        drop(agent);
    })
    .await;
    assert_eq!(
        ending,
        Ending {
            how: How::OutOfTime,
            text: None,
            unsent: 0,
        }
    );
}

#[tokio::test]
async fn a_failed_model_call_fails_the_job() {
    let ending = job(LONG, |agent| async move {
        agent.report(None, Some("429 Resource exhausted"));
    })
    .await;
    assert_eq!(
        ending,
        Ending {
            how: How::Failed("429 Resource exhausted".into()),
            text: None,
            unsent: 0,
        }
    );
}

#[tokio::test]
async fn a_harness_with_no_plugin_reports_what_it_wrote() {
    let ending = job(LONG, |mut agent| async move {
        agent.exit(Some(0), "\n查到了\n", "");
    })
    .await;
    assert_eq!(ending, done("查到了"));

    let ending = job(LONG, |mut agent| async move {
        agent.exit(Some(1), "", "loading…\nError: No API key\n\n");
    })
    .await;
    assert_eq!(
        ending.how,
        How::Failed("the agent exited with status 1: Error: No API key".into())
    );

    let ending = job(LONG, |mut agent| async move {
        agent.exit(None, "", "");
    })
    .await;
    assert_eq!(
        ending.how,
        How::Failed("the agent exited unexpectedly".into())
    );
}

#[tokio::test]
async fn a_report_goes_before_the_end_that_follows_it() {
    let ending = job(LONG, |mut agent| async move {
        agent.report(None, Some("模型调用失败"));
        agent.exit(Some(1), "", "Request error");
    })
    .await;
    assert_eq!(ending.how, How::Failed("模型调用失败".into()));
}
