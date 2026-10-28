use std::sync::Arc;

use chrono::DateTime;
use max_core::ids::FaceId;
use max_core::message::{Draft, DraftNode, Message as Row};
use max_db::ledger::Delivery;

use super::*;
use crate::conversation::testing::{from_xiaoming, group, offset, text};
use crate::conversation::{Place, ingest};

/// Records what it is asked to send, and answers from a script: Ok gives
/// the message an id and a ref_idx.
#[derive(Default)]
struct Recorder {
    answers: Mutex<VecDeque<Result<(), i64>>>,
    sent: Mutex<Vec<(String, Message)>>,
}

impl Api for Recorder {
    fn send<'a>(
        &'a self,
        chat: Chat<'a>,
        message: &'a Message,
    ) -> Pin<Box<dyn Future<Output = Result<Sent, api::Error>> + Send + 'a>> {
        let mut sent = self.sent.lock().unwrap();
        sent.push((format!("{chat:?}"), message.clone()));
        let n = sent.len();
        let answer = self.answers.lock().unwrap().pop_front().unwrap_or(Ok(()));
        Box::pin(async move {
            match answer {
                Ok(()) => Ok(Sent {
                    id: format!("SENT{n}"),
                    ref_idx: Some(format!("REF{n}")),
                }),
                Err(code) => Err(api::Error::Api {
                    path: "/v2/groups/GROUP1/messages".into(),
                    status: 400,
                    code,
                    message: "refused".into(),
                    trace: "t".into(),
                }),
            }
        })
    }
}

struct Setup {
    pool: PgPool,
    place: Arc<Place>,
    api: Arc<Recorder>,
}

impl Setup {
    async fn new(pool: PgPool) -> Self {
        let mut conn = pool.acquire().await.unwrap();
        let place = Arc::new(group(&mut conn).await);
        Self {
            pool,
            place,
            api: Arc::default(),
        }
    }

    /// 小明 says something now.
    async fn hear(&self, n: u32) -> Row {
        self.hear_at(n, Utc::now()).await
    }

    async fn hear_at(&self, n: u32, at: DateTime<Utc>) -> Row {
        let mut conn = self.pool.acquire().await.unwrap();
        let mut inbound = from_xiaoming(n, vec![text("在吗")]);
        inbound.at = at;
        let committed = ingest::inbound(&mut conn, &self.place, &inbound, Utc::now(), offset())
            .await
            .unwrap();
        committed.message
    }

    async fn say(&self, draft: Draft) -> Outgoing {
        let mut conn = self.pool.acquire().await.unwrap();
        let (message, _) = ingest::said(
            &mut conn,
            &self.place,
            draft,
            None,
            None,
            Utc::now(),
            offset(),
        )
        .await
        .unwrap();
        Outgoing {
            place: Arc::clone(&self.place),
            message,
        }
    }

    async fn send_all(&self, outgoing: Vec<Outgoing>) {
        let (tx, rx) = mpsc::unbounded_channel();
        for outgoing in outgoing {
            tx.send(outgoing).unwrap();
        }
        drop(tx);
        let api = Arc::clone(&self.api) as Arc<dyn Api>;
        run(api, self.pool.clone(), rx, Duration::from_secs(5)).await;
    }

    fn sent(&self) -> Vec<(String, Message)> {
        self.api.sent.lock().unwrap().clone()
    }

    async fn delivery(&self, message: &Row) -> (Delivery, Option<String>, Option<String>) {
        let mut conn = self.pool.acquire().await.unwrap();
        let row = ledger::row(&mut conn, self.place.conversation, message.id)
            .await
            .unwrap()
            .unwrap();
        let (native_id, quote_id) =
            sqlx::query_as("select native_id, quote_id from deliveries where message_id = $1")
                .bind(message.id.0)
                .fetch_one(&mut *conn)
                .await
                .unwrap();
        (row.delivery.unwrap(), native_id, quote_id)
    }
}

fn said(text: &str) -> Draft {
    Draft {
        reply_to: None,
        nodes: vec![DraftNode::Text { text: text.into() }],
    }
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_passive_markdown_reply(pool: PgPool) {
    let s = Setup::new(pool).await;
    let heard = s.hear(0).await;
    let mut conn = s.pool.acquire().await.unwrap();
    let xiaoming = platform::principals(&mut conn, &[heard.sender.identity])
        .await
        .unwrap()[&heard.sender.identity];
    drop(conn);
    let draft = Draft {
        reply_to: Some(heard.id),
        nodes: vec![
            DraftNode::Mention {
                principal: xiaoming,
            },
            DraftNode::Text {
                text: " 在，\\[x^2\\]".into(),
            },
            DraftNode::Face { face: FaceId(14) },
        ],
    };
    let outgoing = s.say(draft).await;
    let message = outgoing.message.clone();
    s.send_all(vec![outgoing]).await;
    let sent = s.sent();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].0, "Group(\"GROUP1\")");
    assert_eq!(
        sent[0].1,
        Message {
            body: Body::Markdown("<qqbot-at-user id=\"XIAOMING\" /> 在，$$x^2$$[微笑]".into()),
            reply: Some(Reply::Message {
                id: "MSG0".into(),
                seq: 1,
            }),
            quote: Some("IDX0".into()),
        }
    );
    assert_eq!(
        s.delivery(&message).await,
        (Delivery::Sent, Some("SENT1".into()), Some("REF1".into()))
    );
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn plain_text_when_markdown_is_refused(pool: PgPool) {
    let s = Setup::new(pool).await;
    s.hear(0).await;
    s.api
        .answers
        .lock()
        .unwrap()
        .extend([Err(40054010), Ok(())]);
    let first = s.say(said("一")).await;
    let message = first.message.clone();
    s.api.answers.lock().unwrap().extend([Err(1), Err(2)]);
    let second = s.say(said("二")).await;
    let failed = second.message.clone();
    s.send_all(vec![first, second]).await;
    let sent = s.sent();
    let bodies: Vec<_> = sent.iter().map(|(_, m)| (&m.body, &m.reply)).collect();
    let reply = |seq| {
        Some(Reply::Message {
            id: "MSG0".into(),
            seq,
        })
    };
    assert_eq!(
        bodies,
        [
            (&Body::Markdown("一".into()), &reply(1)),
            (&Body::Text("一".into()), &reply(2)),
            (&Body::Markdown("二".into()), &reply(3)),
            (&Body::Text("二".into()), &reply(4)),
        ]
    );
    assert_eq!(s.delivery(&message).await.0, Delivery::Sent);
    assert_eq!(s.delivery(&failed).await, (Delivery::Failed, None, None));
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn proactive_when_nothing_is_recent_or_after_five_replies(pool: PgPool) {
    let s = Setup::new(pool).await;
    s.send_all(vec![s.say(said("没人说话")).await]).await;
    s.hear(0).await;
    let mut outgoing = Vec::new();
    for n in 0..6 {
        outgoing.push(s.say(said(&n.to_string())).await);
    }
    s.send_all(outgoing).await;
    let replies: Vec<_> = s
        .sent()
        .into_iter()
        .map(|(_, message)| match message.reply {
            Some(Reply::Message { seq, .. }) => seq,
            _ => 0,
        })
        .collect();
    assert_eq!(replies, [0, 1, 2, 3, 4, 5, 0]);
}

/// QQ replays what was said while Max was down, and its reply window counts
/// from when it was said.
#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn proactive_to_a_message_replayed_too_late(pool: PgPool) {
    let s = Setup::new(pool).await;
    s.hear_at(0, Utc::now() - chrono::TimeDelta::minutes(10))
        .await;
    s.send_all(vec![s.say(said("掐着表呢")).await]).await;
    assert!(s.sent()[0].1.reply.is_none());
}

#[tokio::test(start_paused = true)]
async fn proactive_messages_wait_for_the_rate() {
    let pool = sqlx::postgres::PgPoolOptions::new()
        .connect_lazy("postgres://unused")
        .unwrap();
    let shared = Shared {
        api: Arc::new(Recorder::default()),
        pool,
        sent: Mutex::default(),
        replies: Mutex::default(),
    };
    let start = Instant::now();
    for _ in 0..CHAT_RATE {
        shared.proactive("group:A").await;
    }
    assert_eq!(start.elapsed(), Duration::ZERO);
    for _ in 0..CHAT_RATE {
        shared.proactive("group:B").await;
        shared.proactive("group:C").await;
    }
    assert_eq!(start.elapsed(), Duration::ZERO);
    shared.proactive("group:D").await;
    assert_eq!(start.elapsed(), MINUTE, "the bot's rate");
    let start = Instant::now();
    shared.proactive("group:A").await;
    assert_eq!(start.elapsed(), Duration::ZERO);
    for _ in 0..CHAT_RATE - 1 {
        shared.proactive("group:A").await;
    }
    shared.proactive("group:A").await;
    assert_eq!(start.elapsed(), MINUTE, "a chat's rate");
}
