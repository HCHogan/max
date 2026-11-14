use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use max_core::message::{Draft, DraftNode};
use serde_json::{Value, json};
use sqlx::PgPool;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::net::TcpListener;
use tokio::process::{ChildStdout, Command};
use tokio::sync::broadcast;
use tokio::sync::mpsc::{self, UnboundedReceiver};

use super::*;
use crate::conversation::Place;
use crate::conversation::testing::{from_xiaoming, group, offset, text};
use crate::scope::Scope;
use crate::service::Services;

const PATIENCE: Duration = Duration::from_secs(5);
const MAXX: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../nix/maxx.js");

/// The group's `/events`, served with a quick heartbeat; what it asks of
/// the conversation comes to the receiver.
async fn served(scope: &mut Scope) -> (String, UnboundedReceiver<Signal>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/events", listener.local_addr().unwrap());
    let (signals, asked) = mpsc::unbounded_channel();
    scope.spawn(move |stop| async move {
        let app = beating(
            ConversationId(7),
            signals,
            stop.clone(),
            Duration::from_millis(200),
        );
        let _ = axum::serve(listener, app)
            .with_graceful_shutdown(stop.cancelled_owned())
            .await;
    });
    (url, asked)
}

/// Answers the next subscription the way the actor would, with `head`
/// and `rows`.
async fn answer(
    asked: &mut UnboundedReceiver<Signal>,
    place: &Arc<Place>,
    pool: &PgPool,
    (head, rows): (MessageId, &broadcast::Sender<Arc<Message>>),
) {
    let Some(Signal::Subscribe {
        conversation,
        reply,
    }) = timeout(PATIENCE, asked.recv()).await.unwrap()
    else {
        panic!("no subscription");
    };
    assert_eq!(conversation, ConversationId(7));
    let subscription = Subscription {
        place: Arc::clone(place),
        head,
        rows: rows.subscribe(),
        services: Arc::new(Services::bare(pool.clone())),
    };
    reply.send(subscription).unwrap();
}

/// Asks for `url`, and answers the subscription.
async fn follow(
    url: &str,
    asked: &mut UnboundedReceiver<Signal>,
    place: &Arc<Place>,
    pool: &PgPool,
    at: (MessageId, &broadcast::Sender<Arc<Message>>),
) -> reqwest::Response {
    let (answer, ()) = tokio::join!(reqwest::get(url), answer(asked, place, pool, at));
    answer.unwrap()
}

/// 小明 says `said` as the `n`th message.
async fn from_xiaoming_says(pool: &PgPool, place: &Place, n: u32, said: &str) -> Message {
    let mut conn = pool.acquire().await.unwrap();
    let inbound = from_xiaoming(n, vec![text(said)]);
    let committed = ingest::inbound(&mut conn, place, inbound, Utc::now(), offset());
    Arc::unwrap_or_clone(committed.await.unwrap().message)
}

/// A streamed answer, a line at a time.
struct Lines {
    answer: reqwest::Response,
    read: Vec<u8>,
}

impl Lines {
    /// The next line; None once the stream ends.
    async fn next(&mut self) -> Option<String> {
        loop {
            if let Some(end) = self.read.iter().position(|&byte| byte == b'\n') {
                let line: Vec<u8> = self.read.drain(..=end).collect();
                return Some(String::from_utf8(line[..end].to_vec()).unwrap());
            }
            let chunk = timeout(PATIENCE, self.answer.chunk()).await.unwrap();
            self.read.extend_from_slice(&chunk.unwrap()?);
        }
    }

    /// The next row, past heartbeats.
    async fn row(&mut self) -> Value {
        loop {
            let line = self.next().await.unwrap();
            if !line.is_empty() {
                return serde_json::from_str(&line).unwrap();
            }
        }
    }

    /// Heartbeats, until the stream ends.
    async fn end(&mut self) {
        while let Some(line) = self.next().await {
            assert_eq!(line, "");
        }
    }
}

/// Max says `text`, or a program of its if `program`.
async fn max_says(
    pool: &PgPool,
    place: &Place,
    (text, reply_to): (&str, Option<MessageId>),
    program: bool,
) -> MessageId {
    let mut conn = pool.acquire().await.unwrap();
    let draft = Draft {
        reply_to,
        nodes: vec![DraftNode::Text { text: text.into() }],
    };
    let now = Utc::now();
    let by = if program {
        ingest::By::Program
    } else {
        ingest::By::Max
    };
    let said = ingest::said(&mut conn, place, draft, None, None, by, now, offset());
    said.await.unwrap().unwrap().id
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_program_follows_the_timeline(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    drop(conn);
    let mut ids = Vec::new();
    for (n, said) in [(1, "早"), (2, "ping")] {
        ids.push(from_xiaoming_says(&pool, &place, n, said).await.id);
    }
    ids.push(max_says(&pool, &place, ("pong", Some(ids[1])), false).await);
    ids.push(max_says(&pool, &place, ("CI 全绿", None), true).await);
    let mut scope = Scope::new();
    let (url, mut asked) = served(&mut scope).await;
    let (rows, _) = broadcast::channel(16);
    let head = ids[3];

    // From after the first row: the rest from the database, as they
    // were said.
    let after = format!("{url}?after={}", ids[0]);
    let answer = follow(&after, &mut asked, &place, &pool, (head, &rows)).await;
    assert_eq!(answer.status(), StatusCode::OK);
    assert_eq!(answer.headers()[HEAD], head.0.to_string());
    let mut lines = Lines {
        answer,
        read: Vec::new(),
    };
    let ping = lines.row().await;
    let person = ping["person"].as_i64().unwrap();
    assert_eq!(
        ping,
        json!({
            "id": ids[1].0,
            "at": "2026-10-29T12:02:00+08:00",
            "sender": "小明",
            "person": person,
            "text": "ping",
        })
    );
    let pong = lines.row().await;
    assert_eq!(pong["by"], "max");
    assert_eq!(pong["sender"], "maxx");
    assert_eq!(pong["reply_to"], ids[1].0);
    assert_eq!(pong["text"], format!("[reply#{}] pong", ids[1]));
    let program = lines.row().await;
    assert_eq!(
        (&program["by"], &program["text"]),
        (&json!("program"), &json!("CI 全绿"))
    );

    // Then each row as it is committed; one from before isn't again.
    let again = from_xiaoming_says(&pool, &place, 5, "ping").await;
    let mut conn = pool.acquire().await.unwrap();
    let old = ledger::row(&mut conn, place.conversation, ids[2])
        .await
        .unwrap();
    drop(conn);
    rows.send(Arc::new(old.unwrap().message)).unwrap();
    rows.send(Arc::new(again.clone())).unwrap();
    let live = lines.row().await;
    assert_eq!(
        (&live["id"], &live["text"]),
        (&json!(again.id.0), &json!("ping"))
    );
    assert_eq!(live["person"], person);

    // Nothing for a while: the heartbeat. The actor gone: the end.
    assert_eq!(lines.next().await.unwrap(), "");
    drop(rows);
    lines.end().await;
    scope.close(PATIENCE).await;
}

/// A stream asked for the rows as data has each whole, the ones it
/// catches up on and the ones that come, as the `rows` tool gives them.
#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_stream_asked_for_data_has_each_row_whole(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    drop(conn);
    let first = from_xiaoming_says(&pool, &place, 1, "早").await;
    let mut scope = Scope::new();
    let (url, mut asked) = served(&mut scope).await;
    let (rows, _) = broadcast::channel(16);

    let full = format!("{url}?after=0&full=1");
    let answer = follow(&full, &mut asked, &place, &pool, (first.id, &rows)).await;
    assert_eq!(answer.status(), StatusCode::OK);
    let mut lines = Lines {
        answer,
        read: Vec::new(),
    };
    let caught = lines.row().await;
    let identity = first.sender.identity.0;
    assert_eq!(caught["text"], "早");
    assert_eq!(
        caught["row"],
        json!({
            "id": first.id.0,
            "conversation": place.conversation.0,
            "sender": { "identity": identity, "name": "小明", "role": "member" },
            "at": caught["row"]["at"],
            "content": {
                "type": "message",
                "reply_to": null,
                "nodes": [{ "type": "text", "text": "早" }],
            },
            "turn": null,
            "raw": null,
            "command": false,
            "delivery": null,
        })
    );
    assert_eq!(
        caught["people"],
        json!({ identity.to_string(): caught["person"] })
    );
    let again = from_xiaoming_says(&pool, &place, 2, "ping").await;
    rows.send(Arc::new(again.clone())).unwrap();
    let live = lines.row().await;
    assert_eq!(live["row"]["id"], again.id.0);
    assert_eq!(live["row"]["content"]["nodes"][0]["text"], "ping");
    drop(rows);
    lines.end().await;

    // Anything else in a query is refused.
    for wrong in ["full=2", "after=x", "rows=1", "after=1&nope"] {
        let answer = reqwest::get(format!("{url}?{wrong}")).await.unwrap();
        assert_eq!(answer.status(), StatusCode::BAD_REQUEST, "{wrong}");
    }
    assert_eq!(
        super::asked(Some("full=1&after=7")),
        Some(Asked {
            after: Some(7),
            full: true
        })
    );
    scope.close(PATIENCE).await;
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_stream_from_now_ends_with_the_service(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    drop(conn);
    let head = from_xiaoming_says(&pool, &place, 1, "早").await.id;
    let mut scope = Scope::new();
    let (url, mut asked) = served(&mut scope).await;
    let (rows, _) = broadcast::channel(16);

    // Without after, nothing from before; with anything else, nothing.
    let answer = follow(&url, &mut asked, &place, &pool, (head, &rows)).await;
    assert_eq!(answer.headers()[HEAD], head.0.to_string());
    let mut lines = Lines {
        answer,
        read: Vec::new(),
    };
    assert_eq!(lines.next().await.unwrap(), "");
    let wrong = reqwest::get(format!("{url}?since=1")).await.unwrap();
    assert_eq!(wrong.status(), StatusCode::BAD_REQUEST);

    // A conversation that doesn't answer.
    let answer = reqwest::get(&url);
    let actor = async {
        let subscribe = asked.recv().await;
        assert!(matches!(subscribe, Some(Signal::Subscribe { .. })));
    };
    let (answer, ()) = tokio::join!(answer, actor);
    let answer = answer.unwrap();
    assert_eq!(answer.status(), StatusCode::SERVICE_UNAVAILABLE);
    let said = answer.text().await.unwrap();
    assert!(
        said.contains("this chat's conversation didn't answer"),
        "{said}"
    );

    // The service stops: the stream ends, and doesn't hold it up.
    // Well within the grace, which would end it anyway.
    let closed = async { tokio::join!(scope.close(PATIENCE), lines.end()) };
    timeout(Duration::from_secs(2), closed).await.unwrap();
}

/// The next line maxx printed, a row.
async fn row(printed: &mut tokio::io::Lines<BufReader<ChildStdout>>) -> Value {
    let line = timeout(PATIENCE, printed.next_line()).await.unwrap();
    serde_json::from_str(&line.unwrap().unwrap()).unwrap()
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn maxx_prints_the_rows_and_opens_the_stream_again(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    drop(conn);
    let first = from_xiaoming_says(&pool, &place, 1, "早").await;
    let ping = from_xiaoming_says(&pool, &place, 2, "ping").await;
    let mut scope = Scope::new();
    let (url, mut asked) = served(&mut scope).await;
    let mut maxx = Command::new("node")
        .arg(MAXX)
        .args(["events", "--after", &format!("#{}", first.id)])
        .env("MAXX_URL", url.replace("/events", ""))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .expect("node runs maxx");
    let mut printed = BufReader::new(maxx.stdout.take().unwrap()).lines();
    let (rows, _) = broadcast::channel(16);
    answer(&mut asked, &place, &pool, (ping.id, &rows)).await;
    assert_eq!(row(&mut printed).await["text"], "ping");
    let live = from_xiaoming_says(&pool, &place, 3, "在吗").await;
    rows.send(Arc::new(live.clone())).unwrap();
    assert_eq!(row(&mut printed).await["id"], live.id.0);

    // The stream ends, a row comes meanwhile; maxx asks again after the
    // last one it printed.
    drop(rows);
    let missed = from_xiaoming_says(&pool, &place, 4, "人呢").await;
    let (rows, _) = broadcast::channel(16);
    answer(&mut asked, &place, &pool, (missed.id, &rows)).await;
    assert_eq!(row(&mut printed).await["id"], missed.id.0);
    maxx.kill().await.unwrap();
    let mut told = String::new();
    let mut stderr = maxx.stderr.take().unwrap();
    stderr.read_to_string(&mut told).await.unwrap();
    assert_eq!(
        told,
        "maxx events: the connection dropped; reconnecting in 1 seconds\n"
    );
    scope.close(PATIENCE).await;
}
