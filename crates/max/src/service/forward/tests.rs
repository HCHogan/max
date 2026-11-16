use std::path::{Path as FilePath, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::body::{Body, Bytes};
use axum::routing::post;
use futures_util::StreamExt;
use max_core::item::Protocol;
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, UnixListener, UnixStream};

use super::router;
use crate::llm::{Upstream, Upstreams};
use crate::scope::Scope;

/// What the provider was asked: the authorization, and the body.
type Asked = Arc<Mutex<Vec<(Option<String>, String)>>>;

/// What a provider answers over Responses.
const RESPONDED: &str = "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":70,\"output_tokens\":5}}}\n\n";

/// What the provider answers: a call of `bash`.
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
    let answering = |answer: &'static str| {
        let asked = Arc::clone(&asked);
        post(move |headers: axum::http::HeaderMap, body: String| {
            let asked = Arc::clone(&asked);
            async move {
                let authorization = headers
                    .get("authorization")
                    .map(|value| value.to_str().unwrap().to_owned());
                asked.lock().unwrap().push((authorization, body));
                ([("content-type", "text/event-stream")], answer)
            }
        })
    };
    let app = axum::Router::new()
        .route("/quiet/chat/completions", post(quiet))
        .route("/v1/chat/completions", answering(ANSWER))
        .route("/other/responses", answering(RESPONDED));
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

/// The agents' own model alone, asked to think hard.
fn upstream(base_url: String) -> Upstreams {
    quiet_within(base_url, Duration::from_secs(120))
}

fn quiet_within(base_url: String, idle: Duration) -> Upstreams {
    Upstreams::only(flash(base_url, idle), Some("high"))
}

fn flash(base_url: String, idle: Duration) -> Upstream {
    Upstream {
        provider: "cliproxy".into(),
        protocol: Protocol::Chat,
        base_url,
        api_key: Some("the-providers-key".into()),
        headers: vec![("x-extra".into(), "1".into())],
        model: "gemini-3.8-flash-high".into(),
        window: 1_000_000,
        max_output: None,
        idle,
    }
}

/// The agents' own model, and another provider's, which speaks
/// Responses and has a key of its own.
fn two(base_url: &str) -> Upstreams {
    let mut upstreams = upstream(base_url.to_owned());
    let other = Upstream {
        provider: "other".into(),
        protocol: Protocol::Responses,
        base_url: base_url.replace("/v1", "/other"),
        api_key: Some("the-others-key".into()),
        headers: Vec::new(),
        model: "team/gpt-6-astra".into(),
        window: 400_000,
        max_output: Some(128_000),
        idle: Duration::from_secs(120),
    };
    upstreams.all.insert(other.reference(), Arc::new(other));
    upstreams
}

/// `/llm` for a VM at a socket in a directory of its own, with the
/// `model`s it may call.
fn vm(scope: &mut Scope, name: &str, model: Option<Upstreams>) -> (PathBuf, PathBuf) {
    let dir = std::env::temp_dir().join(format!("max-forward-{name}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mine.sock");
    let _ = std::fs::remove_file(&socket);
    let listener = UnixListener::bind(&socket).unwrap();
    let app = router(model.map(Arc::new));
    scope.spawn(move |stop| async move {
        let _ = axum::serve(listener, app)
            .with_graceful_shutdown(stop.cancelled_owned())
            .await;
    });
    (dir, socket)
}

const ASK: &str =
    r#"{"model":"anything","stream":true,"messages":[ {"role":"user", "content":"你好"} ]}"#;

#[tokio::test]
async fn an_agents_model_calls_go_on_with_the_providers_key() {
    let mut scope = Scope::new();
    let asked = Asked::default();
    let base_url = provider(&mut scope, Arc::clone(&asked)).await;
    let (dir, socket) = vm(&mut scope, "calls", Some(upstream(base_url)));

    // What the agent's harness is told of the model, and no key.
    let (status, body) = send(&socket, "/llm", None).await;
    assert_eq!(status, "HTTP/1.1 200 OK", "{body}");
    let about: Value = serde_json::from_str(&body).unwrap();
    let flash = json!({
        "api": "openai-completions",
        "model": "cliproxy/gemini-3.8-flash-high",
        "window": 1_000_000,
        "max_output": null,
    });
    let mut told = flash.clone();
    told["effort"] = json!("high");
    told["models"] = json!([flash]);
    assert_eq!(about, told);

    // No token: the socket says whose call it is.
    let (status, body) = send(&socket, "/llm/chat/completions", Some(ASK)).await;
    assert_eq!(status, "HTTP/1.1 200 OK", "{body}");
    assert!(
        body.contains("\"name\":\"bash\"") && body.contains("data: [DONE]"),
        "{body}"
    );
    {
        let asked = asked.lock().unwrap();
        let (authorization, request) = &asked[0];
        assert_eq!(authorization.as_deref(), Some("Bearer the-providers-key"));
        // It named no model max knows, and went to the agents' own: the
        // model in its place, the rest as pi wrote it.
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

    scope.close(Duration::from_secs(5)).await;
    let _ = std::fs::remove_dir_all(dir);
}

/// A call goes to the model it names, with that provider's key, at that
/// protocol's endpoint; one that names none max knows goes to the
/// agents' own.
#[tokio::test]
async fn a_call_goes_to_the_model_it_names() {
    let mut scope = Scope::new();
    let asked = Asked::default();
    let base_url = provider(&mut scope, Arc::clone(&asked)).await;
    let (dir, socket) = vm(&mut scope, "named", Some(two(&base_url)));

    // Both are told of, the agents' own on top with its effort.
    let (_, body) = send(&socket, "/llm", None).await;
    let about: Value = serde_json::from_str(&body).unwrap();
    assert_eq!(about["model"], "cliproxy/gemini-3.8-flash-high");
    assert_eq!(about["effort"], "high");
    let astra = json!({
        "api": "openai-responses",
        "model": "other/team/gpt-6-astra",
        "window": 400_000,
        "max_output": 128_000,
    });
    assert_eq!(about["models"][1], astra);
    assert_eq!(about["models"].as_array().unwrap().len(), 2);

    let ask = r#"{"model":"other/team/gpt-6-astra","reasoning":{"effort":"low","summary":"auto"},"input":"你好"}"#;
    let (status, body) = send(&socket, "/llm/responses", Some(ask)).await;
    assert_eq!(status, "HTTP/1.1 200 OK", "{body}");
    {
        let asked = asked.lock().unwrap();
        let (authorization, request) = &asked[0];
        assert_eq!(authorization.as_deref(), Some("Bearer the-others-key"));
        // The provider's id for it, and the effort as the agent wrote it.
        let forwarded = r#"{"model":"team/gpt-6-astra","reasoning":{"effort":"low","summary":"auto"},"input":"你好"}"#;
        assert_eq!(request, forwarded);
    }

    // Not at the other protocol's endpoint.
    let (status, body) = send(&socket, "/llm/chat/completions", Some(ask)).await;
    assert_eq!(status, "HTTP/1.1 404 Not Found");
    assert!(
        body.contains("other/team/gpt-6-astra is called at /llm/responses"),
        "{body}"
    );

    // The agents' own by its name, asked to think as the agent says; and
    // the provider's id alone, which an agent from before a restart of
    // max may still send, is no name: the agents' own again.
    for (n, model) in ["cliproxy/gemini-3.8-flash-high", "team/gpt-6-astra"]
        .into_iter()
        .enumerate()
    {
        let ask = json!({ "model": model, "reasoning_effort": "xhigh", "messages": [] });
        let ask = ask.to_string();
        let (status, body) = send(&socket, "/llm/chat/completions", Some(&ask)).await;
        assert_eq!(status, "HTTP/1.1 200 OK", "{body}");
        let asked = asked.lock().unwrap();
        let (authorization, request) = &asked[n + 1];
        assert_eq!(authorization.as_deref(), Some("Bearer the-providers-key"));
        let forwarded = json!({ "model": "gemini-3.8-flash-high", "reasoning_effort": "xhigh", "messages": [] });
        assert_eq!(serde_json::from_str::<Value>(request).unwrap(), forwarded);
    }
    assert_eq!(asked.lock().unwrap().len(), 3);

    // Named twice, it goes on with the one name max read.
    let twice = r#"{"model":"cliproxy/gemini-3.8-flash-high","messages":[],"model":"another"}"#;
    let (status, body) = send(&socket, "/llm/chat/completions", Some(twice)).await;
    assert_eq!(status, "HTTP/1.1 200 OK", "{body}");
    assert_eq!(
        asked.lock().unwrap()[3].1,
        r#"{"model":"gemini-3.8-flash-high","messages":[]}"#
    );

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
    let (dir, socket) = vm(&mut scope, "quiet", Some(quiet));

    // Before its last chunk.
    let broken = send(&socket, "/llm/chat/completions", Some(ASK));
    let (status, body) = tokio::time::timeout(Duration::from_secs(5), broken)
        .await
        .expect("the quiet answer is broken off");
    assert_eq!(status, "HTTP/1.1 200 OK");
    assert!(body.contains("data: {\"n\":1}"), "{body}");
    assert!(!body.ends_with("0\r\n\r\n"), "{body}");

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
