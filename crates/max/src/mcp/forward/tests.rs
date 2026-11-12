use std::path::{Path as FilePath, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::body::{Body, Bytes};
use axum::routing::post;
use futures_util::StreamExt;
use max_core::ids::ConversationId;
use max_core::item::{Protocol, Usage};
use serde_json::{Value, json};
use sqlx::PgPool;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, UnixListener, UnixStream};

use super::{Model, router};
use crate::conversation::testing::group;
use crate::llm::Upstream;
use crate::mcp::{Sessions, serve_with};
use crate::scope::Scope;

/// What the provider was asked: the authorization, and the body.
type Asked = Arc<Mutex<Vec<(Option<String>, String)>>>;

/// What the provider answers: a call of `bash`, and what it used.
const ANSWER: &str = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"bash\",\"arguments\":\"{}\"}}]}}]}\n\n\
     data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":1200,\"completion_tokens\":30,\"prompt_tokens_details\":{\"cached_tokens\":1000}}}\n\n\
     data: [DONE]\n\n";

/// A provider that answers with an event stream; under /quiet, one event
/// and then nothing.
async fn provider(scope: &mut Scope, asked: Asked) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let quiet = || async {
        let first = futures_util::stream::once(async {
            Ok::<_, std::convert::Infallible>(Bytes::from("data: {\"n\":1}\n\n"))
        });
        Body::from_stream(first.chain(futures_util::stream::pending()))
    };
    let app = axum::Router::new()
        .route("/quiet/chat/completions", post(quiet))
        .route(
            "/v1/chat/completions",
            post(move |headers: axum::http::HeaderMap, body: String| {
                let asked = Arc::clone(&asked);
                async move {
                    let authorization = headers
                        .get("authorization")
                        .map(|value| value.to_str().unwrap().to_owned());
                    asked.lock().unwrap().push((authorization, body));
                    ([("content-type", "text/event-stream")], ANSWER)
                }
            }),
        );
    scope.spawn(move |stop| async move {
        let _ = axum::serve(listener, app)
            .with_graceful_shutdown(stop.cancelled_owned())
            .await;
    });
    format!("http://{address}/v1")
}

/// The status line and the body of a request over the VM's socket: a
/// POST of `body`, or with none a GET.
async fn send(socket: &FilePath, path: &str, body: Option<&str>) -> (String, String) {
    let method = if body.is_some() { "POST" } else { "GET" };
    let body = body.unwrap_or_default();
    let request = format!(
        "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:7777\r\nContent-Type: application/json\r\n\
         Accept: application/json, text/event-stream\r\n\
         Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let mut stream = UnixStream::connect(socket).await.unwrap();
    stream.write_all(request.as_bytes()).await.unwrap();
    let mut reply = String::new();
    stream.read_to_string(&mut reply).await.unwrap();
    let (head, body) = reply.split_once("\r\n\r\n").unwrap();
    (head.lines().next().unwrap().to_owned(), body.to_owned())
}

fn upstream(base_url: String) -> Upstream {
    quiet_within(base_url, Duration::from_secs(120))
}

fn quiet_within(base_url: String, idle: Duration) -> Upstream {
    Upstream {
        provider: "cliproxy".into(),
        protocol: Protocol::Chat,
        base_url,
        api_key: Some("the-providers-key".into()),
        headers: vec![("x-extra".into(), "1".into())],
        model: "gemini-3.8-flash-high".into(),
        window: 1_000_000,
        max_output: None,
        effort: Some("high".into()),
        idle,
    }
}

/// The service of a VM of conversation 7 at a socket in a directory of
/// its own, with the agents' `model`.
fn vm(scope: &mut Scope, name: &str, model: Option<Model>) -> (PathBuf, PathBuf) {
    let conversation = ConversationId(7);
    let dir = std::env::temp_dir().join(format!("max-forward-{name}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mine.sock");
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket).unwrap();
    let host = router(conversation, model);
    scope.spawn(move |stop| serve_with(listener, conversation, Sessions::default(), host, stop));
    (dir, socket)
}

const ASK: &str =
    r#"{"model":"anything","stream":true,"messages":[ {"role":"user", "content":"你好"} ]}"#;

#[tokio::test]
async fn an_agents_model_calls_go_on_with_the_providers_key() {
    let mut scope = Scope::new();
    let asked = Asked::default();
    let base_url = provider(&mut scope, Arc::clone(&asked)).await;
    let (model, mut used) = Model::heard(upstream(base_url));
    let (dir, socket) = vm(&mut scope, "calls", Some(model));

    // What the agent's harness is told of the model, and no key.
    let (status, body) = send(&socket, "/llm", None).await;
    assert_eq!(status, "HTTP/1.1 200 OK", "{body}");
    let about: Value = serde_json::from_str(&body).unwrap();
    let told = json!({
        "api": "openai-completions",
        "model": "gemini-3.8-flash-high",
        "window": 1_000_000,
        "max_output": null,
        "effort": "high",
    });
    assert_eq!(about, told);

    // No token: the socket says whose call it is.
    let (status, body) = send(&socket, "/llm/chat/completions", Some(ASK)).await;
    assert_eq!(status, "HTTP/1.1 200 OK", "{body}");
    assert!(
        body.contains("\"name\":\"bash\"") && body.contains("data: [DONE]"),
        "{body}"
    );
    // What it used, read on the way, for the VM's conversation.
    let (conversation, called) = used.recv().await.unwrap();
    assert_eq!(conversation, ConversationId(7));
    let cached = Usage {
        input: 1200,
        cached: 1000,
        output: 30,
        reasoning: 0,
    };
    assert_eq!(called.usage, cached);
    assert!(called.timing.first.is_some());
    {
        let asked = asked.lock().unwrap();
        let (authorization, request) = &asked[0];
        assert_eq!(authorization.as_deref(), Some("Bearer the-providers-key"));
        // The model in its place, the rest as pi wrote it.
        let forwarded = r#"{"model":"gemini-3.8-flash-high","stream":true,"messages":[ {"role":"user", "content":"你好"} ]}"#;
        assert_eq!(request, forwarded);
    }

    // Not the protocol's endpoint, not JSON: refused before it goes on.
    let status = |pair: (String, String)| pair.0;
    let refused = send(&socket, "/llm/responses", Some(ASK)).await;
    assert_eq!(status(refused), "HTTP/1.1 404 Not Found");
    let refused = send(&socket, "/llm/chat/completions", Some("[1]")).await;
    assert_eq!(status(refused), "HTTP/1.1 400 Bad Request");
    assert_eq!(asked.lock().unwrap().len(), 1);
    assert!(used.try_recv().is_err(), "no call");

    scope.close(Duration::from_secs(5)).await;
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn an_answer_that_stops_coming_is_broken_off() {
    let mut scope = Scope::new();
    let base_url = provider(&mut scope, Asked::default()).await;
    let quiet = quiet_within(
        base_url.replace("/v1", "/quiet"),
        Duration::from_millis(200),
    );
    let (model, mut used) = Model::heard(quiet);
    let (dir, socket) = vm(&mut scope, "quiet", Some(model));

    // Before its last chunk.
    let broken = send(&socket, "/llm/chat/completions", Some(ASK));
    let (status, body) = tokio::time::timeout(Duration::from_secs(5), broken)
        .await
        .expect("the quiet answer is broken off");
    assert_eq!(status, "HTTP/1.1 200 OK");
    assert!(body.contains("data: {\"n\":1}"), "{body}");
    assert!(!body.ends_with("0\r\n\r\n"), "{body}");
    // A call all the same, which used nothing the provider counted.
    let (_, called) = used.recv().await.unwrap();
    assert_eq!(called.usage, Usage::default());

    scope.close(Duration::from_secs(5)).await;
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn without_a_model_for_them_there_is_nothing_to_call() {
    let mut scope = Scope::new();
    let (dir, socket) = vm(&mut scope, "none", None);
    for body in [None, Some(ASK)] {
        let path = if body.is_some() {
            "/llm/chat/completions"
        } else {
            "/llm"
        };
        let (status, body) = send(&socket, path, body).await;
        assert_eq!(status, "HTTP/1.1 404 Not Found");
        assert!(
            body.contains("no model is configured for background agents"),
            "{body}"
        );
    }
    scope.close(Duration::from_secs(5)).await;
    let _ = std::fs::remove_dir_all(dir);
}

/// What the calls used is recorded for the conversation whose VM made
/// them, as a background agent's.
#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn what_the_agents_use_is_the_conversations(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let conversation = group(&mut conn).await.conversation;
    drop(conn);
    let mut scope = Scope::new();
    let asked = Asked::default();
    let base_url = provider(&mut scope, Arc::clone(&asked)).await;
    let model = Model::start(upstream(base_url), pool.clone(), &mut scope);
    let dir = std::env::temp_dir().join(format!("max-forward-used-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mine.sock");
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket).unwrap();
    let host = router(conversation, Some(model));
    scope.spawn(move |stop| serve_with(listener, conversation, Sessions::default(), host, stop));

    let (status, body) = send(&socket, "/llm/chat/completions", Some(ASK)).await;
    assert_eq!(status, "HTTP/1.1 200 OK", "{body}");
    let recorded = async {
        loop {
            let rows: Vec<(String, String, i64, i64)> = sqlx::query_as(
                "select purpose, model, input, cached from llm_usage where conversation_id = $1",
            )
            .bind(conversation.0)
            .fetch_all(&pool)
            .await
            .unwrap();
            if !rows.is_empty() {
                return rows;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    };
    let rows = tokio::time::timeout(Duration::from_secs(5), recorded)
        .await
        .expect("the call is recorded");
    let model = "gemini-3.8-flash-high".to_owned();
    assert_eq!(rows, [("job".to_owned(), model, 1200, 1000)]);

    scope.close(Duration::from_secs(5)).await;
    let _ = std::fs::remove_dir_all(dir);
}
