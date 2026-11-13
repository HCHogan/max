//! The table against the real database, with actors that answer commands
//! and a sender that only queues. Time is real, as in the actor's tests.

use std::collections::BTreeSet;

use max_core::ids::MessageId;
use max_core::item::ItemKind;
use max_core::message::{Content, Node, Role};
use max_db::links::Peer;
use qqbot::api::{GroupInfo, Mute, Muted};
use tokio::sync::oneshot;

use super::*;
use crate::command;
use crate::conversation::testing::{self, from_xiaoming, offset, shared, text};
use crate::conversation::{Heard, Outgoing, Question, ingest};
use crate::inbound::{Chat, InNode, Person};
use crate::llm::testing::{Answer, Script};
use crate::mcp::Services;
use crate::qq::groups::Groups;

const PATIENCE: Duration = Duration::from_secs(5);

struct Setup {
    pool: PgPool,
    inbound: Option<UnboundedSender<Inbound>>,
    signals: UnboundedSender<Signal>,
    outbound: UnboundedReceiver<Outgoing>,
    done: Option<oneshot::Receiver<()>>,
    owner: Account,
    script: Arc<Script>,
    _scope: Scope,
}

impl Setup {
    /// Max on QQ, owned by the person who writes from the private chat
    /// `c2c:OWNER`.
    async fn new(pool: PgPool) -> Self {
        Self::with_qq(pool, None).await
    }

    /// With `qq` to ask what a group is called.
    async fn with_qq(pool: PgPool, qq: Option<Arc<dyn Groups>>) -> Self {
        let mut conn = pool.acquire().await.unwrap();
        let account = platform::account(&mut conn, Platform::Qq, "BOT", "maxx")
            .await
            .unwrap();
        let owner = platform::account(&mut conn, Platform::Qq, "OWNER", "hank")
            .await
            .unwrap();
        drop(conn);
        let script = Arc::new(Script::default());
        let (mut shared, outbound) = shared(&pool, &script, 300, BTreeSet::from([owner.principal]));
        shared.services = Arc::new(Services {
            groups: qq,
            ..Services::bare(pool.clone())
        });
        // As in main: the actors' questions and the VMs' signals come to
        // the table on one channel.
        let (signals, signals_rx) = mpsc::unbounded_channel();
        shared.signals = signals.clone();
        let me = Me {
            account,
            name: "maxx".into(),
        };
        let table = Table::new(Arc::new(shared), HashMap::from([(Platform::Qq, me)]));
        let (inbound, rx) = mpsc::unbounded_channel();
        let (done_tx, done) = oneshot::channel();
        let mut scope = Scope::new();
        scope.spawn(move |_| async move {
            table.run(rx, signals_rx, Duration::from_secs(2)).await;
            let _ = done_tx.send(());
        });
        Self {
            pool,
            inbound: Some(inbound),
            signals,
            outbound,
            done: Some(done),
            owner,
            script,
            _scope: scope,
        }
    }

    fn send(&self, inbound: Inbound) {
        self.inbound.as_ref().unwrap().send(inbound).unwrap();
    }

    /// The next thing Max says: where, and its text.
    async fn said(&mut self) -> (String, String) {
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
        (outgoing.place.native_id.clone(), text)
    }

    /// Asks for a code in the owner's private chat.
    async fn code(&mut self, n: u32, command: &str) -> String {
        self.send(private(n, command));
        let (chat, said) = self.said().await;
        assert_eq!(chat, "c2c:OWNER");
        let code: String = said.chars().filter(char::is_ascii_digit).take(6).collect();
        assert_eq!(code.len(), 6, "{said}");
        code
    }

    async fn stop(&mut self) {
        self.inbound = None;
        let done = self.done.take().unwrap();
        tokio::time::timeout(PATIENCE, done)
            .await
            .expect("the table didn't stop")
            .unwrap();
    }

    /// The last item of the n-th request: what was new to the model.
    fn request_tail(&self, n: usize) -> String {
        let requests = self.script.requests.lock().unwrap();
        match &requests[n].items.last().unwrap().kind {
            ItemKind::User { text, .. } => text.clone(),
            other => panic!("{other:?}"),
        }
    }

    async fn count(&self, query: &'static str) -> i64 {
        let mut conn = self.pool.acquire().await.unwrap();
        sqlx::query_scalar(query)
            .fetch_one(&mut *conn)
            .await
            .unwrap()
    }

    /// The conversation of a chat.
    async fn conversation(&self, native_id: &str) -> i64 {
        sqlx::query_scalar("select conversation_id from endpoints where native_id = $1")
            .bind(native_id)
            .fetch_one(&self.pool)
            .await
            .unwrap()
    }
}

/// QQ, asked only what GROUP1 is called.
struct Named(&'static str);

impl Groups for Named {
    fn muted<'a>(&'a self, _: &'a str) -> crate::qq::send::Answer<'a, Vec<Muted>> {
        unreachable!("nobody is muted here")
    }

    fn mute<'a>(&'a self, _: &'a str, _: &'a Mute<'a>) -> crate::qq::send::Answer<'a, ()> {
        unreachable!("nobody is muted here")
    }

    fn info<'a>(&'a self, group: &'a str) -> crate::qq::send::Answer<'a, GroupInfo> {
        Box::pin(async move {
            assert_eq!(group, "GROUP1");
            Ok(GroupInfo {
                group_name: self.0.to_owned(),
                group_finger_memo: String::new(),
                group_member_num: 3,
            })
        })
    }
}

/// The owner writes to Max in private.
fn private(n: u32, said: &str) -> Inbound {
    let mut inbound = from_xiaoming(n, vec![text(said)]);
    inbound.chat = Chat {
        native_id: "c2c:OWNER".into(),
        kind: ConversationKind::Direct,
    };
    inbound.native_id = format!("C2C{n}");
    inbound.sender = Person {
        native_user_id: "OWNER".into(),
        name: "hank".into(),
        role: None,
    };
    inbound
}

/// The owner says something to Max in the group, where QQ knows them by
/// another openid.
fn owner_in_group(n: u32, said: &str) -> Inbound {
    let me = InNode::MentionMe {
        display: "maxx".into(),
    };
    let mut inbound = from_xiaoming(n, vec![me, text(said)]);
    inbound.sender = Person {
        native_user_id: "OWNERMEMBER".into(),
        name: "hank".into(),
        role: Some(Role::Owner),
    };
    inbound
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_group_is_served_once_bound(pool: PgPool) {
    let mut s = Setup::new(pool).await;
    s.send(from_xiaoming(0, vec![text("有人吗")]));
    let code = s.code(1, "/bind").await;
    s.send(owner_in_group(2, "/bind 000000"));
    // Not to Max: another bot's, perhaps.
    let mut bare = owner_in_group(5, &format!("/bind {code}"));
    bare.nodes.remove(0);
    s.send(bare);
    s.send(owner_in_group(3, &format!("/bind {code}")));
    let bound = (
        "group:GROUP1".to_owned(),
        command::answer("bound: the history starts here"),
    );
    assert_eq!(s.said().await, bound);
    // Only an owner may run /bind: the account here is the owner's now.
    s.send(owner_in_group(4, &format!("/bind {code}")));
    assert_eq!(
        s.said().await.1,
        command::answer("error: this group is bound already, and can't be bound again")
    );
    let mut conn = s.pool.acquire().await.unwrap();
    let member = platform::account(&mut conn, Platform::Qq, "OWNERMEMBER", "hank")
        .await
        .unwrap();
    assert_eq!(member.principal, s.owner.principal);
    drop(conn);
    let kept = "select count(*) from messages where native_id in ('MSG0', 'MSG2', 'MSG3', 'MSG5')";
    assert_eq!(s.count(kept).await, 1, "only the /bind that bound");
    s.stop().await;
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_group_goes_on_from_an_old_one(pool: PgPool) {
    let mut s = Setup::new(pool).await;
    let mut conn = s.pool.acquire().await.unwrap();
    let old_max = platform::account(&mut conn, Platform::QqLegacy, "20000", "Max")
        .await
        .unwrap();
    let group = ConversationKind::Group;
    let old = platform::endpoint(
        &mut conn,
        Platform::QqLegacy,
        "group:30001",
        old_max.identity,
        group,
        None,
    )
    .await
    .unwrap();
    let old_place = Place {
        conversation: old.conversation,
        kind: group,
        endpoint: old.id,
        platform: Platform::QqLegacy,
        native_id: "group:30001".into(),
        me: old_max,
        my_name: "Max".into(),
    };
    let mut said_before = from_xiaoming(0, vec![text("老群里的话")]);
    said_before.platform = Platform::QqLegacy;
    said_before.native_id = "OLD0".into();
    ingest::inbound(&mut conn, &old_place, said_before, Utc::now(), offset())
        .await
        .unwrap();
    drop(conn);

    s.send(private(1, "/bind 30002"));
    assert_eq!(
        s.said().await.1,
        command::answer("error: no history of old group 30002")
    );
    let code = s.code(2, "/bind 30001").await;
    let again = s.code(3, "/bind 30001").await;
    s.send(owner_in_group(4, &format!("/bind {code}")));
    assert_eq!(
        s.said().await.1,
        command::answer("bound: the old group's history goes on here")
    );
    let mut conn = s.pool.acquire().await.unwrap();
    let bound = platform::endpoint_on(&mut conn, old.conversation, Platform::Qq)
        .await
        .unwrap();
    assert_eq!(bound.as_deref(), Some("group:GROUP1"));
    let rows: i64 = sqlx::query_scalar("select count(*) from messages where conversation_id = $1")
        .bind(old.conversation.0)
        .fetch_one(&mut *conn)
        .await
        .unwrap();
    assert_eq!(rows, 3, "the old row, then the /bind and its answer");
    drop(conn);

    s.send(private(5, "/bind 30001"));
    assert_eq!(
        s.said().await.1,
        command::answer("error: old group 30001's history goes on in another group already")
    );
    let mut elsewhere = owner_in_group(6, &format!("/bind {again}"));
    elsewhere.chat.native_id = "group:GROUP2".into();
    s.send(elsewhere);
    s.send(private(7, "/status"));
    assert_eq!(s.said().await.0, "c2c:OWNER", "GROUP2 got no answer");
    let endpoints = "select count(*) from endpoints where native_id = 'group:GROUP2'";
    assert_eq!(s.count(endpoints).await, 0);
    s.stop().await;
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn an_owner_links_two_conversations_one_way(pool: PgPool) {
    let mut s = Setup::with_qq(pool, Some(Arc::new(Named("示波器同好会")))).await;
    let code = s.code(0, "/bind").await;
    s.send(owner_in_group(1, &format!("/bind {code}")));
    s.said().await;
    let chat = s.conversation("c2c:OWNER").await;
    let group = s.conversation("group:GROUP1").await;
    let answer = |body: &str| command::answer(body);

    // Not for the group's own people, its owner and admins among them.
    let me = InNode::MentionMe {
        display: "maxx".into(),
    };
    s.send(from_xiaoming(2, vec![me, text("/link")]));
    assert_eq!(s.said().await.1, answer("refused: Max's owners only"));

    // Max in the private chat is to ask Max in the group.
    let code = s.code(3, "/link").await;
    // Said where it was issued, the code isn't used up.
    s.send(private(4, &format!("/link {code}")));
    let here = "error: that code was issued here; send it in the conversation Max here is to ask";
    assert_eq!(s.said().await.1, answer(here));
    s.send(owner_in_group(5, &format!("/link {code}")));
    let linked = format!(
        "linked: Max in c#{chat} hank may ask Max here now, and not the other way\n\
         @maxx /unlink c#{chat} removes it"
    );
    assert_eq!(s.said().await, ("group:GROUP1".into(), answer(&linked)));
    s.send(owner_in_group(6, &format!("/link {code}")));
    let gone = "error: no such code, or it has run out";
    assert_eq!(s.said().await.1, answer(gone));
    let code = s.code(7, "/link").await;
    s.send(owner_in_group(8, &format!("/link {code}")));
    let already = format!("skipped: Max in c#{chat} hank may ask Max here already");
    assert_eq!(s.said().await.1, answer(&already));
    let edges: Vec<(i64, i64)> = sqlx::query_as("select asker_id, asked_id from links")
        .fetch_all(&s.pool)
        .await
        .unwrap();
    assert_eq!(edges, [(chat, group)]);

    // The group asked QQ what it is called when its actor started.
    let deadline = std::time::Instant::now() + PATIENCE;
    let titled = "select count(*) from conversations where title = '示波器同好会'";
    while s.count(titled).await == 0 {
        assert!(std::time::Instant::now() < deadline, "no title");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    s.send(private(9, "/status"));
    let status = s.said().await.1;
    // `/status` names them by number alone.
    let may_ask = format!("\nmay ask   c#{group}\n");
    assert!(status.contains(&may_ask), "{status}");
    assert!(!status.contains("asked by"), "{status}");
    s.send(owner_in_group(10, "/status"));
    let status = s.said().await.1;
    let asked_by = format!("\nasked by  c#{chat}\n");
    assert!(status.contains(&asked_by), "{status}");
    assert!(!status.contains("may ask"), "{status}");

    // Either side cuts it.
    let answer = |body: &str| command::answer(body);
    s.send(owner_in_group(11, "/unlink"));
    let which = "error: say which conversation, as @maxx /unlink c#N; @maxx /status lists them";
    assert_eq!(s.said().await.1, answer(which));
    s.send(private(12, &format!("/unlink c#{group}")));
    let unlinked = format!(
        "unlinked: Max here and Max in c#{group} 示波器同好会 can't ask each other any more"
    );
    assert_eq!(s.said().await.1, answer(&unlinked));
    s.send(owner_in_group(13, &format!("/unlink c#{chat}")));
    let none = format!("skipped: no link with c#{chat}");
    assert_eq!(s.said().await.1, answer(&none));
    assert_eq!(s.count("select count(*) from links").await, 0);
    s.stop().await;
    assert_eq!(s.script.calls(), 0);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_conversation_that_stopped_on_an_error_starts_again(pool: PgPool) {
    let mut s = Setup::new(pool).await;
    s.script.push(Answer::Hangs);
    s.send(private(1, "在吗"));
    let deadline = std::time::Instant::now() + PATIENCE;
    while s.script.calls() == 0 {
        assert!(std::time::Instant::now() < deadline, "no model call");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    // Postgres refuses C2C2 alone: the actor stops on it.
    sqlx::raw_sql(
        "create function refuse() returns trigger language plpgsql
           as $$ begin raise exception 'refused'; end $$;
         create trigger refuse before insert on messages
           for each row when (new.native_id = 'C2C2') execute function refuse();",
    )
    .execute(&s.pool)
    .await
    .unwrap();
    s.send(private(2, "嗯"));
    let said = s.said().await;
    let failed = "```text\nerror: the conversation failed: error returned from database: refused";
    assert_eq!(said.0, "c2c:OWNER");
    assert!(said.1.starts_with(failed), "{}", said.1);
    assert_eq!(
        said.1.matches("refused").count(),
        1,
        "the cause once: {}",
        said.1
    );
    let lost = "select count(*) from turn_outcomes where outcome = 'lost'";
    assert_eq!(s.count(lost).await, 1);
    // It is gone right after; a message it took while going would be lost.
    tokio::time::sleep(Duration::from_millis(200)).await;
    s.code(3, "/bind").await;
    s.stop().await;
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_program_in_the_vm_wakes_a_group_nobody_has_written_in(pool: PgPool) {
    let mut s = Setup::new(pool).await;
    // The group was bound, and talked in, before max started.
    let mut conn = s.pool.acquire().await.unwrap();
    let place = testing::group(&mut conn).await;
    let said = from_xiaoming(0, vec![text("CI 跑完叫我")]);
    ingest::inbound(&mut conn, &place, said, Utc::now(), offset())
        .await
        .unwrap();
    drop(conn);
    s.script.push(Answer::says("CI 挂了两个"));
    let (reply, answered) = oneshot::channel();
    let wake = Signal::Call {
        conversation: place.conversation,
        tool: "wake".into(),
        args: serde_json::json!({ "text": "CI 跑完了：2 failed" }),
        reply,
    };
    s.signals.send(wake).unwrap();
    let answered = tokio::time::timeout(PATIENCE, answered).await.unwrap();
    assert_eq!(
        answered.unwrap(),
        Ok(serde_json::json!({ "said": "woke Max" }))
    );
    assert_eq!(
        s.said().await,
        ("group:GROUP1".into(), "CI 挂了两个".into())
    );
    let shown = s.request_tail(0);
    assert!(shown.contains("[max-wake] CI 跑完了：2 failed"), "{shown}");
    // To the actor the wake started.
    let notice = Signal::Heard {
        conversation: place.conversation,
        heard: Heard::Vm("VM 没开起来".into()),
    };
    s.script.push(Answer::says("VM 出问题了，我去看看"));
    s.signals.send(notice).unwrap();
    assert_eq!(s.said().await.1, "VM 出问题了，我去看看");
    let shown = s.request_tail(1);
    assert!(shown.contains("[VM] VM 没开起来"), "{shown}");
    // And a program following the timeline, from what was said last.
    let head: i64 = sqlx::query_scalar("select max(id) from messages")
        .fetch_one(&s.pool)
        .await
        .unwrap();
    let (reply, subscribed) = oneshot::channel();
    let subscribe = Signal::Subscribe {
        conversation: place.conversation,
        reply,
    };
    s.signals.send(subscribe).unwrap();
    let subscription = tokio::time::timeout(PATIENCE, subscribed).await.unwrap();
    assert_eq!(subscription.unwrap().head, MessageId(head));
    s.stop().await;
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_question_starts_the_conversation_it_is_for(pool: PgPool) {
    let mut s = Setup::new(pool).await;
    // The group was bound, and talked in, before max started.
    let mut conn = s.pool.acquire().await.unwrap();
    let place = testing::group(&mut conn).await;
    let said = from_xiaoming(0, vec![text("明天有活动")]);
    ingest::inbound(&mut conn, &place, said, Utc::now(), offset())
        .await
        .unwrap();
    drop(conn);
    let peer = |conversation, title: Option<&str>| Peer {
        conversation,
        title: title.map(str::to_owned),
    };
    let ask = |from: Peer, to: Peer| Signal::Heard {
        conversation: to.conversation,
        heard: Heard::Asked(Question {
            from,
            to,
            text: "几点开始？".into(),
        }),
    };
    let here = peer(place.conversation, None);
    s.script.push(Answer::says("我看看"));
    s.signals
        .send(ask(peer(ConversationId(7), Some("hank")), here.clone()))
        .unwrap();
    // Only what Max says is said: the question is its to read.
    assert_eq!(s.said().await, ("group:GROUP1".into(), "我看看".into()));
    let shown = s.request_tail(0);
    assert!(
        shown.contains("[ask#1 问] c#7 hank\n几点开始？\n"),
        "{shown}"
    );

    // Max serves no chat of the one it asks next: it hears so at once,
    // as an answer comes, through the table.
    s.script.push(Answer::says("那边问不了"));
    s.signals
        .send(ask(here, peer(ConversationId(999), Some("别处"))))
        .unwrap();
    assert_eq!(s.said().await.1, "那边问不了");
    let shown = s.request_tail(1);
    let unanswered = "[没答成] c#999 别处：Max serves no chat of that conversation\n问：几点开始？";
    assert!(shown.contains(unanswered), "{shown}");
    s.stop().await;
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_turn_running_in_a_crash_is_lost(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = testing::group(&mut conn).await;
    let said = from_xiaoming(0, vec![text("在吗")]);
    let committed = ingest::inbound(&mut conn, &place, said, Utc::now(), offset())
        .await
        .unwrap();
    let from = committed.message.id;
    let started = turns::start(&mut conn, place.conversation, &[], from, Utc::now())
        .await
        .unwrap();
    drop(conn);
    close_unfinished(&pool).await.unwrap();
    let mut conn = pool.acquire().await.unwrap();
    let outcome = turns::outcome(&mut conn, started.turn).await.unwrap();
    assert_eq!(outcome, Some(Outcome::Lost));
}
