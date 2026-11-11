use std::path::Path as FilePath;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::body::{Body, Bytes};
use axum::routing::post;
use futures_util::StreamExt;
use serde_json::{Value, json};
use sqlx::PgPool;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, UnixListener, UnixStream};

use tokio::sync::mpsc::{UnboundedReceiver, unbounded_channel};

use crate::conversation::testing::group;
use crate::job::{Called, Link};
use crate::llm::Upstream;
use crate::mcp::{Caller, Context, Services, Sessions, serve};
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

/// The status line and the body of a request over the VM's socket.
async fn send(socket: &FilePath, path: &str, headers: &str, body: &str) -> (String, String) {
    let request = format!(
        "POST {path} HTTP/1.1\r\nHost: 127.0.0.1:7777\r\nContent-Type: application/json\r\n\
         Accept: application/json, text/event-stream\r\n{headers}\
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
        protocol: max_core::item::Protocol::Chat,
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

/// A job's caller with `upstream`, and what it is told of its calls.
fn linked(upstream: Upstream) -> (Caller, UnboundedReceiver<Called>) {
    let (called, calls) = unbounded_channel();
    let link = Link {
        upstream: Arc::new(upstream),
        called,
        hooks: unbounded_channel().0,
        stop: tokio_util::sync::CancellationToken::new(),
        poster: crate::conversation::Poster::for_agent(unbounded_channel().0, 1),
    };
    (Caller::Job(Arc::new(link)), calls)
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_jobs_model_calls_go_on_with_the_providers_key(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    drop(conn);
    let conversation = place.conversation;
    let context = |caller| Context {
        caller,
        ..Context::check(Services::bare(pool.clone()), Arc::clone(&place))
    };
    let mut scope = Scope::new();
    let asked = Asked::default();
    let base_url = provider(&mut scope, Arc::clone(&asked)).await;
    let sessions = Sessions::default();
    let quiet = base_url.replace("/v1", "/quiet");
    let (caller, mut calls) = linked(upstream(base_url));
    let job = sessions.open(context(caller));
    let run = sessions.open(context(Caller::Check));
    let (caller, mut stalled_calls) = linked(quiet_within(quiet, Duration::from_millis(200)));
    let stalled = sessions.open(context(caller));

    let dir = std::env::temp_dir().join(format!("max-forward-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mine.sock");
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket).unwrap();
    let served = sessions.clone();
    scope.spawn(move |stop| serve(listener, conversation, served, stop));

    let bearer = |token: &str| format!("Authorization: Bearer {token}\r\n");
    let ask =
        r#"{"model":"anything","stream":true,"messages":[ {"role":"user", "content":"你好"} ]}"#;
    let (status, body) = send(&socket, "/llm/chat/completions", &bearer(job.token()), ask).await;
    assert_eq!(status, "HTTP/1.1 200 OK", "{body}");
    assert!(
        body.contains("\"name\":\"bash\"") && body.contains("data: [DONE]"),
        "{body}"
    );
    // What it used and called, read on the way.
    let called = calls.recv().await.unwrap();
    let cached = max_core::item::Usage {
        input: 1200,
        cached: 1000,
        output: 30,
        reasoning: 0,
    };
    assert_eq!(
        (called.usage, called.tools),
        (cached, vec!["bash".to_owned()])
    );
    assert!(called.timing.first.is_some());
    {
        let asked = asked.lock().unwrap();
        let (authorization, request) = &asked[0];
        assert_eq!(authorization.as_deref(), Some("Bearer the-providers-key"));
        // The model in its place, the rest as pi wrote it.
        let forwarded = r#"{"model":"gemini-3.8-flash-high","stream":true,"messages":[ {"role":"user", "content":"你好"} ]}"#;
        assert_eq!(request, forwarded);
    }

    // An answer that stops coming is broken off, before its last chunk.
    let (path, token) = ("/llm/chat/completions", bearer(stalled.token()));
    let broken = send(&socket, path, &token, ask);
    let (status, body) = tokio::time::timeout(Duration::from_secs(5), broken)
        .await
        .expect("the quiet answer is broken off");
    assert_eq!(status, "HTTP/1.1 200 OK");
    assert!(body.contains("data: {\"n\":1}"), "{body}");
    assert!(!body.ends_with("0\r\n\r\n"), "{body}");
    // A call all the same, which used nothing the provider counted.
    let called = stalled_calls.recv().await.unwrap();
    assert_eq!(called.usage, max_core::item::Usage::default());
    assert!(called.tools.is_empty());

    // Not the protocol's endpoint, not JSON, a run's session, a job over.
    let status = |pair: (String, String)| pair.0;
    let refused = send(&socket, "/llm/responses", &bearer(job.token()), ask).await;
    assert_eq!(status(refused), "HTTP/1.1 404 Not Found");
    let refused = send(
        &socket,
        "/llm/chat/completions",
        &bearer(job.token()),
        "[1]",
    )
    .await;
    assert_eq!(status(refused), "HTTP/1.1 400 Bad Request");
    let refused = send(&socket, "/llm/chat/completions", &bearer(run.token()), ask).await;
    assert_eq!(status(refused), "HTTP/1.1 403 Forbidden");
    let token = job.token().to_owned();
    drop(job);
    let refused = send(&socket, "/llm/chat/completions", &bearer(&token), ask).await;
    assert_eq!(status(refused), "HTTP/1.1 401 Unauthorized");
    assert_eq!(asked.lock().unwrap().len(), 1);
    // Refused before it went on: no call.
    assert!(calls.try_recv().is_err());

    scope.close(Duration::from_secs(5)).await;
    let _ = std::fs::remove_dir_all(dir);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_job_calls_only_the_tools_that_dont_act_in_the_group(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    drop(conn);
    let conversation = place.conversation;
    let sessions = Sessions::default();
    let (caller, _calls) = linked(upstream("http://127.0.0.1:9/v1".into()));
    let job = sessions.open(Context {
        caller,
        ..Context::check(Services::bare(pool), place)
    });
    let dir = std::env::temp_dir().join(format!("max-forward-tools-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mine.sock");
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket).unwrap();
    let mut scope = Scope::new();
    let served = sessions.clone();
    scope.spawn(move |stop| serve(listener, conversation, served, stop));

    let mcp = |method: &str, name: Option<&str>| {
        let mut headers = format!(
            "MCP-Protocol-Version: 2026-07-28\r\nMcp-Method: {method}\r\nAuthorization: Bearer {}\r\n",
            job.token()
        );
        if let Some(name) = name {
            headers += &format!("Mcp-Name: {name}\r\n");
        }
        headers
    };
    let meta = json!({
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": {},
    });
    let list =
        json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": { "_meta": meta } });
    let (_, body) = send(&socket, "/mcp", &mcp("tools/list", None), &list.to_string()).await;
    let listed: Value = serde_json::from_str(&body).unwrap();
    let names: Vec<&str> = listed["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tool| tool["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["history", "web_search", "ask", "answer"]);

    let call = json!({ "jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
        "name": "send_image", "arguments": { "path": "a.png" }, "_meta": meta,
    }});
    let headers = mcp("tools/call", Some("send_image"));
    let (_, body) = send(&socket, "/mcp", &headers, &call.to_string()).await;
    let called: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(called["result"]["isError"], true, "{body}");
    assert_eq!(called["result"]["structuredContent"]["code"], "not_allowed");

    scope.close(std::time::Duration::from_secs(5)).await;
    let _ = std::fs::remove_dir_all(dir);
}
