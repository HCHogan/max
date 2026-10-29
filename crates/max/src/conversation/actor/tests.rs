//! The actor against the real database, a scripted model and a sender
//! that only records. Time is real: a paused clock would jump ahead while
//! the actor waits on Postgres. Waits are short and bounded.

use std::time::Duration;

use max_core::item::ItemKind;
use max_core::message::{Content, Node};
use max_core::run::Outcome;
use tokio::sync::{mpsc, oneshot};

use super::*;
use crate::conversation::testing::{from_xiaohong, from_xiaoming, group, shared, text};
use crate::historian::Captured;
use crate::inbound::InNode;
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
        Self::start(pool, idle_window_secs, xiaoming_owns, true).await
    }

    /// Without proactive replies: chatter starts no classifier call that
    /// races the core's calls for the script's answers.
    async fn unprompted(pool: PgPool, idle_window_secs: u64) -> Self {
        Self::start(pool, idle_window_secs, false, false).await
    }

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
        let (mut shared, outbound) = shared(&pool, &script, idle_window_secs, owners);
        let (historian, notices) = shared.rows.subscribe();
        shared.historian = Some(historian);
        let (mailbox, rx) = mpsc::unbounded_channel();
        let actor = Conversation::new(Arc::new(shared), place, mailbox.clone())
            .await
            .unwrap();
        let (done_tx, done) = oneshot::channel();
        let mut scope = Scope::new();
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

fn at_max(n: u32, said: &str) -> Inbound {
    from_xiaoming(
        n,
        vec![
            InNode::MentionMe {
                display: "maxx".into(),
            },
            text(said),
        ],
    )
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
    h.send(from_xiaoming(0, vec![text("/status")]));
    let (answer, status) = h.said().await;
    assert!(status.starts_with("🦈 maxx dev\n🌊 "), "{status}");
    assert!(
        status.contains("\n💬 proactive: on\n💤 idle\n⏱️ up "),
        "{status}"
    );
    let Content::Message { reply_to, .. } = answer.content else {
        unreachable!()
    };
    assert_eq!(reply_to, None, "an answer doesn't quote the command");

    h.send(from_xiaoming(1, vec![text("/model test/small")]));
    assert_eq!(h.said().await.1, "这个命令只有主人能用。");
    h.send(from_xiaoming(2, vec![text("/clear --all")]));
    assert_eq!(h.said().await.1, "这个命令只有群主、管理员能用。");
    // 小红 is an admin.
    h.send(from_xiaohong(3, vec![text("/clear --all")]));
    assert_eq!(h.said().await.1, "好，之前的聊天不再进上下文。");
    h.stop().await;
    assert_eq!(h.script.calls(), 0);
    assert!(h.turns().await.is_empty());
    let cleared = h
        .count("select cleared_upto from conversation_settings")
        .await;
    assert!(cleared > 0);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn compact_is_answered_when_the_historian_is_done(pool: PgPool) {
    let mut h = Harness::new(pool, 300).await;
    h.send(from_xiaoming(0, vec![text("/compact")]));
    assert_eq!(h.said().await.1, "这个命令只有群主、管理员能用。");
    h.send(from_xiaohong(1, vec![text("/compact")]));
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
    assert_eq!(text, "好，整理成了 2 段摘要。");
    let Content::Message { reply_to, .. } = answer.content else {
        unreachable!()
    };
    assert_eq!(reply_to, None);
    h.stop().await;
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn an_owner_changes_settings(pool: PgPool) {
    let mut h = Harness::with_owner(pool, 300, true).await;
    h.send(from_xiaoming(0, vec![text("/model test/nope")]));
    let answer = h.said().await.1;
    assert!(answer.starts_with("没有这个模型"), "{answer}");
    h.send(from_xiaoming(1, vec![text("/model test/small")]));
    assert_eq!(h.said().await.1, "下一次回复起用 test/small。");
    h.send(from_xiaoming(2, vec![text("/proactive off")]));
    assert_eq!(h.said().await.1, "主动接话关了，只在被叫到时回。");
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
    h.send(from_xiaohong(1, vec![text("/kill")]));
    let deadline = Instant::now() + PATIENCE;
    while h.turns().await[0].1.is_none() {
        assert!(Instant::now() < deadline, "the core didn't end");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(h.turns().await[0].1, Some(Outcome::Interrupted));
    h.stop().await;
    assert!(h.outbound.try_recv().is_err(), "/kill isn't answered");
}

/// The old group's records under the test group: 老红 and 老王 spoke there,
/// by QQ numbers 20001 and 20002.
async fn old_group(pool: &PgPool) {
    use max_core::ids::ConversationId;
    use max_core::message::{Platform, Role};
    use max_db::platform::ConversationKind;

    use crate::conversation::testing::{at, offset};
    use crate::inbound::Person;

    let mut conn = pool.acquire().await.unwrap();
    let conversation: i64 = sqlx::query_scalar(
        "select conversation_id from endpoints where native_id = 'group:GROUP1'",
    )
    .fetch_one(&mut *conn)
    .await
    .unwrap();
    let old_me = platform::account(&mut conn, Platform::QqLegacy, "10000", "Max")
        .await
        .unwrap();
    let native_id = "group:OLD1";
    let kind = ConversationKind::Group;
    let conversation = Some(ConversationId(conversation));
    let endpoint = platform::attach(
        &mut conn,
        conversation,
        Platform::QqLegacy,
        native_id,
        old_me.identity,
        kind,
    )
    .await
    .unwrap();
    let place = Place {
        conversation: endpoint.conversation,
        kind,
        endpoint: endpoint.id,
        platform: Platform::QqLegacy,
        native_id: native_id.into(),
        me: old_me,
        my_name: "Max".into(),
    };
    for (n, qq, name) in [(0, "20001", "老红"), (1, "20002", "老王")] {
        let mut said = from_xiaoming(n, vec![text("从前")]);
        said.platform = Platform::QqLegacy;
        said.chat.native_id = native_id.into();
        said.native_id = format!("OLD{n}");
        said.quote_id = None;
        said.sender = Person {
            native_user_id: qq.into(),
            name: name.into(),
            role: Some(Role::Member),
        };
        ingest::inbound(&mut conn, &place, &said, at(n), offset())
            .await
            .unwrap();
    }
}

fn from_xiaogang(n: u32, nodes: Vec<InNode>) -> Inbound {
    let mut inbound = from_xiaoming(n, nodes);
    inbound.sender = crate::inbound::Person {
        native_user_id: "XIAOGANG".into(),
        name: "小刚".into(),
        role: Some(max_core::message::Role::Member),
    };
    inbound
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn link_takes_people_back_to_their_old_selves(pool: PgPool) {
    // 小明 owns Max.
    let mut h = Harness::with_owner(pool, 300, true).await;
    old_group(&h.pool).await;
    let at = |who: &str, display: &str| InNode::Mention {
        user: who.into(),
        display: display.into(),
    };
    let mut asks = vec![
        (
            from_xiaohong(10, vec![text("/link")]),
            "在群里发 /link 你的QQ号，把这个账号接到老群记录里的你。",
        ),
        (
            from_xiaohong(11, vec![text("/link 20001")]),
            "好，接到了老群记录里的「老红」。",
        ),
        (from_xiaohong(12, vec![text("/link 20001")]), "已经接上了。"),
        (
            from_xiaohong(13, vec![text("/link 20002")]),
            "你已经接到老群记录里的另一个人了，要改找主人。",
        ),
        (
            from_xiaogang(14, vec![text("/link 99999")]),
            "老群的记录里没有这个 QQ 号说过的话。",
        ),
        (
            from_xiaogang(15, vec![text("/link 20001")]),
            "这个 QQ 号在这个群里已经有人接上了，有问题找主人。",
        ),
        (
            from_xiaogang(16, vec![text("/link "), at("XIAOHONG", "小红"), text(" -")]),
            "替别人接、撤销，只有主人能用。",
        ),
        (
            from_xiaoming(17, vec![text("/link 20002")]),
            "主人和 Max 自己的账号不用 /link。",
        ),
    ];
    // 小明 moves 老红 from 小红 to 小刚.
    let moved = from_xiaoming(
        18,
        vec![text("/link "), at("XIAOGANG", "小刚"), text(" 20001")],
    );
    asks.push((moved, "好，接到了老群记录里的「老红」。"));
    for (ask, answer) in asks {
        h.send(ask);
        assert_eq!(h.said().await.1, answer);
    }
    let pool = h.pool.clone();
    let linked = |native: &'static str| {
        let pool = pool.clone();
        async move {
            let mut conn = pool.acquire().await.unwrap();
            sqlx::query_scalar::<_, bool>(
                "select p.merged_into is not distinct from
                     (select principal_id from identities where native_user_id = '20001')
                 from identities i join principals p on p.id = i.principal_id
                 where i.native_user_id = $1",
            )
            .bind(native)
            .fetch_one(&mut *conn)
            .await
            .unwrap()
        }
    };
    assert!(linked("XIAOGANG").await);
    assert!(!linked("XIAOHONG").await);

    h.send(from_xiaoming(
        19,
        vec![text("/link "), at("XIAOGANG", "小刚"), text(" -")],
    ));
    assert_eq!(h.said().await.1, "好，撤销了这个账号的关联。");
    assert!(!linked("XIAOGANG").await);
    h.stop().await;
    assert_eq!(h.script.calls(), 0);
}
