//! The actor against the real database, a scripted model and a sender
//! that only records. Time is real: a paused clock would jump ahead while
//! the actor waits on Postgres. Waits are short and bounded.

use std::time::Duration;

use max_core::item::ItemKind;
use max_core::message::{Content, Node};
use max_core::run::Outcome;
use max_db::{PgPool, summaries};
use tokio::sync::{mpsc, oneshot};

use serde_json::json;

use super::*;
use crate::command;
use crate::conversation::testing::{from_xiaohong, from_xiaoming, group, shared, text};
use crate::historian::Captured;
use crate::inbound::InNode;
use crate::job::{Ending, Finished, How, Request};
use crate::llm::testing::{Answer, Script};

const PATIENCE: Duration = Duration::from_secs(5);

struct Harness {
    pool: PgPool,
    script: Arc<Script>,
    mailbox: UnboundedSender<Event>,
    outbound: UnboundedReceiver<Outgoing>,
    /// What the historian hears.
    notices: UnboundedReceiver<Notice>,
    done: Option<oneshot::Receiver<()>>,
    _scope: Scope,
}

impl Harness {
    async fn new(pool: PgPool, idle_window_secs: u64) -> Self {
        Self::with_owner(pool, idle_window_secs, false).await
    }

    /// With 小明 as Max's owner, if `xiaoming_owns`.
    async fn with_owner(pool: PgPool, idle_window_secs: u64, xiaoming_owns: bool) -> Self {
        Self::start(pool, idle_window_secs, xiaoming_owns, true, |_| {}).await
    }

    /// Without proactive replies: chatter starts no classifier call that
    /// races the core's calls for the script's answers.
    async fn unprompted(pool: PgPool, idle_window_secs: u64) -> Self {
        Self::start(pool, idle_window_secs, false, false, |_| {}).await
    }

    /// With job#1, titled `title`, running as far as the actor knows:
    /// where its steers go.
    async fn with_job(pool: PgPool, title: &str) -> (Self, UnboundedReceiver<String>) {
        let mut steered = None;
        let h = Self::start(pool, 300, true, false, |actor| {
            steered = Some(actor.jobs.pretend(title));
        })
        .await;
        (h, steered.unwrap())
    }

    async fn start(
        pool: PgPool,
        idle_window_secs: u64,
        xiaoming_owns: bool,
        proactive: bool,
        prepare: impl FnOnce(&mut Conversation),
    ) -> Self {
        let mut conn = pool.acquire().await.unwrap();
        let place = Arc::new(group(&mut conn).await);
        if !proactive {
            let settings = Settings {
                proactive,
                ..Settings::default()
            };
            platform::save_settings(&mut conn, place.conversation, &settings, Utc::now())
                .await
                .unwrap();
        }
        let xiaoming = platform::account(&mut conn, place.platform, "XIAOMING", "小明")
            .await
            .unwrap();
        drop(conn);
        let mut owners = BTreeSet::new();
        if xiaoming_owns {
            owners.insert(xiaoming.principal);
        }
        let script = Arc::new(Script::default());
        let (mut shared, outbound) = shared(&pool, &script, idle_window_secs, owners);
        let (historian, notices) = shared.rows.subscribe();
        shared.historian = Some(historian);
        let mut scope = Scope::new();
        let (mailbox, rx) = mpsc::unbounded_channel();
        let mut actor = Conversation::new(Arc::new(shared), place, mailbox.clone())
            .await
            .unwrap();
        prepare(&mut actor);
        let (done_tx, done) = oneshot::channel();
        scope.spawn(move |_| async move {
            actor.run(rx).await.unwrap();
            let _ = done_tx.send(());
        });
        Self {
            pool,
            script,
            mailbox,
            outbound,
            notices,
            done: Some(done),
            _scope: scope,
        }
    }

    fn send(&self, inbound: Inbound) {
        self.mailbox.send(Event::Inbound(inbound)).unwrap();
    }

    /// The next message Max sends, and its text.
    async fn said(&mut self) -> (Message, String) {
        let outgoing = tokio::time::timeout(PATIENCE, self.outbound.recv())
            .await
            .expect("Max said nothing")
            .unwrap();
        let Content::Message { nodes, .. } = &outgoing.message.content else {
            panic!("{:?}", outgoing.message);
        };
        let text = nodes
            .iter()
            .map(|node| match node {
                Node::Text { text } => text.clone(),
                other => format!("{other:?}"),
            })
            .collect();
        (outgoing.message, text)
    }

    async fn stop(&mut self) {
        self.mailbox.send(Event::Stop).unwrap();
        let done = self.done.take().unwrap();
        tokio::time::timeout(PATIENCE, done)
            .await
            .expect("the actor didn't stop")
            .unwrap();
    }

    async fn turns(&self) -> Vec<(TurnId, Option<Outcome>)> {
        let mut conn = self.pool.acquire().await.unwrap();
        let ids: Vec<i64> = sqlx::query_scalar("select id from turns order by id")
            .fetch_all(&mut *conn)
            .await
            .unwrap();
        let mut out = Vec::new();
        for id in ids {
            let turn = TurnId(id);
            out.push((turn, turns::outcome(&mut conn, turn).await.unwrap()));
        }
        out
    }

    async fn count(&self, query: &'static str) -> i64 {
        let mut conn = self.pool.acquire().await.unwrap();
        sqlx::query_scalar(query)
            .fetch_one(&mut *conn)
            .await
            .unwrap()
    }

    /// The last item of the n-th request: what was new to the model.
    fn request_tail(&self, n: usize) -> String {
        let requests = self.script.requests.lock().unwrap();
        match &requests[n].items.last().unwrap().kind {
            ItemKind::User { text, .. } => text.clone(),
            other => panic!("{other:?}"),
        }
    }
}

/// An @ of Max, which a command in a group needs.
fn me() -> InNode {
    InNode::MentionMe {
        display: "maxx".into(),
    }
}

fn at_max(n: u32, said: &str) -> Inbound {
    from_xiaoming(n, vec![me(), text(said)])
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn an_at_wakes_a_core_that_answers(pool: PgPool) {
    let mut h = Harness::new(pool, 300).await;
    h.script
        .push(Answer::Says(vec!["在的\n\n".into(), "说吧".into()]));
    h.send(at_max(0, " 在吗"));
    assert_eq!(h.said().await.1, "在的");
    let (second, text) = h.said().await;
    assert_eq!(text, "说吧");
    let tail = h.request_tail(0);
    assert!(
        tail.contains("[新消息]") && tail.contains("@你]:"),
        "{tail}"
    );
    h.stop().await;

    let turns = h.turns().await;
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].1, Some(Outcome::Answered));
    assert_eq!(second.turn, Some(turns[0].0));
    let calls = h
        .count("select count(*) from llm_usage where purpose = 'turn'")
        .await;
    assert_eq!(calls, 1);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_tool_result_comes_back_to_the_model(pool: PgPool) {
    let mut h = Harness::new(pool, 300).await;
    h.script.push(Answer::Calls(
        "shell".into(),
        r#"{"command": "uname -a"}"#.into(),
    ));
    h.script.push(Answer::says("这里没有 VM"));
    h.send(at_max(0, " 跑一下 uname"));
    assert_eq!(h.said().await.1, "这里没有 VM");
    h.stop().await;
    let second = h.script.requests.lock().unwrap()[1].items.clone();
    let result = second
        .iter()
        .find_map(|item| match &item.kind {
            ItemKind::ToolResult { output, .. } => Some(output.clone()),
            _ => None,
        })
        .expect("the tool's result");
    assert!(result.error, "{result:?}");
    let turns = h.turns().await;
    assert_eq!(turns[0].1, Some(Outcome::Answered));
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn chatter_alone_wakes_nobody(pool: PgPool) {
    let mut h = Harness::new(pool, 300).await;
    let verdict = r#"{"trigger": false, "reason": "闲聊"}"#;
    h.script.push(Answer::says(verdict));
    h.script.push(Answer::says(verdict));
    h.send(from_xiaoming(0, vec![text("今天好热")]));
    h.send(from_xiaoming(0, vec![text("今天好热")]));
    h.send(from_xiaohong(1, vec![text("是啊")]));
    // The classifier says no to the first, then to what came meanwhile.
    let deadline = Instant::now() + PATIENCE;
    while h.script.calls() < 2 {
        assert!(Instant::now() < deadline, "too few classifier calls");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    h.stop().await;
    assert_eq!(h.script.calls(), 2);
    assert!(h.turns().await.is_empty());
    assert_eq!(h.count("select count(*) from messages").await, 2);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn later_rows_reach_the_running_core(pool: PgPool) {
    let mut h = Harness::unprompted(pool, 300).await;
    h.script.push(Answer::says("嗯"));
    h.script.push(Answer::says("看到了"));
    h.send(at_max(0, " 第一句"));
    assert_eq!(h.said().await.1, "嗯");
    h.send(from_xiaohong(1, vec![text("插一句")]));
    h.send(at_max(2, " 第二句"));
    assert_eq!(h.said().await.1, "看到了");
    let tail = h.request_tail(1);
    assert!(tail.starts_with("[新消息]\n[上下文里的人] "), "{tail}");
    assert!(tail.contains("小红（管理员）"), "{tail}");
    assert!(tail.contains("小红 #"), "{tail}");
    assert!(tail.contains("插一句\n[12:02 小明 #"), "{tail}");
    assert!(tail.ends_with(" 第二句"), "{tail}");
    h.stop().await;
    assert_eq!(h.turns().await.len(), 1, "one core took both");
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_failed_call_says_so(pool: PgPool) {
    let mut h = Harness::new(pool, 300).await;
    h.script.push(Answer::Fails(max_llm::Error::Status {
        status: 400,
        body: "nope".into(),
    }));
    h.send(at_max(0, " 在吗"));
    let (message, text) = h.said().await;
    assert_eq!(text, "出错了，这条没回上。");
    let Content::Message { reply_to, .. } = message.content else {
        unreachable!()
    };
    assert!(reply_to.is_some());
    assert_eq!(message.turn, None);
    h.stop().await;
    let turns = h.turns().await;
    assert!(matches!(
        &turns[0].1,
        Some(Outcome::Failed {
            reason: FailReason::Model { .. }
        })
    ));
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn an_idle_core_ends_on_its_own(pool: PgPool) {
    let mut h = Harness::new(pool, 1).await;
    h.script.push(Answer::says("好"));
    h.send(at_max(0, " 在吗"));
    h.said().await;
    let deadline = Instant::now() + PATIENCE;
    while h.turns().await[0].1.is_none() {
        assert!(Instant::now() < deadline, "the core didn't end");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert_eq!(h.turns().await[0].1, Some(Outcome::Answered));
    h.stop().await;
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn stopping_interrupts_a_call_that_outlasts_the_grace(pool: PgPool) {
    let mut h = Harness::new(pool, 300).await;
    h.script.push(Answer::Hangs);
    h.send(at_max(0, " 在吗"));
    let deadline = Instant::now() + PATIENCE;
    while h.script.calls() == 0 {
        assert!(Instant::now() < deadline, "no model call");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    h.stop().await;
    assert_eq!(h.turns().await[0].1, Some(Outcome::Interrupted));
    assert_eq!(h.count("select count(*) from turn_snapshots").await, 1);
    let (_, said) = h.said().await;
    assert_eq!(said, "我要重启一下，这条没回上，等会儿再问一次吧。");
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_judged_wake_starts_a_core(pool: PgPool) {
    let mut h = Harness::new(pool, 300).await;
    let verdict = r#"{"trigger": true, "reason": "在叫 Max"}"#;
    h.script.push(Answer::says(verdict));
    h.script.push(Answer::says("来了"));
    h.send(from_xiaoming(0, vec![text("max 你怎么看")]));
    assert_eq!(h.said().await.1, "来了");
    let volatile = h.request_tail(1);
    assert!(
        volatile.ends_with("max 你怎么看\n[判定：在叫 Max]\n"),
        "{volatile}"
    );
    h.stop().await;
    let intent = h
        .count("select count(*) from llm_usage where purpose = 'intent'")
        .await;
    assert_eq!(intent, 1);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn commands_answer_and_never_wake(pool: PgPool) {
    let mut h = Harness::new(pool, 300).await;
    h.send(from_xiaoming(0, vec![me(), text("/status")]));
    let (answer, status) = h.said().await;
    assert!(
        status.starts_with("```text\n/status → maxx dev\nos        "),
        "{status}"
    );
    assert!(
        status.contains("\nmodel     test/big · high\nproactive on\ncore      idle\nuptime    "),
        "{status}"
    );
    assert!(status.ends_with("\n```"), "{status}");
    let Content::Message { reply_to, .. } = answer.content else {
        unreachable!()
    };
    assert_eq!(reply_to, None, "an answer doesn't quote the command");

    h.send(from_xiaoming(1, vec![me(), text("/model test/small")]));
    assert_eq!(h.said().await.1, command::answer("model", "拒绝：仅限主人"));
    h.send(from_xiaoming(2, vec![me(), text("/clear --all")]));
    assert_eq!(
        h.said().await.1,
        command::answer("clear", "拒绝：仅限群主、管理员")
    );
    // 小红 is an admin.
    h.send(from_xiaohong(3, vec![me(), text("/clear --all")]));
    assert_eq!(
        h.said().await.1,
        command::answer(
            "clear",
            "已清空：之前的消息不再进入上下文，@maxx /unclear 恢复"
        )
    );
    let cleared = h
        .count("select cleared_upto from conversation_settings")
        .await;
    assert!(cleared > 0);

    h.send(from_xiaoming(4, vec![me(), text("/unclear")]));
    assert_eq!(
        h.said().await.1,
        command::answer("unclear", "拒绝：仅限群主、管理员")
    );
    h.send(from_xiaohong(5, vec![me(), text("/unclear")]));
    assert_eq!(
        h.said().await.1,
        command::answer("unclear", "已恢复：清空前的消息回到上下文")
    );
    h.send(from_xiaohong(6, vec![me(), text("/unclear")]));
    assert_eq!(
        h.said().await.1,
        command::answer("unclear", "跳过：没有清空过")
    );
    // Cleared again, and the historian has summed up since.
    h.send(from_xiaohong(7, vec![me(), text("/clear --all")]));
    let (answered, _) = h.said().await;
    let summary = summaries::Summary {
        first: answered.id,
        last: answered.id,
        started_at: answered.at,
        ended_at: answered.at,
        title: "清空以后".into(),
        kind: "chat".into(),
        importance: 10,
        full: "清空以后聊的".into(),
        brief: None,
        line: None,
    };
    let mut conn = h.pool.acquire().await.unwrap();
    let conversation = answered.conversation;
    summaries::insert(&mut conn, conversation, &summary, "m", Utc::now())
        .await
        .unwrap();
    drop(conn);
    h.send(from_xiaohong(8, vec![me(), text("/unclear")]));
    assert_eq!(
        h.said().await.1,
        command::answer(
            "unclear",
            "已恢复：清空前的摘要回到上下文；清空时还没写成摘要的那段不回来，context_search 搜得到"
        )
    );
    h.stop().await;
    assert_eq!(h.script.calls(), 0);
    assert!(h.turns().await.is_empty());
    let cleared = h
        .count("select count(cleared_upto) from conversation_settings")
        .await;
    assert_eq!(cleared, 0);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn compact_is_answered_when_the_historian_is_done(pool: PgPool) {
    let mut h = Harness::new(pool, 300).await;
    h.send(from_xiaoming(0, vec![me(), text("/compact")]));
    assert_eq!(
        h.said().await.1,
        command::answer("compact", "拒绝：仅限群主、管理员")
    );
    h.send(from_xiaohong(1, vec![me(), text("/compact")]));
    let mut said = 0;
    let reply = loop {
        let notice = tokio::time::timeout(PATIENCE, h.notices.recv())
            .await
            .expect("the historian heard nothing")
            .unwrap();
        match notice {
            Notice::Row(_) => said += 1,
            Notice::Compact(compact) => break compact.reply,
        }
    };
    // 小明's command, Max's answer, 小红's command.
    assert_eq!(said, 3);
    reply.send(Ok(Captured::Published(2))).unwrap();
    let (answer, text) = h.said().await;
    assert_eq!(text, command::answer("compact", "已压缩：2 段摘要"));
    let Content::Message { reply_to, .. } = answer.content else {
        unreachable!()
    };
    assert_eq!(reply_to, None);
    h.stop().await;
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn an_owner_changes_settings(pool: PgPool) {
    let mut h = Harness::with_owner(pool, 300, true).await;
    h.send(from_xiaoming(0, vec![me(), text("/model test/nope")]));
    let answer = h.said().await.1;
    assert!(answer.contains("/model → 错误：没有这个模型"), "{answer}");
    h.send(from_xiaoming(1, vec![me(), text("/model test/small")]));
    assert_eq!(
        h.said().await.1,
        command::answer("model", "已切换：test/small，下次回复生效")
    );
    h.send(from_xiaoming(2, vec![me(), text("/proactive off")]));
    assert_eq!(
        h.said().await.1,
        command::answer("proactive", "已关闭主动接话：只在被 @ 或回复时回答")
    );
    h.script.push(Answer::says("嗯"));
    // From 小红: 小明's burst of commands would hold his @ as unfinished.
    let mention = InNode::MentionMe {
        display: "maxx".into(),
    };
    h.send(from_xiaohong(3, vec![mention, text(" 在吗")]));
    h.said().await;
    h.stop().await;
    let model = h.script.requests.lock().unwrap()[0].model.model.clone();
    assert_eq!(model, "small");
    let proactive = h
        .count("select count(*) from conversation_settings where not proactive")
        .await;
    assert_eq!(proactive, 1);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn kill_stops_the_core_quietly(pool: PgPool) {
    let mut h = Harness::new(pool, 300).await;
    h.script.push(Answer::Hangs);
    h.send(at_max(0, " 写篇长文"));
    let deadline = Instant::now() + PATIENCE;
    while h.script.calls() == 0 {
        assert!(Instant::now() < deadline, "no model call");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    h.send(from_xiaohong(1, vec![me(), text("/kill")]));
    let deadline = Instant::now() + PATIENCE;
    while h.turns().await[0].1.is_none() {
        assert!(Instant::now() < deadline, "the core didn't end");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(h.turns().await[0].1, Some(Outcome::Interrupted));
    h.stop().await;
    assert!(h.outbound.try_recv().is_err(), "/kill isn't answered");
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_post_hears_how_its_sending_went(pool: PgPool) {
    let mut h = Harness::unprompted(pool, 300).await;
    let say = |nodes: Vec<DraftNode>| {
        let draft = Draft {
            reply_to: None,
            nodes,
        };
        post(Act::Say(draft))
    };
    let (chart, sent) = say(vec![DraftNode::Text {
        text: "每日活跃".into(),
    }]);
    h.mailbox.send(Event::Post(chart)).unwrap();
    let outgoing = tokio::time::timeout(PATIENCE, h.outbound.recv())
        .await
        .unwrap()
        .unwrap();
    let id = outgoing.message.id;
    // What the sender does once QQ has answered.
    outgoing.receipt.unwrap().send(Ok(id)).unwrap();
    assert_eq!(sent.await.unwrap(), Ok(id));

    // Nothing to send: told at once, and nothing goes to the sender.
    let (empty, sent) = say(Vec::new());
    h.mailbox.send(Event::Post(empty)).unwrap();
    assert!(sent.await.unwrap().is_err());
    h.stop().await;
    assert!(h.outbound.try_recv().is_err());
}

/// A post that waits to hear how it went.
fn post(act: Act) -> (Post, oneshot::Receiver<Result<MessageId, String>>) {
    let (receipt, sent) = oneshot::channel();
    let post = Post {
        act,
        origin: None,
        receipt: Some(receipt),
    };
    (post, sent)
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_post_takes_back_a_message(pool: PgPool) {
    let mut h = Harness::unprompted(pool, 300).await;
    h.send(from_xiaoming(0, vec![text("加群领红包")]));
    // No such message: told at once. By then 小明's is committed.
    let (nothing, refused) = post(Act::Unsend(MessageId(i64::MAX)));
    h.mailbox.send(Event::Post(nothing)).unwrap();
    assert!(refused.await.unwrap().is_err());
    let target = sqlx::query_scalar("select id from messages where native_id = 'MSG0'")
        .fetch_one(&h.pool)
        .await
        .map(MessageId)
        .unwrap();

    let (unsend, sent) = post(Act::Unsend(target));
    h.mailbox.send(Event::Post(unsend)).unwrap();
    let outgoing = tokio::time::timeout(PATIENCE, h.outbound.recv())
        .await
        .unwrap()
        .unwrap();
    let row = outgoing.message;
    assert_eq!(row.content, Content::Unsend { target });
    assert_eq!(row.sender.name, "maxx");
    outgoing.receipt.unwrap().send(Ok(row.id)).unwrap();
    assert_eq!(sent.await.unwrap(), Ok(row.id));

    // An unsend is no message to take back.
    let (again, refused) = post(Act::Unsend(row.id));
    h.mailbox.send(Event::Post(again)).unwrap();
    assert!(refused.await.unwrap().is_err());
    h.stop().await;
    assert!(h.outbound.try_recv().is_err());
}

fn finished(how: How, text: &str) -> Finished {
    Finished {
        ending: Ending {
            how,
            text: Some(text.to_owned()),
        },
        file: Some("/work/.max/jobs/job-1.md".to_owned()),
    }
}

async fn ask(h: &Harness, request: Request) -> Result<serde_json::Value, String> {
    let (reply, answer) = oneshot::channel();
    h.mailbox.send(Event::Jobs { request, reply }).unwrap();
    tokio::time::timeout(PATIENCE, answer)
        .await
        .unwrap()
        .unwrap()
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_jobs_report_wakes_max(pool: PgPool) {
    let (mut h, _) = Harness::with_job(pool, "查票价").await;
    // The turn that started the job had rows to start from.
    h.send(from_xiaoming(0, vec![text("票价多少来着")]));
    h.script.push(Answer::says("票价查到了，一百块"));
    let finished = finished(How::Done, "一百块。");
    h.mailbox.send(Event::JobDone { job: 1, finished }).unwrap();
    assert_eq!(h.said().await.1, "票价查到了，一百块");
    let volatile = h.request_tail(0);
    assert!(
        volatile.ends_with("[job#1 完成] 查票价\n一百块。\n（全文在 /work/.max/jobs/job-1.md）\n"),
        "{volatile}"
    );
    // It ended: no more steering it.
    let steered = ask(
        &h,
        Request::Steer {
            job: 1,
            message: "再查查".into(),
        },
    )
    .await;
    assert!(steered.unwrap_err().contains("job#1 不在跑了"));
    h.stop().await;
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_job_is_steered_listed_and_cancelled(pool: PgPool) {
    let (mut h, mut steered) = Harness::with_job(pool, "查票价").await;
    let steer = Request::Steer {
        job: 1,
        message: "只要硬座".into(),
    };
    assert_eq!(ask(&h, steer).await.unwrap(), json!({ "job": "job#1" }));
    assert_eq!(steered.recv().await.unwrap(), "只要硬座");
    let status = ask(&h, Request::Status { job: None }).await.unwrap();
    assert_eq!(status["jobs"][0]["job"], "job#1");
    assert_eq!(status["jobs"][0]["title"], "查票价");
    assert_eq!(status["jobs"][0]["calls"], 0);
    let cancelled = ask(&h, Request::Cancel { job: 1 }).await.unwrap();
    assert_eq!(cancelled, json!({ "job": "job#1" }));
    // What a cancelled job says when it ends wakes nobody.
    let finished = finished(How::Done, "一百块。");
    h.mailbox.send(Event::JobDone { job: 1, finished }).unwrap();
    let status = ask(&h, Request::Status { job: None }).await.unwrap();
    assert_eq!(status, json!({ "jobs": [] }));
    h.stop().await;
    assert!(h.turns().await.is_empty());
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn without_a_job_model_no_job_starts(pool: PgPool) {
    let (mut h, _) = Harness::with_job(pool, "查票价").await;
    let start = Request::Start {
        task: "查一下".into(),
        title: None,
    };
    assert_eq!(ask(&h, start).await.unwrap_err(), "没配后台 agent 用的模型");
    h.stop().await;
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn kill_stops_the_jobs_too(pool: PgPool) {
    let (mut h, _) = Harness::with_job(pool, "查票价").await;
    h.send(from_xiaoming(0, vec![me(), text(" /status")]));
    let (_, status) = h.said().await;
    assert!(
        status.contains("job       job#1 · 0m · 0 calls · 查票价"),
        "{status}"
    );
    h.send(from_xiaoming(1, vec![me(), text(" /kill")]));
    let (_, killed) = h.said().await;
    assert!(killed.contains("/kill → 后台的 job#1 也停了"), "{killed}");
    let status = ask(&h, Request::Status { job: None }).await.unwrap();
    assert_eq!(status, json!({ "jobs": [] }));
    h.stop().await;
}
