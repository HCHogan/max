//! The actor against the real database, a scripted model and a sender
//! that only records. Time is real: a paused clock would jump ahead while
//! the actor waits on Postgres. Waits are short and bounded.

use std::time::Duration;

use max_core::ids::ConversationId;
use max_core::item::{Image, ItemKind};
use max_core::limits::Setting;
use max_core::message::{Content, Node};
use max_core::run::Outcome;
use max_db::PgPool;
use max_db::links::Peer;
use max_db::platform::ConversationKind::{self, Direct, Group};
use tokio::sync::{mpsc, oneshot};

use super::*;
use crate::command;
use crate::conversation::testing::{
    from_xiaohong, from_xiaoming, group, private, privately, shared, text,
};
use crate::conversation::{Configured, Question};
use crate::inbound::{InNode, Quote};
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
        Self::with_owner(pool, idle_window_secs, false).await
    }

    /// With 小明 as Max's owner, if `xiaoming_owns`.
    async fn with_owner(pool: PgPool, idle_window_secs: u64, xiaoming_owns: bool) -> Self {
        Self::start(
            pool,
            Group,
            idle_window_secs,
            xiaoming_owns,
            true,
            None,
            |_| {},
        )
        .await
    }

    /// Without proactive replies: chatter starts no classifier call that
    /// races the core's calls for the script's answers.
    async fn unprompted(pool: PgPool, idle_window_secs: u64) -> Self {
        Self::start(pool, Group, idle_window_secs, false, false, None, |_| {}).await
    }

    /// With ask#1, `question` put to c#9, waiting for its answer as far
    /// as the actor knows.
    async fn with_job(pool: PgPool, question: &str) -> Self {
        Self::start(pool, Group, 300, true, false, None, |actor| {
            actor.jobs.pretend(9, question);
        })
        .await
    }

    /// In 小明's private chat with Max.
    async fn private(pool: PgPool) -> Self {
        Self::start(pool, Direct, 300, false, true, None, |_| {}).await
    }

    /// With the VMs' directory at `vm_dir`, where the memory file is.
    async fn with_vm_dir(pool: PgPool, vm_dir: PathBuf) -> Self {
        Self::start(pool, Group, 300, false, false, Some(vm_dir), |_| {}).await
    }

    async fn start(
        pool: PgPool,
        kind: ConversationKind,
        idle_window_secs: u64,
        xiaoming_owns: bool,
        proactive: bool,
        vm_dir: Option<PathBuf>,
        prepare: impl FnOnce(&mut Conversation),
    ) -> Self {
        let mut conn = pool.acquire().await.unwrap();
        let place = Arc::new(match kind {
            Group => group(&mut conn).await,
            Direct => private(&mut conn).await,
        });
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
        shared.vm_dir = vm_dir;
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

    /// The pictures in the last item of the n-th request, by handle.
    fn request_pictures(&self, n: usize) -> Vec<String> {
        let requests = self.script.requests.lock().unwrap();
        match &requests[n].items.last().unwrap().kind {
            ItemKind::User { images, .. } => images.iter().map(Image::handle).collect(),
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

/// The usage of a model call that can't be recorded: the turn goes on,
/// and so does the conversation.
#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn an_unrecorded_usage_holds_nothing_up(pool: PgPool) {
    sqlx::query("alter table llm_usage add constraint never check (false) not valid")
        .execute(&pool)
        .await
        .unwrap();
    let mut h = Harness::new(pool, 300).await;
    h.script.push(Answer::says("在的"));
    h.send(at_max(0, " 在吗"));
    assert_eq!(h.said().await.1, "在的");
    h.script.push(Answer::says("还在"));
    h.send(at_max(1, " 还在吗"));
    assert_eq!(h.said().await.1, "还在");
    h.stop().await;
    assert_eq!(h.count("select count(*) from llm_usage").await, 0);
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

/// A picture from before the core started is in its tail by its caption
/// only: a row that quotes it while the core runs brings the picture.
#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_row_brings_the_picture_it_quotes(pool: PgPool) {
    use max_core::message::{MediaKind, MediaMeta, MediaRef};

    let mut h = Harness::unprompted(pool, 300).await;
    h.script.push(Answer::says("嗯"));
    h.script.push(Answer::says("一只猫"));
    let picture = InNode::Node(Node::Media {
        media: Some(MediaRef::Remote("https://q.example/cat".into())),
        meta: MediaMeta {
            kind: MediaKind::Image,
            mime: None,
            size: None,
            name: None,
            description: None,
        },
    });
    h.send(from_xiaohong(0, vec![picture]));
    h.send(at_max(1, " 在吗"));
    assert_eq!(h.said().await.1, "嗯");
    assert!(h.request_pictures(0).is_empty());
    let mut ask = at_max(2, " 这是什么");
    ask.quote = Some(Quote {
        quote_id: Some("IDX0".into()),
        ..Quote::default()
    });
    h.send(ask);
    assert_eq!(h.said().await.1, "一只猫");
    let picture = h
        .count("select id from messages where native_id = 'MSG0'")
        .await;
    assert_eq!(h.request_pictures(1), [format!("image#{picture}.0")]);
    h.stop().await;
}

/// Someone who @s Max and finishes the sentence in the next message gets
/// one answer to both: the call that hasn't said anything starts over.
#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn the_rest_of_a_sentence_starts_the_call_over(pool: PgPool) {
    let mut h = Harness::unprompted(pool, 300).await;
    h.script.push(Answer::Hangs);
    h.script.push(Answer::says("给 nix 用就选这个"));
    h.send(at_max(0, " 推荐用哪个？"));
    calls_reach(&h, 1).await;
    // Other people's rows, and his to someone else, wait for the next call.
    h.send(from_xiaohong(1, vec![text("插一句")]));
    let mention = InNode::Mention {
        user: "XIAOHONG".into(),
        display: "小红".into(),
    };
    h.send(from_xiaoming(2, vec![mention, text(" 你也看看")]));
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(h.script.calls(), 1);
    h.send(from_xiaoming(3, vec![text("如果我要给nix用的话")]));
    assert_eq!(h.said().await.1, "给 nix 用就选这个");
    let tail = h.request_tail(1);
    assert!(tail.starts_with("[新消息]\n"), "{tail}");
    assert!(tail.contains("插一句"), "{tail}");
    assert!(tail.ends_with("如果我要给nix用的话"), "{tail}");
    h.stop().await;
    assert_eq!(h.turns().await.len(), 1);
}

/// A call starts over at most three times before one finishes, and not for
/// someone who has been answered since.
#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_call_starts_over_only_so_often(pool: PgPool) {
    let mut h = Harness::unprompted(pool, 300).await;
    h.script.push(Answer::says("先说一句"));
    h.script.push(Answer::Hangs);
    for _ in 0..4 {
        h.script.push(Answer::Hangs);
    }
    h.send(at_max(0, " 在吗"));
    assert_eq!(h.said().await.1, "先说一句");
    h.send(from_xiaohong(1, vec![me(), text(" 再问一个")]));
    calls_reach(&h, 2).await;
    // 小明 has been answered: his next words start nothing over.
    h.send(from_xiaoming(2, vec![text("好")]));
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(h.script.calls(), 2);
    for n in 0..4 {
        h.send(from_xiaohong(3 + n, vec![text("还有")]));
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
    assert_eq!(h.script.calls(), 5, "one call and three over");
    h.stop().await;
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
async fn a_core_is_shown_the_memory_file(pool: PgPool) {
    let dir = std::env::temp_dir().join(format!("max-memory-{:016x}", rand::random::<u64>()));
    let mut h = Harness::with_vm_dir(pool, dir.clone()).await;
    let conversation: i64 = sqlx::query_scalar("select max(id) from conversations")
        .fetch_one(&h.pool)
        .await
        .unwrap();
    let memory = vm::work(&dir, ConversationId(conversation)).join(".max");
    std::fs::create_dir_all(&memory).unwrap();
    let text = "# 记忆\n\n## 群里\n- 群友叫你小鲨鲨（2026-08-28 #3）\n";
    std::fs::write(memory.join("memory.md"), text).unwrap();
    h.script.push(Answer::says("在"));
    h.send(at_max(0, " 小鲨鲨？"));
    h.said().await;
    let volatile = h.request_tail(0);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        volatile.contains(&format!("\n[记忆]\n{text}\n[新消息]\n")),
        "{volatile}"
    );
    h.stop().await;
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
async fn commands_answer_and_never_wake(pool: PgPool) {
    let mut h = Harness::new(pool, 300).await;
    h.send(from_xiaoming(0, vec![me(), text("/status")]));
    let (answer, status) = h.said().await;
    assert!(
        status.starts_with("```text\n/status → maxx dev\nos        "),
        "{status}"
    );
    assert!(
        status.contains(
            "\nmodel     test/big · high\nproactive on\ncore      idle\n24h       none\n7d        none\nuptime    "
        ),
        "{status}"
    );
    assert!(status.ends_with("\n```"), "{status}");
    let Content::Message { reply_to, .. } = answer.content else {
        unreachable!()
    };
    assert_eq!(reply_to, None, "an answer doesn't quote the command");

    // Its model calls, one of them on a model with no price, and the
    // tokens they used in the last day and week.
    sqlx::query(
        "insert into llm_usage
             (conversation_id, purpose, provider, model, input, cached, output, reasoning, at)
         select id, 'turn', 'test', model, input, cached, output, 0, now() - ago
         from conversations, (values
             ('big', 10000000, 8000000, 100000, interval '1 hour'),
             ('small', 1000, 0, 10, interval '3 days'),
             ('big', 5, 0, 5, interval '8 days')
         ) as calls (model, input, cached, output, ago)",
    )
    .execute(&h.pool)
    .await
    .unwrap();
    h.send(from_xiaoming(20, vec![me(), text("/status")]));
    let status = h.said().await.1;
    assert!(
        status.contains(
            "\n24h       in 10.0M · out 100k · cache 80.0% · $1.70\n\
             7d        in 10.0M · out 100k · cache 80.0% · ≥ $1.70\n"
        ),
        "{status}"
    );

    h.send(from_xiaoming(1, vec![me(), text("/model test/small")]));
    assert_eq!(
        h.said().await.1,
        command::answer("model", "refused: Max's owners only")
    );
    h.send(from_xiaoming(2, vec![me(), text("/clear --all")]));
    assert_eq!(
        h.said().await.1,
        command::answer("clear", "refused: the group owner and admins only")
    );
    // 小红 is an admin.
    h.send(from_xiaohong(3, vec![me(), text("/clear --all")]));
    assert_eq!(
        h.said().await.1,
        command::answer(
            "clear",
            "cleared: earlier messages are out of the context; @maxx /unclear brings them back"
        )
    );
    let cleared = h
        .count("select cleared_upto from conversation_settings")
        .await;
    assert!(cleared > 0);

    h.send(from_xiaoming(4, vec![me(), text("/unclear")]));
    assert_eq!(
        h.said().await.1,
        command::answer("unclear", "refused: the group owner and admins only")
    );
    h.send(from_xiaohong(5, vec![me(), text("/unclear")]));
    assert_eq!(
        h.said().await.1,
        command::answer(
            "unclear",
            "uncleared: the messages before the clear are back in the context"
        )
    );
    h.send(from_xiaohong(6, vec![me(), text("/unclear")]));
    assert_eq!(
        h.said().await.1,
        command::answer("unclear", "skipped: never cleared")
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
async fn an_owner_changes_settings(pool: PgPool) {
    let mut h = Harness::with_owner(pool, 300, true).await;
    h.send(from_xiaoming(0, vec![me(), text("/model test/nope")]));
    let answer = h.said().await.1;
    assert!(answer.contains("/model → error: no such model"), "{answer}");
    h.send(from_xiaoming(1, vec![me(), text("/model test/wide")]));
    assert_eq!(
        h.said().await.1,
        command::answer(
            "model",
            "switched to test/wide; takes effect from the next reply"
        )
    );
    h.send(from_xiaoming(2, vec![me(), text("/proactive off")]));
    assert_eq!(
        h.said().await.1,
        command::answer(
            "proactive",
            "proactive off: Max replies only when @-ed or replied to"
        )
    );
    h.script.push(Answer::says("嗯"));
    // From 小红: 小明's burst of commands would hold his @ as unfinished.
    let mention = InNode::MentionMe {
        display: "maxx".into(),
    };
    h.send(from_xiaohong(3, vec![mention, text(" 在吗")]));
    h.said().await;
    // The turn that answered goes on as it started.
    h.send(from_xiaoming(4, vec![me(), text("/effort high")]));
    assert_eq!(
        h.said().await.1,
        command::answer(
            "effort",
            "effort set to high; takes effect when the running turn ends, after 5 minutes idle"
        )
    );
    h.stop().await;
    let proactive = h
        .count("select count(*) from conversation_settings where not proactive")
        .await;
    assert_eq!(proactive, 1);
    let requests = h.script.requests.lock().unwrap();
    assert_eq!(requests[0].model.model, "wide");
    // Max sees the answers as the host's, not its own words.
    let shown: String = requests[0]
        .items
        .iter()
        .filter_map(|item| match &item.kind {
            ItemKind::User { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(shown.matches(" 系统发的]: ").count(), 3, "{shown}");
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_private_chat_is_its_persons_to_command(pool: PgPool) {
    let mut h = Harness::private(pool).await;
    h.send(privately(from_xiaoming(0, vec![text("/model test/wide")])));
    assert_eq!(
        h.said().await.1,
        command::answer(
            "model",
            "switched to test/wide; takes effect from the next reply"
        )
    );
    h.send(privately(from_xiaoming(1, vec![text("/clear --all")])));
    let cleared = h.said().await.1;
    assert!(cleared.contains("/clear → cleared: "), "{cleared}");
    // Binding a group is the owners' alone.
    h.send(privately(from_xiaoming(2, vec![text("/bind")])));
    assert_eq!(
        h.said().await.1,
        command::answer("bind", "refused: Max's owners only")
    );
    h.stop().await;
    assert_eq!(h.script.calls(), 0);
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

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_queued_post_hears_its_row_before_it_is_sent(pool: PgPool) {
    let mut h = Harness::unprompted(pool, 300).await;
    let queue = |nodes: Vec<DraftNode>| {
        let draft = Draft {
            reply_to: None,
            nodes,
        };
        post(Act::Queue(draft))
    };
    let (file, committed) = queue(vec![DraftNode::Text {
        text: "录像.mp4".into(),
    }]);
    h.mailbox.send(Event::Post(file)).unwrap();
    let id = tokio::time::timeout(PATIENCE, committed)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    // The sender has it to send, and nobody to tell.
    let outgoing = tokio::time::timeout(PATIENCE, h.outbound.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(outgoing.message.id, id);
    assert!(outgoing.receipt.is_none());

    let (empty, committed) = queue(Vec::new());
    h.mailbox.send(Event::Post(empty)).unwrap();
    assert!(committed.await.unwrap().is_err());
    h.stop().await;
    assert!(h.outbound.try_recv().is_err());
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

/// A program's call ends once nobody waits for its result, as when the MCP
/// service has given up on it; but a `say` goes out whole, as Max's own
/// reply does. Here the first message's receipt never comes.
#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_program_call_nobody_waits_for_ends(pool: PgPool) {
    let mut h = Harness::new(pool, 300).await;
    let (reply, result) = oneshot::channel();
    let call = Event::Call {
        tool: "say".into(),
        args: serde_json::json!({ "text": "早[split]CI 全绿" }),
        reply,
    };
    h.mailbox.send(call).unwrap();
    let mut result = Some(result);
    let mut receipts = Vec::new();
    for said in ["早", "CI 全绿"] {
        let outgoing = tokio::time::timeout(PATIENCE, h.outbound.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            outgoing.message.content,
            Content::Message {
                reply_to: None,
                nodes: vec![Node::Text { text: said.into() }],
            }
        );
        receipts.push(outgoing.receipt.unwrap());
        // Given up on once the first message is out.
        result.take();
    }
    // The `say` no longer waits for the receipts.
    for mut receipt in receipts {
        tokio::time::timeout(PATIENCE, receipt.closed())
            .await
            .expect("the call went on");
    }
    h.stop().await;
}

/// A marker whose id a program didn't fill in stops its say; in code, it
/// is an example, and goes out.
#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_program_says_nothing_with_an_unfilled_id(pool: PgPool) {
    let mut h = Harness::new(pool, 300).await;
    let (reply, refused) = oneshot::channel();
    let call = Event::Call {
        tool: "say".into(),
        args: serde_json::json!({ "text": "[reply#${id}] 构建好了" }),
        reply,
    };
    h.mailbox.send(call).unwrap();
    let refused = tokio::time::timeout(PATIENCE, refused).await.unwrap();
    assert_eq!(refused.unwrap().unwrap_err().code, "unfilled");
    assert!(h.outbound.try_recv().is_err());

    let example = "回复写成 `[reply#${id}]`";
    let (reply, result) = oneshot::channel();
    let call = Event::Call {
        tool: "say".into(),
        args: serde_json::json!({ "text": example }),
        reply,
    };
    h.mailbox.send(call).unwrap();
    let outgoing = tokio::time::timeout(PATIENCE, h.outbound.recv())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        outgoing.message.content,
        Content::Message {
            reply_to: None,
            nodes: vec![Node::Text {
                text: example.into()
            }],
        }
    );
    outgoing
        .receipt
        .unwrap()
        .send(Ok(outgoing.message.id))
        .unwrap();
    let said = tokio::time::timeout(PATIENCE, result).await.unwrap();
    assert!(said.unwrap().is_ok());
    h.stop().await;
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
async fn a_program_follows_the_rows_as_they_are_committed(pool: PgPool) {
    let mut h = Harness::new(pool, 300).await;
    h.script.push(Answer::says("早"));
    h.send(from_xiaoming(0, vec![me(), text(" 在吗")]));
    let (said, _) = h.said().await;
    let (reply, subscribed) = oneshot::channel();
    h.mailbox.send(Event::Subscribe(reply)).unwrap();
    let mut subscription = tokio::time::timeout(PATIENCE, subscribed)
        .await
        .unwrap()
        .unwrap();
    // The rows up to the head are in the database; those after come.
    assert_eq!(subscription.head, said.id);
    h.script.push(Answer::says("在"));
    h.send(from_xiaoming(1, vec![me(), text(" 真在吗")]));
    let (answer, _) = h.said().await;
    let asked = subscription.rows.recv().await.unwrap();
    assert_eq!(asked.sender.name, "小明");
    let answered = subscription.rows.recv().await.unwrap();
    assert_eq!(answered.id, answer.id);
    assert!(asked.id > said.id && asked.id < answer.id);
    // The actor stopped: the stream ends.
    h.stop().await;
    assert!(subscription.rows.recv().await.is_err());
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn kill_stops_the_jobs_too(pool: PgPool) {
    let mut h = Harness::with_job(pool, "票价多少").await;
    let jobs = h.poster().status(None).await.unwrap();
    assert_eq!(
        (jobs[0].handle.as_str(), jobs[0].title.as_str()),
        ("ask#1", "? c#9: 票价多少")
    );
    // What ran in the VM under that name until 2026-11-12 is a unit
    // there now.
    let agent = h.poster().cancel(Handle::Agent(1)).await.unwrap_err();
    assert!(agent.contains("systemctl stop max-agent-1"), "{agent}");
    h.send(from_xiaoming(0, vec![me(), text(" /status")]));
    let (_, status) = h.said().await;
    assert!(
        status.contains("job       ask#1 · 0m · ? c#9: 票价多少"),
        "{status}"
    );
    h.send(from_xiaoming(1, vec![me(), text(" /kill")]));
    let (_, killed) = h.said().await;
    assert!(killed.contains("/kill → jobs stopped: ask#1"), "{killed}");
    assert_eq!(h.poster().status(None).await, Ok(Vec::new()));
    h.stop().await;
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn stop_ends_the_turn_and_its_jobs_and_nothing_starts_until_start(pool: PgPool) {
    let mut h = Harness::with_job(pool, "票价多少").await;
    h.script.push(Answer::Hangs);
    h.send(at_max(0, " 写篇长文"));
    calls_reach(&h, 1).await;
    // 小红 is an admin.
    h.send(from_xiaohong(1, vec![me(), text("/stop")]));
    assert_eq!(
        h.said().await.1,
        command::answer(
            "stop",
            "stopped: messages are still recorded, but Max won't reply until @maxx /start\n\
             jobs stopped: ask#1"
        )
    );
    assert_eq!(h.turns().await[0].1, Some(Outcome::Interrupted));

    // An @ is recorded, but wakes nobody; commands are still answered.
    h.send(at_max(2, " 在吗"));
    h.send(from_xiaohong(3, vec![me(), text("/stop")]));
    assert_eq!(
        h.said().await.1,
        command::answer("stop", "skipped: already stopped")
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
        .send(Event::VmNotice("VM 起不来了".into()))
        .unwrap();
    let (reply, muted) = oneshot::channel();
    let call = Event::Call {
        tool: "mute_member".into(),
        args: serde_json::json!({ "member": 1, "seconds": 60 }),
        reply,
    };
    h.mailbox.send(call).unwrap();
    let refused = mcp::Failure::new("refused", stopped.clone());
    assert_eq!(muted.await.unwrap().unwrap_err(), refused);
    let asked = h.poster().ask(ConversationId(9), "在吗".into()).await;
    assert_eq!(asked.unwrap_err(), stopped);
    assert_eq!(h.poster().status(None).await, Ok(Vec::new()));
    assert_eq!(h.turns().await.len(), 1);

    // 小明 is Max's owner here.
    h.send(from_xiaoming(5, vec![me(), text("/start")]));
    assert_eq!(
        h.said().await.1,
        command::answer("start", "started: Max replies again")
    );
    h.send(from_xiaoming(6, vec![me(), text("/start")]));
    assert_eq!(
        h.said().await.1,
        command::answer("start", "skipped: not stopped")
    );
    h.script.push(Answer::says("在"));
    h.send(from_xiaohong(7, vec![me(), text(" 在吗")]));
    assert_eq!(h.said().await.1, "在");
    h.stop().await;
    assert_eq!(h.turns().await.len(), 2);
    let stopped = "select count(*) from conversation_settings where stopped";
    assert_eq!(h.count(stopped).await, 0);
}

/// A stopped conversation's next actor, as after a restart, is stopped
/// too. Intent didn't see what came meanwhile: the classifier's first
/// call is on what comes after `/start`.
#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_stop_outlasts_a_restart(pool: PgPool) {
    let mut h = Harness::new(pool.clone(), 300).await;
    h.send(from_xiaohong(0, vec![me(), text("/stop")]));
    h.said().await;
    h.stop().await;
    let mut h = Harness::new(pool, 300).await;
    h.script
        .push(Answer::says(r#"{"trigger": false, "reason": "闲聊"}"#));
    h.send(at_max(1, " 在吗"));
    h.send(from_xiaoming(2, vec![text("今天吃什么")]));
    h.send(from_xiaohong(3, vec![me(), text("/start")]));
    assert_eq!(
        h.said().await.1,
        command::answer("start", "started: Max replies again")
    );
    h.send(from_xiaohong(4, vec![text("明天呢")]));
    calls_reach(&h, 1).await;
    h.stop().await;
    assert!(h.turns().await.is_empty());
    let requests = h.script.requests.lock().unwrap();
    assert_eq!(requests.len(), 1);
    let shown: String = requests[0]
        .items
        .iter()
        .filter_map(|item| match &item.kind {
            ItemKind::User { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect();
    assert!(shown.contains("明天呢"), "{shown}");
}

/// Only the group owner and admins stop Max, and in a private chat its
/// person.
#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn who_stops_max(pool: PgPool) {
    let mut h = Harness::new(pool.clone(), 300).await;
    h.send(from_xiaoming(0, vec![me(), text("/stop")]));
    assert_eq!(
        h.said().await.1,
        command::answer("stop", "refused: the group owner and admins only")
    );
    h.stop().await;
    let mut h = Harness::private(pool).await;
    h.send(privately(from_xiaoming(1, vec![text("/stop")])));
    let answer = h.said().await.1;
    assert!(answer.contains("Max won't reply until /start"), "{answer}");
    h.stop().await;
}

/// Max's `config`, as its tool asks: what each limit is now, or why not.
async fn configure(
    h: &Harness,
    changes: Vec<(Setting, Option<u64>)>,
) -> Result<Vec<Configured>, String> {
    h.poster().configure(changes).await
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn max_sets_the_idle_window_of_the_running_turn(pool: PgPool) {
    let mut h = Harness::new(pool, 300).await;
    h.script.push(Answer::says("好"));
    h.send(at_max(0, " 在吗"));
    h.said().await;
    assert_eq!(h.turns().await[0].1, None, "the turn goes on");

    // Below what the tool allows, so the test is short: the actor
    // trusts the command and the tool to keep to the ranges.
    let configured = configure(&h, vec![(Setting::IdleWindowSecs, Some(1))])
        .await
        .unwrap();
    let idle = configured
        .iter()
        .find(|one| one.setting == Setting::IdleWindowSecs);
    assert_eq!(idle.map(|one| (one.value, one.default)), Some((1, 300)));
    let deadline = Instant::now() + PATIENCE;
    while h.turns().await[0].1.is_none() {
        assert!(Instant::now() < deadline, "the core didn't end");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert_eq!(h.turns().await[0].1, Some(Outcome::Answered));
    h.stop().await;
    let saved = h
        .count("select (overrides->>'idle_window_secs')::bigint from conversation_settings")
        .await;
    assert_eq!(saved, 1);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn admins_config_the_limits_and_everyone_sees_them(pool: PgPool) {
    let mut h = Harness::new(pool, 300).await;
    h.send(from_xiaoming(0, vec![me(), text("/config")]));
    assert_eq!(
        h.said().await.1,
        command::answer(
            "config",
            "this conversation's limits\n\
             idle_window_secs  300\n\
             call_time_secs    60"
        )
    );
    h.send(from_xiaoming(
        1,
        vec![me(), text("/config call_time_secs 120")],
    ));
    assert_eq!(
        h.said().await.1,
        command::answer("config", "refused: the group owner and admins only")
    );
    // 小红 is an admin.
    let mut n = 2;
    let mut config = |h: &Harness, argument: &str| {
        h.send(from_xiaohong(
            n,
            vec![me(), text(&format!("/config {argument}"))],
        ));
        n += 1;
    };
    for (argument, answer) in [
        (
            "call_time_secs 120",
            "call_time_secs set to 120; takes effect from Max's next program or command",
        ),
        (
            "call_time_secs 5",
            "error: call_time_secs takes a number from 10 to 600, or default",
        ),
        (
            "call_time_secs soon",
            "error: call_time_secs takes a number from 10 to 600, or default",
        ),
        (
            "job_time_secs 60",
            "error: no such setting; there are idle_window_secs, call_time_secs",
        ),
        (
            "idle_window_secs 1800",
            "idle_window_secs set to 1800; takes effect now",
        ),
        ("call_time_secs", "call_time_secs    120 (default 60)"),
    ] {
        config(&h, argument);
        assert_eq!(
            h.said().await.1,
            command::answer("config", answer),
            "{argument}"
        );
    }
    h.send(from_xiaoming(9, vec![me(), text("/status")]));
    let status = h.said().await.1;
    assert!(
        status.contains("\nconfig    idle_window_secs 1800 · call_time_secs 120\n"),
        "{status}"
    );
    config(&h, "idle_window_secs default");
    assert_eq!(
        h.said().await.1,
        command::answer(
            "config",
            "idle_window_secs back to the default, 300; takes effect now"
        )
    );
    h.stop().await;
    assert_eq!(h.script.calls(), 0);
    let saved = h
        .count("select (overrides->>'call_time_secs')::bigint from conversation_settings")
        .await;
    assert_eq!(saved, 120);
    let idle = h
        .count("select count(overrides->'idle_window_secs') from conversation_settings")
        .await;
    assert_eq!(idle, 0);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_program_call_ends_at_the_conversations_call_time(pool: PgPool) {
    let mut h = Harness::start(pool, Group, 300, false, true, None, |actor| {
        actor.settings.overrides.set(Setting::CallTimeSecs, Some(1));
    })
    .await;
    let (reply, result) = oneshot::channel();
    let call = Event::Call {
        tool: "say".into(),
        args: serde_json::json!({ "text": "早" }),
        reply,
    };
    h.mailbox.send(call).unwrap();
    // The sender holds the receipt, so the `say` waits on it.
    let _held = tokio::time::timeout(PATIENCE, h.outbound.recv())
        .await
        .unwrap()
        .unwrap();
    let failed = tokio::time::timeout(PATIENCE, result)
        .await
        .expect("the call went on")
        .unwrap()
        .unwrap_err();
    assert_eq!(failed.code, "timeout");
    assert!(
        failed.message.starts_with("not done in 1 seconds"),
        "{}",
        failed.message
    );
    h.stop().await;
}

/// What Max in conversation 7 asks Max here, and where its answer goes.
fn question(text: &str) -> (Event, oneshot::Receiver<Result<String, String>>) {
    let (answer, answered) = oneshot::channel();
    let question = Question {
        from: Peer {
            conversation: ConversationId(7),
            title: Some("hank".into()),
        },
        text: text.to_owned(),
        answer,
    };
    (Event::Asked(question), answered)
}

/// Max calls `answer` for question `to`.
async fn answer(h: &Harness, to: u32, text: &str) -> Result<String, String> {
    h.poster().answer(to, text.to_owned()).await
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_new_core_is_shown_the_questions_still_waiting(pool: PgPool) {
    // An idle window too short to outlast the question.
    let mut h = Harness::unprompted(pool, 1).await;
    h.send(from_xiaoming(0, vec![text("明天有活动")]));
    h.script.push(Answer::says("谁知道明天几点开始？"));
    let (asked, answered) = question("明天的活动\n几点开始？");
    h.mailbox.send(asked).unwrap();
    assert_eq!(h.said().await.1, "谁知道明天几点开始？");
    let deadline = std::time::Instant::now() + PATIENCE;
    while h.turns().await.first().is_none_or(|turn| turn.1.is_none()) {
        assert!(std::time::Instant::now() < deadline, "the core didn't end");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    // Someone here knows; the core that hears them never saw the question.
    h.script.push(Answer::says("好，我告诉它"));
    h.send(from_xiaohong(1, vec![me(), text("八点")]));
    assert_eq!(h.said().await.1, "好，我告诉它");
    let shown = h.request_tail(1);
    let waiting = "\n\n[等你回答的问题]\nask#1 c#7 hank：明天的活动 ⏎ 几点开始？\n\n[新消息]\n";
    assert!(shown.contains(waiting), "{shown}");
    assert_eq!(answer(&h, 1, "八点").await, Ok("c#7 hank".to_owned()));
    assert_eq!(answered.await.unwrap(), Ok("八点".to_owned()));
    h.stop().await;
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
