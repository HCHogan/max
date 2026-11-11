use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use reqwest::StatusCode;
use serde_json::{Value, json};
use sqlx::PgPool;
use tokio::net::TcpListener;
use tokio::process::Command;
use tokio::sync::mpsc::{UnboundedReceiver, unbounded_channel};
use tokio::sync::oneshot;
use tokio::time::sleep;
use tokio_util::sync::CancellationToken;

use super::beating;
use crate::conversation::Poster;
use crate::conversation::testing::group;
use crate::job::{Hook, Link, Report, Turn};
use crate::llm::Upstream;
use crate::mcp::{Caller, Context, Services, Sessions, serve};
use crate::scope::Scope;
use max_core::ids::ConversationId;

const CLIENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../nix/client.js");
const SETTLING: &str = r#"{"settling":true}"#;

/// A job's caller, where its harness's calls come, and its stop.
fn job() -> (Caller, UnboundedReceiver<Hook>, CancellationToken) {
    let (hooks, hooked) = unbounded_channel();
    let stop = CancellationToken::new();
    let link = Link {
        upstream: Arc::new(Upstream {
            provider: "cliproxy".into(),
            protocol: max_core::item::Protocol::Chat,
            base_url: "http://127.0.0.1:9/v1".into(),
            api_key: None,
            headers: Vec::new(),
            model: "m".into(),
            window: 1_000_000,
            max_output: None,
            effort: None,
            idle: Duration::from_secs(120),
        }),
        called: unbounded_channel().0,
        hooks,
        stop: stop.clone(),
        poster: Poster::for_agent(unbounded_channel().0, 1),
    };
    (Caller::Job(Arc::new(link)), hooked, stop)
}

/// The next of `hooks`, a turn's end: whether it settles, and where its
/// answer goes.
async fn turned(hooks: &mut UnboundedReceiver<Hook>) -> (bool, oneshot::Sender<Turn>) {
    match hooks.recv().await {
        Some(Hook::Turn { settling, reply }) => (settling, reply),
        other => panic!("{other:?}"),
    }
}

fn steered(steers: &[&str]) -> Turn {
    Turn {
        steers: steers.iter().map(ToString::to_string).collect(),
        stop: false,
    }
}

/// Serves `sessions`' `/job/…` with a 50 ms heartbeat: its base URL.
async fn served(scope: &mut Scope, conversation: ConversationId, sessions: Sessions) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let app = beating(conversation, sessions, Duration::from_millis(50));
    scope.spawn(move |stop| async move {
        let _ = axum::serve(listener, app)
            .with_graceful_shutdown(stop.cancelled_owned())
            .await;
    });
    url
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_settling_turn_waits_with_a_heartbeat(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    drop(conn);
    let conversation = place.conversation;
    let context = |caller| Context {
        caller,
        ..Context::check(Services::bare(pool.clone()), Arc::clone(&place))
    };
    let sessions = Sessions::default();
    let (caller, mut hooks, _stop) = job();
    let grant = sessions.open(context(caller));
    let (caller, over, _stop) = job();
    let ended = sessions.open(context(caller));
    drop(over);
    let check = sessions.open(context(Caller::Check));

    let mut scope = Scope::new();
    let url = served(&mut scope, conversation, sessions).await + "/job/turn";
    let client = reqwest::Client::new();
    let settle =
        |token: &str, body: &'static str| client.post(&url).bearer_auth(token).body(body).send();

    // Held a while: heartbeats, then what came for it.
    let answering = async {
        let (settling, reply) = turned(&mut hooks).await;
        assert!(settling);
        sleep(Duration::from_millis(150)).await;
        reply
            .send(steered(&["[ask#1 回答] Max\n答：火锅"]))
            .unwrap();
    };
    let settling = async { settle(grant.token(), SETTLING).await.unwrap().text().await };
    let (body, ()) = tokio::join!(settling, answering);
    let body = body.unwrap();
    assert!(body.starts_with('\n'), "{body:?}");
    let line = r#"{"steers":["[ask#1 回答] Max\n答：火锅"],"stop":false}"#;
    assert!(body.ends_with(&format!("{line}\n")), "{body:?}");

    // Dropped, as the job does once it's over, or its session closed:
    // the stream ends with nothing on it.
    let dropping = async {
        drop(turned(&mut hooks).await);
    };
    let (body, ()) = tokio::join!(settle(grant.token(), SETTLING), dropping);
    let body = body.unwrap().text().await.unwrap();
    assert!(body.trim().is_empty(), "{body:?}");
    let token = grant.token().to_owned();
    let closing = async {
        let held = turned(&mut hooks).await;
        drop(grant);
        held
    };
    let (body, _held) = tokio::join!(settle(&token, SETTLING), closing);
    let body = body.unwrap().text().await.unwrap();
    assert!(body.trim().is_empty(), "{body:?}");

    let status = |response: reqwest::Result<reqwest::Response>| response.unwrap().status();
    assert_eq!(
        status(settle(&token, SETTLING).await),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        status(settle(check.token(), SETTLING).await),
        StatusCode::FORBIDDEN
    );
    assert_eq!(
        status(settle(ended.token(), SETTLING).await),
        StatusCode::GONE
    );
    assert_eq!(
        status(settle(ended.token(), r#"{"settling":3}"#).await),
        StatusCode::BAD_REQUEST
    );

    scope.close(Duration::from_secs(5)).await;
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_turn_takes_the_steers_and_the_stop_is_streamed(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    drop(conn);
    let conversation = place.conversation;
    let context = |caller| Context {
        caller,
        ..Context::check(Services::bare(pool.clone()), Arc::clone(&place))
    };
    let sessions = Sessions::default();
    let (caller, mut hooks, stop) = job();
    let grant = sessions.open(context(caller));
    let (caller, over, _stop) = job();
    let ended = sessions.open(context(caller));
    drop(over);

    let mut scope = Scope::new();
    let url = served(&mut scope, conversation, sessions.clone()).await;
    let client = reqwest::Client::new();
    let post = |path: &str, token: &str, body: &'static str| {
        client
            .post(format!("{url}{path}"))
            .bearer_auth(token)
            .body(body)
            .send()
    };
    let stopping = |token: &str| {
        client
            .get(format!("{url}/job/stop"))
            .bearer_auth(token)
            .send()
    };

    // A turn's end takes what the job gives it.
    let giving = async {
        let (settling, reply) = turned(&mut hooks).await;
        assert!(!settling);
        reply.send(steered(&["先看 A", "再看 B"])).unwrap();
    };
    let (turned, ()) = tokio::join!(post("/job/turn", grant.token(), ""), giving);
    let turned: Value = turned.unwrap().json().await.unwrap();
    assert_eq!(
        turned,
        json!({ "steers": ["先看 A", "再看 B"], "stop": false })
    );
    // One the job dropped, as it does once it's over, took none.
    let dropping = async {
        drop(hooks.recv().await);
    };
    let (turned, ()) = tokio::join!(post("/job/turn", grant.token(), ""), dropping);
    assert_eq!(turned.unwrap().status(), StatusCode::GONE);
    let turned = post("/job/turn", ended.token(), "").await.unwrap();
    assert_eq!(turned.status(), StatusCode::GONE);

    // The stop: heartbeats until it comes, then at once.
    let stopped = async {
        sleep(Duration::from_millis(150)).await;
        stop.cancel();
    };
    let (body, ()) = tokio::join!(
        async { stopping(grant.token()).await.unwrap().text().await },
        stopped
    );
    let body = body.unwrap();
    assert!(body.starts_with('\n'), "{body:?}");
    assert!(body.ends_with("{\"stop\":true}\n"), "{body:?}");
    let again = stopping(grant.token()).await.unwrap().text().await.unwrap();
    assert_eq!(again, "{\"stop\":true}\n");
    // Over before any stop: nothing.
    let (caller, _hooks, _stop) = job();
    let short = sessions.open(context(caller));
    let token = short.token().to_owned();
    let closing = async move {
        sleep(Duration::from_millis(120)).await;
        drop(short);
    };
    let (body, ()) = tokio::join!(
        async { stopping(&token).await.unwrap().text().await },
        closing
    );
    let body = body.unwrap();
    assert!(!body.is_empty() && body.trim().is_empty(), "{body:?}");
    assert_eq!(
        stopping(&token).await.unwrap().status(),
        StatusCode::UNAUTHORIZED
    );

    // The report, once.
    let report = r#"{"text":"查到了","error":null}"#;
    let reported = post("/job/report", grant.token(), report).await.unwrap();
    assert_eq!(reported.status(), StatusCode::OK);
    let Some(Hook::Report(got)) = hooks.recv().await else {
        panic!("not a report");
    };
    assert_eq!(
        got,
        Report {
            text: Some("查到了".into()),
            error: None
        }
    );
    let refused = post("/job/report", grant.token(), r#"{"text":3}"#)
        .await
        .unwrap();
    assert_eq!(refused.status(), StatusCode::BAD_REQUEST);

    scope.close(Duration::from_secs(5)).await;
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn maxxs_client_keeps_a_jobs_contract(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    drop(conn);
    let conversation = place.conversation;
    let sessions = Sessions::default();
    let (caller, mut hooks, stop) = job();
    let grant = sessions.open(Context {
        caller,
        ..Context::check(Services::bare(pool), place)
    });
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mcp = format!("http://{}/mcp", listener.local_addr().unwrap());
    let mut scope = Scope::new();
    let served = sessions.clone();
    scope.spawn(move |stop| serve(listener, conversation, served, stop));

    let script = r#"
        const { job } = require(process.env.CLIENT);
        const url = process.env.MAXX_MCP;
        (async () => {
          const ours = job({ url, token: process.env.TOKEN });
          const turned = await ours.turn();
          const settled = await ours.turn({ settling: true });
          const stopped = await ours.stopped(new AbortController().signal);
          const reported = await ours.report({ text: "订了火锅" });
          const theirs = job({ url, token: "nope" });
          const refused = await theirs.turn({ settling: true });
          const over = await theirs.stopped();
          console.log(JSON.stringify([turned, settled, stopped, reported, refused, over]));
        })();
    "#;
    let node = Command::new("node")
        .args(["-e", script])
        .env("CLIENT", CLIENT)
        .env("MAXX_MCP", &mcp)
        .env("TOKEN", grant.token())
        .stdout(Stdio::piped())
        .kill_on_drop(true)
        .output();
    let host = async {
        let (settling, reply) = turned(&mut hooks).await;
        assert!(!settling);
        reply.send(steered(&["要包间"])).unwrap();
        // Held past a heartbeat of the real service's, 30 seconds, would
        // be too slow for a test: the client reads past empty lines
        // either way.
        let (settling, reply) = turned(&mut hooks).await;
        assert!(settling);
        sleep(Duration::from_millis(100)).await;
        reply
            .send(steered(&["[ask#1 回答] Max\n答：火锅"]))
            .unwrap();
        stop.cancel();
        match hooks.recv().await {
            Some(Hook::Report(report)) => report,
            other => panic!("{other:?}"),
        }
    };
    let (out, report) = tokio::join!(node, host);
    let out = out.unwrap();
    assert!(out.status.success());
    let outcomes: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(
        outcomes[0],
        json!({ "ok": true, "value": { "steers": ["要包间"], "stop": false } })
    );
    assert_eq!(
        outcomes[1],
        json!({ "ok": true, "value": { "steers": ["[ask#1 回答] Max\n答：火锅"], "stop": false } })
    );
    assert_eq!(outcomes[2], true);
    assert_eq!(outcomes[3], json!({ "ok": true, "value": null }));
    assert_eq!(outcomes[4]["ok"], false);
    assert_eq!(outcomes[4]["error"]["code"], "refused");
    assert_eq!(outcomes[5], false);
    assert_eq!(
        report,
        Report {
            text: Some("订了火锅".into()),
            error: None
        }
    );

    scope.close(Duration::from_secs(5)).await;
}
