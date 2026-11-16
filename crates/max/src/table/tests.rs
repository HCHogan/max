//! The table against the real database, with actors that answer commands
//! and a sender that only queues. Time is real, as in the actor's tests.

use std::collections::BTreeSet;

use max_core::message::{Content, Node, Role};
use tokio::sync::oneshot;

use super::*;
use crate::command;
use crate::conversation::testing::{self, from_xiaoming, offset, shared, text};
use crate::conversation::{Outgoing, ingest};
use crate::inbound::{Chat, InNode, Person};
use crate::llm::testing::Script;

const PATIENCE: Duration = Duration::from_secs(5);

struct Setup {
    pool: PgPool,
    inbound: Option<UnboundedSender<Inbound>>,
    outbound: UnboundedReceiver<Outgoing>,
    done: Option<oneshot::Receiver<()>>,
    owner: Account,
    _scope: Scope,
}

impl Setup {
    /// Max on QQ, owned by the person who writes from the private chat
    /// `c2c:OWNER`.
    async fn new(pool: PgPool) -> Self {
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
        // As in main: the actors' questions and the VMs' signals come to
        // the table on one channel.
        let (signals, signals_rx) = mpsc::unbounded_channel();
        shared.signals = signals;
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
            outbound,
            done: Some(done),
            owner,
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

    async fn count(&self, query: &'static str) -> i64 {
        let mut conn = self.pool.acquire().await.unwrap();
        sqlx::query_scalar(query)
            .fetch_one(&mut *conn)
            .await
            .unwrap()
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
