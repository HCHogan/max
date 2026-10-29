use std::path::Path as FilePath;
use std::sync::{Arc, Mutex};

use axum::routing::post;
use serde_json::{Value, json};
use sqlx::PgPool;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, UnixListener, UnixStream};

use crate::conversation::testing::{group, offset};
use crate::llm::Upstream;
use crate::mcp::{Context, Sessions, serve};
use crate::scope::Scope;

/// What the provider was asked: the authorization, and the body.
type Asked = Arc<Mutex<Vec<(Option<String>, Value)>>>;

/// A provider that answers with an event stream.
async fn provider(scope: &mut Scope, asked: Asked) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let app = axum::Router::new().route(
        "/v1/chat/completions",
        post(move |headers: axum::http::HeaderMap, body: String| {
            let asked = Arc::clone(&asked);
            async move {
                let authorization = headers
                    .get("authorization")
                    .map(|value| value.to_str().unwrap().to_owned());
                asked
                    .lock()
                    .unwrap()
                    .push((authorization, serde_json::from_str(&body).unwrap()));
                let answer = "data: {\"n\":1}\n\ndata: [DONE]\n\n";
                ([("content-type", "text/event-stream")], answer)
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

fn upstream(base_url: String) -> Arc<Upstream> {
    Arc::new(Upstream {
        provider: "cliproxy".into(),
        protocol: max_core::item::Protocol::Chat,
        base_url,
        api_key: Some("the-providers-key".into()),
        headers: vec![("x-extra".into(), "1".into())],
        model: "gemini-3.8-flash-high".into(),
        window: 1_000_000,
        max_output: None,
        effort: Some("high".into()),
    })
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_jobs_model_calls_go_on_with_the_providers_key(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    drop(conn);
    let conversation = place.conversation;
    let context = || Context {
        pool: pool.clone(),
        place: Arc::clone(&place),
        offset: offset(),
        page_tokens: 2000,
        search: None,
        work: None,
        store: None,
        poster: None,
        embedder: None,
        admin: None,
    };
    let mut scope = Scope::new();
    let asked = Asked::default();
    let base_url = provider(&mut scope, Arc::clone(&asked)).await;
    let sessions = Sessions::default();
    let job = sessions.open_job(context(), upstream(base_url));
    let run = sessions.open(context());

    let dir = std::env::temp_dir().join(format!("max-forward-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mine.sock");
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket).unwrap();
    let served = sessions.clone();
    scope.spawn(move |stop| serve(listener, conversation, served, stop));

    let bearer = |token: &str| format!("Authorization: Bearer {token}\r\n");
    let ask = r#"{"model":"anything","stream":true,"messages":[{"role":"user","content":"你好"}]}"#;
    let (status, body) = send(&socket, "/llm/chat/completions", &bearer(job.token()), ask).await;
    assert_eq!(status, "HTTP/1.1 200 OK", "{body}");
    assert!(
        body.contains("data: {\"n\":1}") && body.contains("data: [DONE]"),
        "{body}"
    );
    {
        let asked = asked.lock().unwrap();
        let (authorization, request) = &asked[0];
        assert_eq!(authorization.as_deref(), Some("Bearer the-providers-key"));
        assert_eq!(request["model"], "gemini-3.8-flash-high");
        assert_eq!(request["messages"][0]["content"], "你好");
    }

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

    scope.close(std::time::Duration::from_secs(5)).await;
    let _ = std::fs::remove_dir_all(dir);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_job_calls_only_the_tools_that_read(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    drop(conn);
    let conversation = place.conversation;
    let sessions = Sessions::default();
    let job = sessions.open_job(
        Context {
            pool,
            place,
            offset: offset(),
            page_tokens: 2000,
            search: None,
            work: None,
            store: None,
            poster: None,
            embedder: None,
            admin: None,
        },
        upstream("http://127.0.0.1:9/v1".into()),
    );
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
    assert_eq!(names, ["context_read", "web_search", "context_search"]);

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
