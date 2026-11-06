use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use reqwest::StatusCode;
use serde_json::{Value, json};
use sqlx::PgPool;
use tokio::net::TcpListener;
use tokio::process::Command;
use tokio::sync::mpsc::{UnboundedReceiver, unbounded_channel};
use tokio::time::sleep;

use super::beating;
use crate::conversation::testing::group;
use crate::job::{Link, Question};
use crate::llm::Upstream;
use crate::mcp::{Caller, Context, Services, Sessions, serve};
use crate::scope::Scope;

const CLIENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../nix/client.js");
const QUESTION: &str = r#"{"question":"选火锅还是烧烤？"}"#;

/// A job's caller, and where its questions come.
fn job() -> (Caller, UnboundedReceiver<Question>) {
    let (asks, questions) = unbounded_channel();
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
        asks,
    };
    (Caller::Job(Arc::new(link)), questions)
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_question_waits_for_its_answer_with_a_heartbeat(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    drop(conn);
    let conversation = place.conversation;
    let context = |caller| Context {
        caller,
        ..Context::check(Services::bare(pool.clone()), Arc::clone(&place))
    };
    let sessions = Sessions::default();
    let (caller, mut questions) = job();
    let grant = sessions.open(context(caller));
    let (caller, over) = job();
    let ended = sessions.open(context(caller));
    drop(over);
    let check = sessions.open(context(Caller::Check));

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/job/ask", listener.local_addr().unwrap());
    let app = beating(conversation, sessions, Duration::from_millis(50));
    let mut scope = Scope::new();
    scope.spawn(move |stop| async move {
        let _ = axum::serve(listener, app)
            .with_graceful_shutdown(stop.cancelled_owned())
            .await;
    });
    let client = reqwest::Client::new();
    let ask =
        |token: &str, body: &'static str| client.post(&url).bearer_auth(token).body(body).send();

    // Answered after a while: heartbeats, then the answer.
    let answering = async {
        let question = questions.recv().await.unwrap();
        assert_eq!(question.text, "选火锅还是烧烤？");
        sleep(Duration::from_millis(150)).await;
        question.answer.send(Some("火锅".into())).unwrap();
    };
    let asking = async { ask(grant.token(), QUESTION).await.unwrap().text().await };
    let (body, ()) = tokio::join!(asking, answering);
    let body = body.unwrap();
    assert!(body.starts_with('\n'), "{body:?}");
    assert!(body.ends_with("{\"answer\":\"火锅\"}\n"), "{body:?}");

    // Given up on, the job gone, or its session closed: null.
    let giving_up = async {
        let question = questions.recv().await.unwrap();
        question.answer.send(None).unwrap();
    };
    let (body, ()) = tokio::join!(ask(grant.token(), QUESTION), giving_up);
    assert_eq!(body.unwrap().text().await.unwrap(), "{\"answer\":null}\n");
    let token = grant.token().to_owned();
    let closing = async {
        let question = questions.recv().await.unwrap();
        drop(grant);
        question
    };
    let (body, _question) = tokio::join!(ask(&token, QUESTION), closing);
    let body = body.unwrap().text().await.unwrap();
    assert!(body.ends_with("{\"answer\":null}\n"), "{body:?}");

    let status = |response: reqwest::Result<reqwest::Response>| response.unwrap().status();
    assert_eq!(
        status(ask(&token, QUESTION).await),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        status(ask(check.token(), QUESTION).await),
        StatusCode::FORBIDDEN
    );
    assert_eq!(status(ask(ended.token(), QUESTION).await), StatusCode::GONE);
    assert_eq!(
        status(ask(ended.token(), "{}").await),
        StatusCode::BAD_REQUEST
    );

    scope.close(Duration::from_secs(5)).await;
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn maxxs_client_asks_for_a_job(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    drop(conn);
    let conversation = place.conversation;
    let sessions = Sessions::default();
    let (caller, mut questions) = job();
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
          const answered = await job({ url, token: process.env.TOKEN }).ask("选火锅还是烧烤？");
          const refused = await job({ url, token: "nope" }).ask("几个人？");
          console.log(JSON.stringify([answered, refused]));
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
    let answering = async {
        let question = questions.recv().await.unwrap();
        assert_eq!(question.text, "选火锅还是烧烤？");
        question.answer.send(Some("火锅".into())).unwrap();
    };
    let (out, ()) = tokio::join!(node, answering);
    let out = out.unwrap();
    assert!(out.status.success());
    let outcomes: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(outcomes[0], json!({ "ok": true, "value": "火锅" }));
    assert_eq!(outcomes[1]["ok"], false);
    assert_eq!(outcomes[1]["error"]["code"], "refused");

    scope.close(Duration::from_secs(5)).await;
}
