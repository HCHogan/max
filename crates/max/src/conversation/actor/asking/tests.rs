//! Two actors against the real database: 小明's private chat and the
//! group, with a scripted model and a sender that only queues. A task
//! plays the conversation table's part and hands a question to the actor
//! it is for.

use std::time::Duration;

use chrono::Utc;
use max_core::item::ItemKind;
use max_core::message::Content;
use max_db::PgPool;
use tokio::sync::mpsc::{self, UnboundedReceiver};

use super::*;
use crate::conversation::testing::{from_xiaohong, group, private, shared, text};
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
                    None => question.refuse("Max serves no chat of that conversation"),
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
    async fn answer(&self, place: &Place, to: MessageId, text: &str) -> Result<String, String> {
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

    /// The next thing Max's account says: where, the row, and its text.
    async fn said(&mut self) -> (ConversationId, Arc<Message>, String) {
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
        (outgoing.place.conversation, outgoing.message, text)
    }

    /// A line maxx says in `place`: the row, which quotes `quoting`.
    async fn line(&mut self, place: &Place, body: &str, quoting: Option<MessageId>) -> MessageId {
        let (conversation, message, text) = self.said().await;
        assert_eq!(text, command::fenced("text", body));
        assert_eq!(conversation, place.conversation, "{text}");
        assert_eq!(ingest::by(&message), By::Host, "{text}");
        let Content::Message { reply_to, .. } = &message.content else {
            unreachable!("said() saw a message");
        };
        assert_eq!(*reply_to, quoting, "{text}");
        message.id
    }

    /// What Max says in `place` itself.
    async fn says(&mut self, place: &Place, words: &str) {
        let (conversation, message, text) = self.said().await;
        assert_eq!((conversation, text.as_str()), (place.conversation, words));
        assert_eq!(ingest::by(&message), By::Max);
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
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_question_and_its_answer_are_said_in_both_conversations(pool: PgPool) {
    let mut p = Pair::new(pool).await;
    let (chat, room) = (Arc::clone(&p.chat), Arc::clone(&p.room));
    let (c, r) = (chat.conversation, room.conversation);
    p.link(&chat, &room).await;

    // Max in the private chat asks Max in the group, which wakes for it.
    p.script.push(Answer::says("我问问大家"));
    let asked = p.ask(&chat, r, " 明天的活动几点开始？\n").await;
    assert_eq!(asked, Ok(1));
    let asking = format!("asked c#{r}:\n明天的活动几点开始？");
    let said = p.line(&chat, &asking, None).await;
    let put = format!("c#{c} asks:\n明天的活动几点开始？");
    let question = p.line(&room, &put, None).await;
    p.says(&room, "我问问大家").await;
    // Among the group's new rows, as a line maxx said, and once.
    let shown = p.request_tail(0);
    let line =
        format!("#{question} 系统发的]: ```text ⏎ c#{c} asks: ⏎ 明天的活动几点开始？ ⏎ ```\n");
    assert!(shown.ends_with(&line), "{shown}");
    assert_eq!(shown.matches("asks:").count(), 1, "{shown}");
    let waiting = p.jobs(&chat, Request::Status { job: None }).await.unwrap();
    let Reply::Running(jobs) = waiting else {
        panic!("{waiting:?}");
    };
    let title = format!("? c#{r}: 明天的活动几点开始？");
    assert_eq!(
        (jobs[0].job.as_str(), jobs[0].title.as_str()),
        ("job#1", title.as_str())
    );

    // The answer names the line; it wakes Max in the private chat.
    p.script.push(Answer::says("群里说晚上八点"));
    let answered = p.answer(&room, question, "晚上八点\n").await;
    assert_eq!(answered, Ok(format!("c#{c}")));
    let (mut lines, mut words) = (Vec::new(), Vec::new());
    for _ in 0..3 {
        let (conversation, message, text) = p.said().await;
        match ingest::by(&message) {
            By::Host => lines.push((conversation, text, project::quotes(&message))),
            _ => words.push((conversation, text)),
        }
    }
    lines.sort();
    let mut expected = [
        (r, format!("answered c#{c}:\n晚上八点"), Some(question)),
        (c, format!("c#{r} answered:\n晚上八点"), Some(said)),
    ]
    .map(|(conversation, body, quoting)| (conversation, command::fenced("text", &body), quoting));
    expected.sort();
    assert_eq!(lines, expected);
    assert_eq!(words, [(c, "群里说晚上八点".to_owned())]);
    let shown = p.request_tail(1);
    let answer = format!("系统发的]: [reply#{said}] ```text ⏎ c#{r} answered: ⏎ 晚上八点 ⏎ ```\n");
    assert!(shown.ends_with(&answer), "{shown}");
    // What the private chat asked is in its tail, not among the new rows.
    assert_eq!(shown.matches("answered:").count(), 1, "{shown}");
    let waiting = p.jobs(&chat, Request::Status { job: None }).await.unwrap();
    assert_eq!(waiting, Reply::Running(Vec::new()));

    // Answered, nobody waits on the line any more: nothing is said.
    let again = p.answer(&room, question, "九点").await.unwrap_err();
    assert!(again.contains("没有人在等"), "{again}");
    let never = p.answer(&room, said, "九点").await.unwrap_err();
    assert!(never.contains("没有人在等"), "{never}");
    p.quiet().await;

    // The group's core still runs: the next question is new input to it.
    p.script.push(Answer::says("这个我知道"));
    assert_eq!(p.ask(&chat, r, "在哪办？").await, Ok(2));
    p.line(&chat, &format!("asked c#{r}:\n在哪办？"), None)
        .await;
    let second = p.line(&room, &format!("c#{c} asks:\n在哪办？"), None).await;
    p.says(&room, "这个我知道").await;
    let fed = p.request_tail(2);
    let line = format!("#{second} 系统发的]: ```text ⏎ c#{c} asks: ⏎ 在哪办？ ⏎ ```");
    assert!(fed.ends_with(&line), "{fed}");
    assert!(!fed.contains("明天的活动"), "{fed}");
    let turns: i64 = sqlx::query_scalar("select count(*) from turns where conversation_id = $1")
        .bind(r.0)
        .fetch_one(&p.pool)
        .await
        .unwrap();
    assert_eq!(turns, 1, "one core took both questions");
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_question_goes_only_along_an_edge(pool: PgPool) {
    let mut p = Pair::new(pool).await;
    let (chat, room) = (Arc::clone(&p.chat), Arc::clone(&p.room));
    let c = chat.conversation;
    p.link(&chat, &room).await;

    // The edge runs one way; no edge, no such conversation and itself
    // are refused alike, and nothing is said.
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
    p.link(&room, &chat).await;

    // Withdrawn, the answer finds nobody, and neither side hears more.
    p.script.push(Answer::says("等我想想"));
    assert_eq!(p.ask(&chat, r, "有空吗").await, Ok(1));
    p.line(&chat, &format!("asked c#{r}:\n有空吗"), None).await;
    let question = p.line(&room, &format!("c#{c} asks:\n有空吗"), None).await;
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
    let late = p.answer(&room, question, "有").await.unwrap_err();
    assert!(late.contains("没有人在等"), "{late}");
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
    let said = format!("asked c#{unknown}:\n有人吗");
    let said = p.line(&room, &said, None).await;
    let unserved = format!("c#{unknown} didn't answer: Max serves no chat of that conversation");
    p.line(&room, &unserved, Some(said)).await;
    p.says(&room, "那算了").await;
    let fed = p.request_tail(1);
    let line = format!("系统发的]: [reply#{said}] ```text ⏎ {unserved} ⏎ ```");
    assert!(fed.ends_with(&line), "{fed}");

    // /stop there ends the wait of a question not yet answered.
    p.script.push(Answer::says("稍等"));
    assert_eq!(p.ask(&chat, r, "还在吗").await, Ok(2));
    let said = p.line(&chat, &format!("asked c#{r}:\n还在吗"), None).await;
    p.line(&room, &format!("c#{c} asks:\n还在吗"), None).await;
    p.says(&room, "稍等").await;
    p.script.push(Answer::says("好吧"));
    let me = InNode::MentionMe {
        display: "maxx".into(),
    };
    let stop = Event::Inbound(from_xiaohong(0, vec![me, text("/stop")]));
    p.mailboxes[&r].send(stop).unwrap();
    let mut heard = Vec::new();
    for _ in 0..3 {
        let (conversation, _, text) = p.said().await;
        heard.push((conversation, text));
    }
    heard.sort();
    let stopped = "stopped: messages are still recorded, but Max won't reply until @maxx /start";
    let unanswered = format!("c#{r} didn't answer: Max was stopped there (/stop)");
    let mut expected = [
        (r, command::answer("stop", stopped)),
        (c, command::fenced("text", &unanswered)),
        (c, "好吧".to_owned()),
    ];
    expected.sort();
    assert_eq!(heard, expected);

    // Stopped, the group isn't told of a question, and the asker hears
    // why at once.
    p.script.push(Answer::says("嗯"));
    assert_eq!(p.ask(&chat, r, "真的不在？").await, Ok(3));
    let again = p
        .line(&chat, &format!("asked c#{r}:\n真的不在？"), None)
        .await;
    let unanswered = format!("c#{r} didn't answer: Max is stopped there (/stop)");
    p.line(&chat, &unanswered, Some(again)).await;
    p.says(&chat, "嗯").await;
    p.quiet().await;
    assert!(said < again);
}
