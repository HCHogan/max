//! Two actors against the real database: 小明's private chat and the
//! group, each with a row to start from, with a scripted model and a
//! sender that only queues. A task plays the conversation table's part and
//! hands a question, or an answer, to the actor it is for. No test here
//! waits on a clock: nothing in asking does.

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
        let back = signals.clone();
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
                let Signal::Heard {
                    conversation,
                    heard,
                } = signal
                else {
                    panic!("{signal:?}");
                };
                match (routes.get(&conversation), heard) {
                    (Some(mailbox), heard) => mailbox.send(Event::Heard(heard)).unwrap(),
                    // As the table says it.
                    (None, Heard::Asked(question)) => {
                        let why = "Max serves no chat of that conversation".to_owned();
                        back.send(question.answered(Err(why))).unwrap();
                    }
                    (None, heard) => panic!("{heard:?}"),
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

    /// Max in `place`, asking of its conversation as a tool does.
    fn max(&self, place: &Place) -> Poster {
        Poster::new(self.mailboxes[&place.conversation].clone())
    }

    /// Max in `place` calls `ask`.
    async fn ask(
        &self,
        place: &Place,
        to: ConversationId,
        question: &str,
    ) -> Result<String, String> {
        self.max(place).ask(to, question.to_owned()).await
    }

    /// Max in `place` calls `answer`.
    async fn answer(&self, place: &Place, to: u32, text: &str) -> Result<String, String> {
        self.max(place).answer(to, text.to_owned()).await
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
async fn one_max_asks_another_and_no_chat_hears_of_it(pool: PgPool) {
    let mut p = Pair::new(pool).await;
    let (chat, room) = (Arc::clone(&p.chat), Arc::clone(&p.room));
    let (c, r) = (chat.conversation, room.conversation);
    p.link(&chat, &room).await;

    // The edge runs one way; no edge, no such conversation and itself
    // are refused alike.
    for (asker, to) in [(&room, c), (&chat, ConversationId(999)), (&chat, c)] {
        let refused = p.ask(asker, to, "在吗").await.unwrap_err();
        let alike =
            format!("can't ask c#{to}: there is no link from here to it, or no such conversation;");
        assert!(refused.starts_with(&alike), "{refused}");
    }

    // Max in the private chat asks Max in the group, which wakes for it.
    let asked = Ok(format!("c#{r}"));
    p.script.push(Answer::says("我问问大家"));
    assert_eq!(p.ask(&chat, r, " 明天几点开始？\n").await, asked);
    p.says(&room, "我问问大家").await;
    let shown = p.request_tail(0);
    let put = format!("[新消息]\n[ask#1 问] c#{c}\n明天几点开始？\n（那个会话的 Max 问你的：");
    assert!(shown.contains(&put), "{shown}");
    // The group may ask nobody, and the question that woke it is shown
    // once: neither list is there.
    assert!(!shown.contains("[能问的会话]"), "{shown}");
    assert!(!shown.contains("[等你回答的问题]"), "{shown}");
    // Who asked kept nothing of it: the number is the group's own.
    let own = p.answer(&chat, 1, "自问自答").await.unwrap_err();
    assert!(own.starts_with("there is no ask#1 to answer"), "{own}");

    // The answer names the question; it wakes Max in the private chat,
    // whose new core is told what it had asked and whom it may ask.
    p.script.push(Answer::says("群里说晚上八点"));
    assert_eq!(p.answer(&room, 1, "晚上八点\n").await, Ok(format!("c#{c}")));
    p.says(&chat, "群里说晚上八点").await;
    let shown = p.request_tail(1);
    let heard = format!("[回答] c#{r}\n问：明天几点开始？\n答：晚上八点\n");
    assert!(shown.ends_with(&heard), "{shown}");
    let askable = format!("\n\n[能问的会话]\nc#{r}\n\n[新消息]\n");
    assert!(shown.contains(&askable), "{shown}");
    // Once.
    let again = p.answer(&room, 1, "九点").await.unwrap_err();
    assert!(again.starts_with("there is no ask#1 to answer"), "{again}");

    // Nobody waits: left unanswered, neither side hears more, and an
    // answer that comes late arrives all the same.
    p.script.push(Answer::says("等我想想"));
    assert_eq!(p.ask(&chat, r, "有空吗").await, asked);
    p.says(&room, "等我想想").await;
    p.quiet().await;
    p.script.push(Answer::says("知道了"));
    assert_eq!(p.answer(&room, 2, "有").await, Ok(format!("c#{c}")));
    p.says(&chat, "知道了").await;
    let late = format!("[新消息]\n[回答] c#{r}\n问：有空吗\n答：有");
    assert_eq!(p.request_tail(3), late);

    // /stop there answers for what was asked and not yet answered: both
    // cores still run, and read what comes as new input.
    p.script.push(Answer::says("稍等"));
    assert_eq!(p.ask(&chat, r, "还在吗").await, asked);
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
    let why = format!("c#{r}：Max is stopped there (/stop)");
    let unanswered = format!("[新消息]\n[没答成] {why}\n问：还在吗");
    assert_eq!(p.request_tail(5), unanswered);
    // Stopped, Max there answers nothing.
    let gone = p.answer(&room, 3, "在").await.unwrap_err();
    assert!(gone.contains("Max is stopped here"), "{gone}");

    // Stopped, Max there isn't told of a question, and the asker hears
    // why at once.
    p.script.push(Answer::says("嗯"));
    assert_eq!(p.ask(&chat, r, "真的不在？").await, asked);
    p.says(&chat, "嗯").await;
    let unanswered = format!("[新消息]\n[没答成] {why}\n问：真的不在？");
    assert_eq!(p.request_tail(6), unanswered);
    p.quiet().await;

    // Nothing of it is a row: maxx said only the command's answer.
    let lines = "select count(*) from messages where raw ->> 'said_by' = 'host'";
    assert_eq!(p.count(lines).await, 1);
    let turns = "select count(*) from turns t join conversations c on c.id = t.conversation_id where c.kind = 'group'";
    assert_eq!(p.count(turns).await, 1, "one core took every question");
}

/// Who is asked keeps the latest questions, and one pushed out can't be
/// answered any more.
#[test]
fn the_latest_questions_are_kept_for_their_answers() {
    let peer = |conversation| links::Peer {
        conversation: ConversationId(conversation),
        title: None,
    };
    let question = |n: usize| Question {
        from: peer(7),
        to: peer(9),
        text: format!("第 {n} 问\n还有一行"),
    };
    let mut asked = Asked::default();
    for n in 1..=ASKED_KEPT + 1 {
        assert_eq!(asked.keep(question(n)), u32::try_from(n).unwrap());
    }
    assert_eq!(asked.kept.len(), ASKED_KEPT);
    assert!(!asked.kept.contains_key(&1), "the oldest went");
    let lines = asked.lines();
    assert_eq!(lines.len(), ASKED_KEPT);
    assert_eq!(lines[0], "ask#2 c#7：第 2 问 ⏎ 还有一行");
    // Answered, it is kept no longer; the numbers go on.
    asked.kept.remove(&2);
    assert_eq!(asked.lines()[0], "ask#3 c#7：第 3 问 ⏎ 还有一行");
    let next = u32::try_from(ASKED_KEPT).unwrap() + 2;
    assert_eq!(asked.keep(question(0)), next);
    // /stop answers for all of them.
    assert_eq!(asked.take().len(), ASKED_KEPT);
    assert!(asked.lines().is_empty());
}
