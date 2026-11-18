use std::sync::Arc;

use max_core::message::{Draft, DraftNode, Message as Row};
use max_db::ledger::Delivery;

use super::*;
use crate::conversation::testing::{from_xiaoming, group, offset, text};
use crate::conversation::{Place, ingest};

/// Records what it is asked to send or recall, and answers both from one
/// script: Ok gives a message an id and a ref_idx, `Err(LOST)` an answer
/// that didn't come back whole. Uploads always work.
#[derive(Default)]
struct Recorder {
    answers: Mutex<VecDeque<Result<(), i64>>>,
    sent: Mutex<Vec<(String, Message)>>,
    /// What each went up as, a file with its name, and the bytes.
    uploaded: Mutex<Vec<(String, Vec<u8>)>>,
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
        let (what, content) = match media {
            Media::Picture(content) => ("picture".to_owned(), content),
            Media::Voice(content) => ("voice".to_owned(), content),
            Media::File { name, content } => (format!("file {name}"), content),
        };
        // The sender hands over where the bytes are, not the bytes.
        let api::Content::Path(path) = content else {
            panic!("uploaded from memory");
        };
        uploaded.push((what, std::fs::read(path).unwrap()));
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
        let committed = ingest::inbound(&mut conn, &self.place, inbound, Utc::now(), offset())
            .await
            .unwrap();
        Arc::unwrap_or_clone(committed.message)
    }

    async fn say(&self, draft: Draft) -> Outgoing {
        let mut conn = self.pool.acquire().await.unwrap();
        let message = ingest::said(
            &mut conn,
            &self.place,
            draft,
            None,
            None,
            ingest::By::Max,
            Utc::now(),
            offset(),
        )
        .await
        .unwrap()
        .unwrap();
        Outgoing {
            place: Arc::clone(&self.place),
            message: Arc::new(message),
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
                .bind(message.id.get())
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
    let told = told.await.unwrap().unwrap_err().to_string();
    assert!(told.starts_with("QQ never answered"), "{told}");
}
