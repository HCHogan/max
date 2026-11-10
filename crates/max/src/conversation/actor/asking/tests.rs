//! Two actors against the real database: 小明's private chat and the
//! group, each with a row to start from, with a scripted model and a
//! sender that only queues. A task plays the conversation table's part and
//! hands a question to the actor it is for.

use std::time::Duration;

use chrono::Utc;
use max_core::item::ItemKind;
use max_core::message::Content;
use max_db::PgPool;
use tokio::sync::mpsc::{self, UnboundedReceiver};

use super::*;
use crate::conversation::testing::{
    from_xiaohong, from_xiaoming, group, offset, private, privately, shared, text,
};
use crate::inbound::InNode;
use crate::job::{Reply, Request};
use crate::llm::testing::{Answer, Script};

const PATIENCE: Duration = Duration::from_secs(5);

struct Pair {
    pool: PgPool,
    script: Arc<Script>,
    chat: Arc<Place>,
    room: Arc<Place>,
    mailboxes: HashMap<ConversationId, UnboundedSender<Event>>,
    outbound: UnboundedReceiver<Outgoing>,
    _scope: Scope,
}

impl Pair {
    async fn new(pool: PgPool) -> Self {
        let mut conn = pool.acquire().await.unwrap();
        let chat = Arc::new(private(&mut conn).await);
        let room = Arc::new(group(&mut conn).await);
        // As a conversation with an edge has: the /link that made it.
        let said = from_xiaoming(0, vec![text("明天有活动")]);
        for (place, said) in [(&chat, privately(said.clone())), (&room, said)] {
            ingest::inbound(&mut conn, place, said, Utc::now(), offset())
                .await
                .unwrap();
        }
        drop(conn);
        let script = Arc::new(Script::default());
        let (mut shared, outbound) = shared(&pool, &script, 300, BTreeSet::new());
        let (signals, mut heard) = mpsc::unbounded_channel();
        shared.signals = signals;
        let shared = Arc::new(shared);
        let mut scope = Scope::new();
        let mut mailboxes = HashMap::new();
        for place in [&chat, &room] {
            let (mailbox, rx) = mpsc::unbounded_channel();
            let actor = Conversation::new(Arc::clone(&shared), Arc::clone(place), mailbox.clone())
                .await
                .unwrap();
            scope.spawn(move |_| async move {
                actor.run(rx).await.unwrap();
            });
            mailboxes.insert(place.conversation, mailbox);
        }
        let routes = mailboxes.clone();
        scope.spawn(move |_| async move {
            while let Some(signal) = heard.recv().await {
                let Signal::Ask {
                    conversation,
                    question,
                } = signal
                else {
                    panic!("{signal:?}");
                };
                match routes.get(&conversation) {
                    Some(mailbox) => mailbox.send(Event::Asked(question)).unwrap(),
                    None => question.refuse("Max 已经不在那个会话的聊天里了"),
                }
            }
        });
        Self {
            pool,
            script,
            chat,
            room,
            mailboxes,
            outbound,
            _scope: scope,
        }
    }

    /// Lets Max in `asker` ask Max in `asked`.
    async fn link(&self, asker: &Place, asked: &Place) {
        let mut conn = self.pool.acquire().await.unwrap();
        links::link(
            &mut conn,
            asker.conversation,
            asked.conversation,
            Utc::now(),
        )
        .await
        .unwrap();
    }

    /// Max in `place` calls `ask`.
    async fn ask(&self, place: &Place, to: ConversationId, question: &str) -> Result<u32, String> {
        let (reply, asked) = oneshot::channel();
        let ask = Event::Ask {
            to,
            question: question.to_owned(),
            origin: None,
            reply,
        };
        self.mailboxes[&place.conversation].send(ask).unwrap();
        tokio::time::timeout(PATIENCE, asked)
            .await
            .unwrap()
            .unwrap()
    }

    /// Max in `place` calls `answer`.
    async fn answer(&self, place: &Place, to: u32, text: &str) -> Result<String, String> {
        let (reply, taken) = oneshot::channel();
        let answer = Event::Answer {
            to,
            text: text.to_owned(),
            origin: None,
            reply,
        };
        self.mailboxes[&place.conversation].send(answer).unwrap();
        tokio::time::timeout(PATIENCE, taken)
            .await
            .unwrap()
            .unwrap()
    }

    async fn jobs(&self, place: &Place, request: Request) -> Result<Reply, String> {
        let (reply, answer) = oneshot::channel();
        let jobs = Event::Jobs {
            request,
            origin: None,
            reply,
        };
        self.mailboxes[&place.conversation].send(jobs).unwrap();
        tokio::time::timeout(PATIENCE, answer)
            .await
            .unwrap()
            .unwrap()
    }

    /// The next thing said: where, and its text.
    async fn said(&mut self) -> (ConversationId, String) {
        let outgoing = tokio::time::timeout(PATIENCE, self.outbound.recv())
            .await
            .expect("nothing was said")
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
        (outgoing.place.conversation, text)
    }

    /// What Max says in `place`.
    async fn says(&mut self, place: &Place, words: &str) {
        let (conversation, text) = self.said().await;
        assert_eq!((conversation, text.as_str()), (place.conversation, words));
    }

    /// Nothing more is said for a moment.
    async fn quiet(&mut self) {
        let more = tokio::time::timeout(Duration::from_millis(300), self.outbound.recv()).await;
        assert!(more.is_err(), "{more:?}");
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
        sqlx::query_scalar(query)
            .fetch_one(&self.pool)
            .await
            .unwrap()
    }
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_question_and_its_answer_reach_the_two_maxes_and_no_chat(pool: PgPool) {
    let mut p = Pair::new(pool).await;
    let (chat, room) = (Arc::clone(&p.chat), Arc::clone(&p.room));
    let (c, r) = (chat.conversation, room.conversation);
    p.link(&chat, &room).await;

    // Max in the private chat asks Max in the group, which wakes for it.
    p.script.push(Answer::says("我问问大家"));
    let asked = p.ask(&chat, r, " 明天的活动几点开始？\n").await;
    assert_eq!(asked, Ok(1));
    p.says(&room, "我问问大家").await;
    let shown = p.request_tail(0);
    let put =
        format!("[新消息]\n[ask#1 问] c#{c}\n明天的活动几点开始？\n（那个会话的 Max 在等你回答：");
    assert!(shown.contains(&put), "{shown}");
    // The group may ask nobody, and is told of no list; and the question
    // that woke it is shown once, not listed as one from before.
    assert!(!shown.contains("[能问的会话]"), "{shown}");
    assert!(!shown.contains("[等你回答的问题]"), "{shown}");
    let waiting = p.jobs(&chat, Request::Status { job: None }).await.unwrap();
    let Reply::Running(jobs) = waiting else {
        panic!("{waiting:?}");
    };
    let title = format!("? c#{r}: 明天的活动几点开始？");
    assert_eq!(
        (jobs[0].job.as_str(), jobs[0].title.as_str()),
        ("job#1", title.as_str())
    );

    // The answer names the question; it wakes Max in the private chat,
    // whose new core is told what it had asked.
    p.script.push(Answer::says("群里说晚上八点"));
    let answered = p.answer(&room, 1, "晚上八点\n").await;
    assert_eq!(answered, Ok(format!("c#{c}")));
    p.says(&chat, "群里说晚上八点").await;
    let shown = p.request_tail(1);
    let heard = format!("[job#1 回答] c#{r}\n问：明天的活动几点开始？\n答：晚上八点\n");
    assert!(shown.ends_with(&heard), "{shown}");
    // Whom it may ask comes after its people.
    let askable = format!("\n\n[能问的会话]\nc#{r}\n\n[新消息]\n");
    assert!(shown.contains(&askable), "{shown}");
    let waiting = p.jobs(&chat, Request::Status { job: None }).await.unwrap();
    assert_eq!(waiting, Reply::Running(Vec::new()));

    // Answered, nobody waits on it any more.
    let again = p.answer(&room, 1, "九点").await.unwrap_err();
    assert!(again.contains("没有人在等 ask#1"), "{again}");
    p.quiet().await;

    // The group's core still runs: the next question is new input to it.
    p.script.push(Answer::says("这个我知道"));
    assert_eq!(p.ask(&chat, r, "在哪办？").await, Ok(2));
    p.says(&room, "这个我知道").await;
    let fed = p.request_tail(2);
    let put = format!("[新消息]\n[ask#2 问] c#{c}\n在哪办？\n");
    assert!(fed.starts_with(&put), "{fed}");
    let turns = "select count(*) from turns t join conversations c on c.id = t.conversation_id where c.kind = 'group'";
    assert_eq!(p.count(turns).await, 1, "one core took both questions");
    // Nothing of it is a row: maxx said nothing in either chat.
    let lines = "select count(*) from messages where raw ->> 'said_by' = 'host'";
    assert_eq!(p.count(lines).await, 0);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_question_goes_only_along_an_edge(pool: PgPool) {
    let mut p = Pair::new(pool).await;
    let (chat, room) = (Arc::clone(&p.chat), Arc::clone(&p.room));
    let c = chat.conversation;
    p.link(&chat, &room).await;

    // The edge runs one way; no edge, no such conversation and itself
    // are refused alike, and nobody is woken.
    for (asker, to) in [(&room, c), (&chat, ConversationId(999)), (&chat, c)] {
        let refused = p.ask(asker, to, "在吗").await.unwrap_err();
        let alike = format!("问不了 c#{to}：这里没有连到它，或者没有这个会话。");
        assert!(refused.starts_with(&alike), "{refused}");
    }
    p.quiet().await;
    assert_eq!(p.script.calls(), 0);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_question_that_gets_no_answer_says_why(pool: PgPool) {
    let mut p = Pair::new(pool).await;
    let (chat, room) = (Arc::clone(&p.chat), Arc::clone(&p.room));
    let (c, r) = (chat.conversation, room.conversation);
    p.link(&chat, &room).await;

    // Withdrawn, the answer finds nobody, and neither side hears more.
    p.script.push(Answer::says("等我想想"));
    assert_eq!(p.ask(&chat, r, "有空吗").await, Ok(1));
    p.says(&room, "等我想想").await;
    let steered = Request::Steer {
        job: 1,
        message: "快点".into(),
    };
    let not_an_agent = p.jobs(&chat, steered).await.unwrap_err();
    assert!(not_an_agent.contains("补不了话"), "{not_an_agent}");
    assert_eq!(
        p.jobs(&chat, Request::Cancel { job: 1 }).await,
        Ok(Reply::Job(1))
    );
    let late = p.answer(&room, 1, "有").await.unwrap_err();
    assert!(late.contains("没有人在等 ask#1"), "{late}");
    p.quiet().await;

    // A conversation Max serves no chat of: the group's core, still
    // running, reads why as new input.
    let unknown = ConversationId(999);
    let mut conn = p.pool.acquire().await.unwrap();
    sqlx::query("insert into conversations (id, kind) values ($1, 'group')")
        .bind(unknown.0)
        .execute(&mut *conn)
        .await
        .unwrap();
    links::link(&mut conn, r, unknown, Utc::now())
        .await
        .unwrap();
    drop(conn);
    p.script.push(Answer::says("那算了"));
    assert_eq!(p.ask(&room, unknown, "有人吗").await, Ok(1));
    p.says(&room, "那算了").await;
    let unserved = "[新消息]\n[job#1 没答成] c#999：Max 已经不在那个会话的聊天里了\n问：有人吗";
    assert_eq!(p.request_tail(1), unserved);

    // /stop there ends the wait of a question not yet answered.
    p.script.push(Answer::says("稍等"));
    assert_eq!(p.ask(&chat, r, "还在吗").await, Ok(2));
    p.says(&room, "稍等").await;
    p.script.push(Answer::says("好吧"));
    let me = InNode::MentionMe {
        display: "maxx".into(),
    };
    let stop = Event::Inbound(from_xiaohong(1, vec![me, text("/stop")]));
    p.mailboxes[&r].send(stop).unwrap();
    let mut heard = vec![p.said().await, p.said().await];
    heard.sort();
    let stopped = "stopped: messages are still recorded, but Max won't reply until @maxx /start";
    let mut expected = [
        (r, command::answer("stop", stopped)),
        (c, "好吧".to_owned()),
    ];
    expected.sort();
    assert_eq!(heard, expected);
    let unanswered = format!("[job#2 没答成] c#{r}：那边被 /stop 停了，Max 不回话\n问：还在吗\n");
    let shown = p.request_tail(3);
    assert!(shown.ends_with(&unanswered), "{shown}");

    // Stopped, Max there isn't told of a question, and the asker hears
    // why at once.
    p.script.push(Answer::says("嗯"));
    assert_eq!(p.ask(&chat, r, "真的不在？").await, Ok(3));
    p.says(&chat, "嗯").await;
    let again =
        format!("[新消息]\n[job#3 没答成] c#{r}：那边被 /stop 停了，Max 不回话\n问：真的不在？");
    assert_eq!(p.request_tail(4), again);
    p.quiet().await;
}
