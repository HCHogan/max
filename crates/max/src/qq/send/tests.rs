use std::sync::Arc;

use max_core::message::{Draft, DraftNode, MediaKind, MediaMeta, Message as Row};
use max_db::ledger::Delivery;
use max_db::media::{self, Blob};

use super::*;
use crate::conversation::testing::{from_xiaoming, group, offset, text};
use crate::conversation::{Place, ingest};
use crate::inbound::InNode;

/// Records what it is asked to send or recall, and answers both from one
/// script: Ok gives a message an id and a ref_idx, `Err(LOST)` an answer
/// that didn't come back whole. Uploads always work.
#[derive(Default)]
struct Recorder {
    answers: Mutex<VecDeque<Result<(), i64>>>,
    sent: Mutex<Vec<(String, Message)>>,
    /// A file's name, and the bytes.
    uploaded: Mutex<Vec<(Option<String>, Vec<u8>)>>,
    recalled: Mutex<Vec<(String, String)>>,
}

const LOST: i64 = 0;

fn refused(code: i64) -> api::Error {
    if code == LOST {
        return api::Error::Decode {
            path: "/v2/groups/GROUP1/messages".into(),
            source: serde_json::from_str::<()>("<html>").unwrap_err(),
        };
    }
    api::Error::Api {
        path: "/v2/groups/GROUP1/messages".into(),
        status: 400,
        code,
        message: "refused".into(),
        trace: "t".into(),
    }
}

impl Api for Recorder {
    fn upload<'a>(&'a self, _: Chat<'a>, media: Media<'a>) -> Answer<'a, Uploaded> {
        let mut uploaded = self.uploaded.lock().unwrap();
        uploaded.push(match media {
            Media::Picture(bytes) => (None, bytes.to_vec()),
            Media::File { name, bytes } => (Some(name.to_owned()), bytes.to_vec()),
        });
        let file_info = format!("FI{}", uploaded.len());
        Box::pin(async move {
            Ok(Uploaded {
                file_info,
                ttl: 86400,
            })
        })
    }

    fn send<'a>(&'a self, chat: Chat<'a>, message: &'a Message) -> Answer<'a, Sent> {
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
                Err(code) => Err(refused(code)),
            }
        })
    }

    fn recall<'a>(&'a self, chat: Chat<'a>, message_id: &'a str) -> Answer<'a, ()> {
        let mut recalled = self.recalled.lock().unwrap();
        recalled.push((format!("{chat:?}"), message_id.to_owned()));
        let answer = self.answers.lock().unwrap().pop_front().unwrap_or(Ok(()));
        Box::pin(async move { answer.map_err(refused) })
    }
}

struct Setup {
    pool: PgPool,
    place: Arc<Place>,
    api: Arc<Recorder>,
    store: Arc<Store>,
    dir: std::path::PathBuf,
}

impl Drop for Setup {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

impl Setup {
    async fn new(pool: PgPool) -> Self {
        let mut conn = pool.acquire().await.unwrap();
        let place = Arc::new(group(&mut conn).await);
        let dir = std::env::temp_dir().join(format!("max-send-{:016x}", rand::random::<u64>()));
        Self {
            pool,
            place,
            api: Arc::default(),
            store: Arc::new(Store::open(&dir).await.unwrap()),
            dir,
        }
    }

    /// 小明 says something now.
    async fn hear(&self, n: u32) -> Row {
        let mut conn = self.pool.acquire().await.unwrap();
        let inbound = from_xiaoming(n, vec![text("在吗")]);
        let committed = ingest::inbound(&mut conn, &self.place, &inbound, Utc::now(), offset())
            .await
            .unwrap();
        committed.message
    }

    async fn say(&self, draft: Draft) -> Outgoing {
        let mut conn = self.pool.acquire().await.unwrap();
        let message = ingest::said(
            &mut conn,
            &self.place,
            draft,
            None,
            None,
            Utc::now(),
            offset(),
        )
        .await
        .unwrap()
        .unwrap();
        Outgoing {
            place: Arc::clone(&self.place),
            message,
            receipt: None,
        }
    }

    /// Max takes back `target`.
    async fn unsend(&self, target: MessageId) -> Outgoing {
        let mut conn = self.pool.acquire().await.unwrap();
        let unsend = ingest::unsend(&mut conn, &self.place, target, None, Utc::now(), offset());
        Outgoing {
            place: Arc::clone(&self.place),
            message: unsend.await.unwrap().unwrap(),
            receipt: None,
        }
    }

    async fn send_all(&self, outgoing: Vec<Outgoing>) {
        let (tx, rx) = mpsc::unbounded_channel();
        for outgoing in outgoing {
            tx.send(outgoing).unwrap();
        }
        drop(tx);
        let api = Arc::clone(&self.api) as Arc<dyn Api>;
        let store = Some(Arc::clone(&self.store));
        run(api, self.pool.clone(), store, rx, Duration::from_secs(5)).await;
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
async fn markdown_with_a_mention_and_a_quote(pool: PgPool) {
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
            body: Body::Markdown("<qqbot-at-user id=\"XIAOMING\" /> 在，$$x^2$$".into()),
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
    let bodies: Vec<_> = sent.iter().map(|(_, m)| &m.body).collect();
    assert_eq!(
        bodies,
        [
            &Body::Markdown("一".into()),
            &Body::Text("一".into()),
            &Body::Markdown("二".into()),
            &Body::Text("二".into()),
        ]
    );
    assert_eq!(s.delivery(&message).await.0, Delivery::Sent);
    assert_eq!(s.delivery(&failed).await, (Delivery::Failed, None, None));
}

/// QQ's answer lost: the message may be in the group, so it isn't sent
/// again as plain text, and nobody says it failed.
#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_lost_answer_is_neither_resent_nor_failed(pool: PgPool) {
    let s = Setup::new(pool).await;
    s.api.answers.lock().unwrap().push_back(Err(LOST));
    let (receipt, told) = tokio::sync::oneshot::channel();
    let outgoing = Outgoing {
        receipt: Some(receipt),
        ..s.say(said("一")).await
    };
    let message = outgoing.message.clone();
    s.send_all(vec![outgoing]).await;
    let bodies: Vec<_> = s.sent().into_iter().map(|(_, m)| m.body).collect();
    assert_eq!(bodies, [Body::Markdown("一".into())]);
    assert_eq!(s.delivery(&message).await, (Delivery::Unknown, None, None));
    let told = told.await.unwrap().unwrap_err();
    assert!(told.starts_with("没等到 QQ 的回答"), "{told}");
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_sticker_is_uploaded_once(pool: PgPool) {
    let s = Setup::new(pool).await;
    // 小明 sent a sticker, and it was downloaded.
    let mut conn = s.pool.acquire().await.unwrap();
    let sticker = InNode::Node(Node::Media {
        media: Some(MediaRef::Remote("https://q.example/s".into())),
        meta: MediaMeta {
            kind: MediaKind::Sticker,
            mime: None,
            size: None,
            name: None,
            description: None,
        },
    });
    let inbound = from_xiaoming(0, vec![sticker]);
    let row = ingest::inbound(&mut conn, &s.place, &inbound, Utc::now(), offset())
        .await
        .unwrap()
        .message
        .id;
    let bytes = b"GIF89a".to_vec();
    let sha256 = s.store.put(bytes.clone()).await.unwrap();
    let blob = Blob {
        sha256,
        mime: Some("image/gif".into()),
        size: 6,
        width: None,
        height: None,
        model_sha256: None,
    };
    media::record(&mut conn, row, 0, &blob, Utc::now())
        .await
        .unwrap();
    drop(conn);

    let again = || Draft {
        reply_to: None,
        nodes: vec![DraftNode::Picture {
            message: row,
            ordinal: 0,
        }],
    };
    // QQ refuses the second: the third uploads it again.
    s.api
        .answers
        .lock()
        .unwrap()
        .extend([Ok(()), Err(40034028), Ok(())]);
    // The first two wait to hear how it went.
    let mut first = s.say(again()).await;
    let message = first.message.clone();
    let (receipt, sent) = tokio::sync::oneshot::channel();
    first.receipt = Some(receipt);
    let mut second = s.say(again()).await;
    let (receipt, refused) = tokio::sync::oneshot::channel();
    second.receipt = Some(receipt);
    let outgoing = vec![first, second, s.say(again()).await];
    s.send_all(outgoing).await;
    assert_eq!(sent.await.unwrap(), Ok(message.id));
    assert!(refused.await.unwrap().unwrap_err().contains("refused"));
    let bodies: Vec<Body> = s.sent().into_iter().map(|(_, m)| m.body).collect();
    let media = |file_info: &str| Body::Media {
        file_info: file_info.into(),
        caption: None,
    };
    assert_eq!(bodies, [media("FI1"), media("FI1"), media("FI2")]);
    assert_eq!(
        *s.api.uploaded.lock().unwrap(),
        [(None, bytes.clone()), (None, bytes)]
    );
    assert_eq!(s.delivery(&message).await.0, Delivery::Sent);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_file_goes_alone_under_its_name(pool: PgPool) {
    let s = Setup::new(pool).await;
    let bytes = b"%PDF-1.4".to_vec();
    let sha256 = s.store.put(bytes.clone()).await.unwrap();
    let blob = Blob {
        sha256: sha256.clone(),
        mime: None,
        size: 8,
        width: None,
        height: None,
        model_sha256: None,
    };
    let mut conn = s.pool.acquire().await.unwrap();
    media::remember(&mut conn, &blob, Utc::now()).await.unwrap();
    drop(conn);
    let file = |name: &str| Draft {
        reply_to: None,
        nodes: vec![
            DraftNode::File {
                sha256: sha256.clone(),
                name: name.into(),
                size: 8,
            },
            DraftNode::Text {
                text: "不在文件消息里".into(),
            },
        ],
    };
    // The same bytes under another name are uploaded again.
    let first = s.say(file("报告.pdf")).await;
    let message = first.message.clone();
    let outgoing = vec![
        first,
        s.say(file("报告.pdf")).await,
        s.say(file("副本.pdf")).await,
    ];
    s.send_all(outgoing).await;
    let bodies: Vec<Body> = s.sent().into_iter().map(|(_, m)| m.body).collect();
    let media = |file_info: &str| Body::Media {
        file_info: file_info.into(),
        caption: None,
    };
    assert_eq!(bodies, [media("FI1"), media("FI1"), media("FI2")]);
    let named = |name: &str| (Some(name.to_owned()), bytes.clone());
    assert_eq!(
        *s.api.uploaded.lock().unwrap(),
        [named("报告.pdf"), named("副本.pdf")]
    );
    assert_eq!(s.delivery(&message).await.0, Delivery::Sent);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn an_unsend_recalls_what_its_message_went_out_or_came_in_as(pool: PgPool) {
    let s = Setup::new(pool).await;
    let heard = s.hear(0).await;
    let first = s.say(said("一")).await;
    let mine = first.message.id;
    let second = s.say(said("二")).await;
    let not_sent = second.message.id;
    // Max takes back what it said, which goes out first; what it said
    // that didn't go out; and 小明's, twice, which QQ refuses the second
    // time.
    let mut outgoing = vec![first, second];
    for target in [mine, not_sent, heard.id, heard.id] {
        outgoing.push(s.unsend(target).await);
    }
    let unsends: Vec<Row> = outgoing[2..].iter().map(|o| o.message.clone()).collect();
    let (receipt, refusal) = tokio::sync::oneshot::channel();
    outgoing[5].receipt = Some(receipt);
    s.api
        .answers
        .lock()
        .unwrap()
        .extend([Ok(()), Err(1), Err(2), Ok(()), Ok(()), Err(40062003)]);
    s.send_all(outgoing).await;

    let group = || "Group(\"GROUP1\")".to_owned();
    assert_eq!(
        *s.api.recalled.lock().unwrap(),
        [
            (group(), "SENT1".to_owned()),
            (group(), "MSG0".to_owned()),
            (group(), "MSG0".to_owned())
        ]
    );
    // Recalled: sent, with no id of its own.
    assert_eq!(s.delivery(&unsends[0]).await, (Delivery::Sent, None, None));
    assert_eq!(s.delivery(&unsends[1]).await.0, Delivery::Failed);
    assert_eq!(s.delivery(&unsends[2]).await.0, Delivery::Sent);
    assert_eq!(s.delivery(&unsends[3]).await.0, Delivery::Failed);
    assert!(refusal.await.unwrap().unwrap_err().contains("群管理员"));
}

#[tokio::test(start_paused = true)]
async fn proactive_messages_wait_for_the_rate() {
    let pool = sqlx::postgres::PgPoolOptions::new()
        .connect_lazy("postgres://unused")
        .unwrap();
    let shared = Shared {
        api: Arc::new(Recorder::default()),
        pool,
        store: None,
        sent: Mutex::default(),
        uploads: Mutex::default(),
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
