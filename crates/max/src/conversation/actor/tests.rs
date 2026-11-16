//! The actor against the real database, a scripted model and a sender
//! that only records. Time is real: a paused clock would jump ahead while
//! the actor waits on Postgres. Waits are short and bounded.

use std::time::Duration;

use max_core::ids::ConversationId;
use max_core::item::ItemKind;
use max_core::message::{Content, Node};
use max_core::run::Outcome;
use max_db::PgPool;
use tokio::sync::{mpsc, oneshot};

use super::*;
use crate::command;
use crate::conversation::Heard;
use crate::conversation::testing::{from_xiaohong, from_xiaoming, group, shared, text};
use crate::inbound::InNode;
use crate::llm::testing::{Answer, Script};

const PATIENCE: Duration = Duration::from_secs(5);

struct Harness {
    pool: PgPool,
    script: Arc<Script>,
    mailbox: UnboundedSender<Event>,
    outbound: UnboundedReceiver<Outgoing>,
    done: Option<oneshot::Receiver<()>>,
    _scope: Scope,
}

impl Harness {
    async fn new(pool: PgPool, idle_window_secs: u64) -> Self {
        Self::start(pool, idle_window_secs, false, true).await
    }

    /// Without proactive replies: chatter starts no classifier call that
    /// races the core's calls for the script's answers.
    async fn unprompted(pool: PgPool, idle_window_secs: u64) -> Self {
        Self::start(pool, idle_window_secs, false, false).await
    }

    /// In a group, with 小明 as Max's owner if `xiaoming_owns`.
    async fn start(
        pool: PgPool,
        idle_window_secs: u64,
        xiaoming_owns: bool,
        proactive: bool,
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
        let (shared, outbound) = shared(&pool, &script, idle_window_secs, owners);
        let mut scope = Scope::new();
        let (mailbox, rx) = mpsc::unbounded_channel();
        let actor = Conversation::new(Arc::new(shared), place, mailbox.clone())
            .await
            .unwrap();
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
            done: Some(done),
            _scope: scope,
        }
    }

    fn send(&self, inbound: Inbound) {
        self.mailbox.send(Event::Inbound(inbound)).unwrap();
    }

    /// Asks as a tool called from the group's VM does.
    fn poster(&self) -> Poster {
        Poster::new(self.mailbox.clone())
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
        (Arc::unwrap_or_clone(outgoing.message), text)
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

/// Until the model has been called `n` times.
async fn calls_reach(h: &Harness, n: usize) {
    let deadline = Instant::now() + PATIENCE;
    while h.script.calls() < n {
        assert!(
            Instant::now() < deadline,
            "{} model calls",
            h.script.calls()
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
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
    assert_eq!(
        text,
        "```text\nerror: the model call failed: the provider answered 400: nope\n```"
    );
    let Content::Message { reply_to, .. } = message.content else {
        unreachable!()
    };
    assert!(reply_to.is_some());
    assert_eq!(message.turn, None);
    assert_eq!(ingest::by(&message), ingest::By::Host);
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
    assert_eq!(h.count("select count(run) from turn_outcomes").await, 1);
    let (_, said) = h.said().await;
    assert_eq!(
        said,
        "```text\nerror: interrupted: Max is shutting down, and the turn outlasted the 200ms grace\n```"
    );
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
    let (_, outcome) = h.turns().await.remove(0);
    assert_eq!(outcome, Some(Outcome::Interrupted));
    h.stop().await;
    assert!(h.outbound.try_recv().is_err(), "/kill isn't answered");
}

/// A post that waits to hear how it went.
fn post(act: Act) -> (Post, oneshot::Receiver<Result<MessageId, String>>) {
    let (receipt, sent) = oneshot::channel();
    let post = Post {
        act,
        receipt: Some(receipt),
    };
    (post, sent)
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_program_says_things_marked_as_its_own(pool: PgPool) {
    let mut h = Harness::new(pool, 300).await;
    let (reply, result) = oneshot::channel();
    let call = Event::Call {
        tool: "say".into(),
        args: serde_json::json!({ "text": "早[split]CI 全绿" }),
        reply,
    };
    h.mailbox.send(call).unwrap();
    let mut ids = Vec::new();
    for said in ["早", "CI 全绿"] {
        let outgoing = tokio::time::timeout(PATIENCE, h.outbound.recv())
            .await
            .unwrap()
            .unwrap();
        let row = outgoing.message;
        assert_eq!(
            row.content,
            Content::Message {
                reply_to: None,
                nodes: vec![Node::Text { text: said.into() }],
            }
        );
        assert_eq!(row.turn, None);
        outgoing.receipt.unwrap().send(Ok(row.id)).unwrap();
        ids.push(row.id.0);
    }
    let result = tokio::time::timeout(PATIENCE, result).await.unwrap();
    assert_eq!(result.unwrap(), Ok(serde_json::json!({ "messages": ids })));
    let marked = "select count(*) from messages where raw->>'said_by' = 'program'";
    assert_eq!(h.count(marked).await, 2);

    // Max sees them as a program's.
    h.script.push(Answer::says("嗯"));
    h.send(from_xiaoming(0, vec![me(), text(" 刚才谁说的")]));
    h.said().await;
    let shown: String = h.script.requests.lock().unwrap()[0]
        .items
        .iter()
        .filter_map(|item| match &item.kind {
            ItemKind::User { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect();
    let line = format!(" #{} 程序发的]: 早", ids[0]);
    assert!(shown.contains(&line), "{shown}");
    h.stop().await;
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn stop_ends_the_turn_and_nothing_starts_until_start(pool: PgPool) {
    // 小明 owns Max here, and no classifier call races the core's.
    let mut h = Harness::start(pool, 300, true, false).await;
    h.script.push(Answer::Hangs);
    h.send(at_max(0, " 写篇长文"));
    calls_reach(&h, 1).await;
    // 小红 is an admin.
    h.send(from_xiaohong(1, vec![me(), text("/stop")]));
    assert_eq!(
        h.said().await.1,
        command::answer(
            "stopped: messages are still recorded, but Max won't reply until @maxx /start"
        )
    );
    assert_eq!(h.turns().await[0].1, Some(Outcome::Interrupted));

    // An @ is recorded, but wakes nobody; commands are still answered.
    h.send(at_max(2, " 在吗"));
    h.send(from_xiaohong(3, vec![me(), text("/stop")]));
    assert_eq!(
        h.said().await.1,
        command::answer("skipped: already stopped")
    );
    h.send(from_xiaohong(4, vec![me(), text("/status")]));
    let status = h.said().await.1;
    assert!(status.contains("\nstate     stopped\n"), "{status}");
    // The programs can't post, wake Max, mute or ask another
    // conversation; they can still read.
    let draft = Draft {
        reply_to: None,
        nodes: vec![DraftNode::Text {
            text: "CI 挂了".into(),
        }],
    };
    let stopped = Refusal::Stopped.why().to_owned();
    assert_eq!(stopped, "Max is stopped here (/stop), so this wasn't done");
    let (say, sent) = post(Act::Say(draft));
    h.mailbox.send(Event::Post(say)).unwrap();
    assert_eq!(sent.await.unwrap(), Err(stopped.clone()));
    assert_eq!(
        h.poster().wake("CI 挂了".into()).await,
        Err(stopped.clone())
    );
    h.mailbox
        .send(Event::Heard(Heard::Vm("VM 起不来了".into())))
        .unwrap();
    let (reply, muted) = oneshot::channel();
    let call = Event::Call {
        tool: "mute_member".into(),
        args: serde_json::json!({ "member": 1, "seconds": 60 }),
        reply,
    };
    h.mailbox.send(call).unwrap();
    let refused = service::Failure::new("refused", stopped.clone());
    assert_eq!(muted.await.unwrap().unwrap_err(), refused);
    let asked = h.poster().ask(ConversationId(9), "在吗".into()).await;
    assert_eq!(asked.unwrap_err(), stopped);
    assert_eq!(h.turns().await.len(), 1);

    // 小明 is Max's owner here.
    h.send(from_xiaoming(5, vec![me(), text("/start")]));
    assert_eq!(
        h.said().await.1,
        command::answer("started: Max replies again")
    );
    h.send(from_xiaoming(6, vec![me(), text("/start")]));
    assert_eq!(h.said().await.1, command::answer("skipped: not stopped"));
    h.script.push(Answer::says("在"));
    h.send(from_xiaohong(7, vec![me(), text(" 在吗")]));
    assert_eq!(h.said().await.1, "在");
    h.stop().await;
    assert_eq!(h.turns().await.len(), 2);
    let stopped = "select count(*) from conversation_settings where stopped";
    assert_eq!(h.count(stopped).await, 0);
}

/// What goes on after `/stop` and as Max shuts down: by what an event
/// would do, not by which event it is.
#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn one_rule_says_what_is_refused(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    drop(conn);
    let script = Arc::new(Script::default());
    let (shared, _outbound) = shared(&pool, &script, 300, BTreeSet::new());
    let (mailbox, _events) = mpsc::unbounded_channel();
    let mut actor = Conversation::new(Arc::new(shared), place, mailbox)
        .await
        .unwrap();
    let kinds = [Does::LOOKS, Does::ACTS, Does::RUNS, Does::STARTS];
    let refused = |actor: &Conversation| kinds.map(|does| actor.refuses(does));
    let (stopped, stopping) = (Some(Refusal::Stopped), Some(Refusal::Stopping));

    // Whatever calls from the VM, with or without a turn running, is
    // refused nothing.
    assert_eq!(refused(&actor), [None; 4]);
    // After /stop, what has Max say or do something.
    actor.settings.stopped = true;
    assert_eq!(refused(&actor), [None, stopped, None, stopped]);
    // As Max shuts down, what starts work.
    actor.settings.stopped = false;
    actor.stopping = Some(Instant::now());
    assert_eq!(refused(&actor), [None, None, stopping, stopping]);
    actor.settings.stopped = true;
    assert_eq!(refused(&actor), [None, stopped, stopping, stopped]);
}
