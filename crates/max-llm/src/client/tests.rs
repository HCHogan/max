use std::collections::BTreeSet;

use max_core::item::{ItemKind, ModelTag};
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use super::*;

fn request() -> Request {
    Request {
        model: ModelTag {
            protocol: Protocol::Chat,
            model: "deepseek-pro".into(),
        },
        items: Vec::new(),
        tools: &[],
        max_output: None,
        roster: BTreeSet::new(),
    }
}

async fn serve() -> (TcpListener, Client) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let provider = Provider {
        base_url: format!("http://{}/v1/", listener.local_addr().unwrap()),
        api_key: Some("sk-test".into()),
        headers: vec![("x-team".into(), "max".into())],
        idle_timeout: Duration::from_millis(300),
    };
    (listener, Client::new(provider).unwrap())
}

/// Accepts one request: its head and its JSON body.
async fn accept(listener: &TcpListener) -> (TcpStream, String, Value) {
    let (mut socket, _) = listener.accept().await.unwrap();
    let mut seen = Vec::new();
    let mut buffer = [0; 4096];
    let head_end = loop {
        let n = socket.read(&mut buffer).await.unwrap();
        seen.extend_from_slice(&buffer[..n]);
        if let Some(end) = seen.windows(4).position(|w| w == b"\r\n\r\n") {
            break end + 4;
        }
    };
    let head = String::from_utf8_lossy(&seen[..head_end]).to_lowercase();
    let length: usize = head
        .lines()
        .find_map(|line| line.strip_prefix("content-length: "))
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    while seen.len() < head_end + length {
        let n = socket.read(&mut buffer).await.unwrap();
        seen.extend_from_slice(&buffer[..n]);
    }
    let body = serde_json::from_slice(&seen[head_end..]).unwrap();
    (socket, head, body)
}

async fn respond(socket: &mut TcpStream, status: &str, content_type: &str) {
    let head =
        format!("HTTP/1.1 {status}\r\ncontent-type: {content_type}\r\nconnection: close\r\n\r\n");
    socket.write_all(head.as_bytes()).await.unwrap();
}

async fn send(socket: &mut TcpStream, text: &str) {
    socket.write_all(text.as_bytes()).await.unwrap();
    socket.flush().await.unwrap();
}

fn data(chunk: &Value) -> String {
    format!("data: {chunk}\n\n")
}

#[tokio::test]
async fn a_streamed_call() {
    let (listener, client) = serve().await;
    let server = async {
        let (mut socket, head, body) = accept(&listener).await;
        assert!(head.starts_with("post /v1/chat/completions "), "{head}");
        assert!(head.contains("authorization: bearer sk-test"));
        assert!(head.contains("x-team: max"));
        assert_eq!(body["stream"], true);
        respond(&mut socket, "200 OK", "text/event-stream").await;
        // A keep-alive comment, then an event split across writes.
        send(&mut socket, ": keep-alive\n\n").await;
        let delta = json!({ "choices": [{ "index": 0, "delta": { "content": "早" } }] });
        let text = data(&delta);
        let (first, second) = text.split_at(10);
        send(&mut socket, first).await;
        send(&mut socket, second).await;
        let finish = json!({ "choices": [{ "index": 0, "delta": {}, "finish_reason": "stop" }] });
        send(&mut socket, &data(&finish)).await;
        send(&mut socket, "data: [DONE]\n\n").await;
    };
    let call = async {
        let mut call = client.call(&request(), &Options::default()).await.unwrap();
        let mut events = Vec::new();
        while let Some(event) = call.next().await.unwrap() {
            events.push(event);
        }
        (events, call.finish().unwrap())
    };
    let ((events, output), ()) = tokio::join!(call, server);
    assert_eq!(events, [Event::Text("早".into())]);
    assert_eq!(
        output.items[0].kind,
        ItemKind::Assistant { text: "早".into() }
    );
}

#[tokio::test]
async fn refusals_and_failures() {
    let (listener, client) = serve().await;
    let server = async {
        let (mut socket, ..) = accept(&listener).await;
        respond(&mut socket, "429 Too Many Requests", "application/json").await;
        send(&mut socket, r#"{"error":{"message":"slow down"}}"#).await;
        drop(socket);

        let (mut socket, ..) = accept(&listener).await;
        respond(&mut socket, "200 OK", "application/json").await;
        send(
            &mut socket,
            r#"{"error":{"code":"server_error","message":"busy"}}"#,
        )
        .await;
    };
    let calls = async {
        let limited = client.call(&request(), &Options::default()).await;
        let failed = client.call(&request(), &Options::default()).await;
        (limited.err().unwrap(), failed.err().unwrap())
    };
    let ((limited, failed), ()) = tokio::join!(calls, server);
    assert!(limited.retryable());
    assert_eq!(
        limited.to_string(),
        r#"the provider answered 429: {"error":{"message":"slow down"}}"#
    );
    assert_eq!(
        failed.to_string(),
        "the provider failed the response: server_error: busy"
    );
}

#[tokio::test]
async fn silence_and_cut_offs() {
    let (listener, client) = serve().await;
    let delta = json!({ "choices": [{ "index": 0, "delta": { "content": "早" } }] });
    let server = async {
        // Stops sending, without closing.
        let (mut socket, ..) = accept(&listener).await;
        respond(&mut socket, "200 OK", "text/event-stream").await;
        send(&mut socket, &data(&delta)).await;
        let silent = socket;
        // Closes before the response completes.
        let (mut socket, ..) = accept(&listener).await;
        respond(&mut socket, "200 OK", "text/event-stream").await;
        send(&mut socket, &data(&delta)).await;
        drop(socket);
        // Open until the test is done with it.
        silent
    };
    let calls = async {
        let mut silent = client.call(&request(), &Options::default()).await.unwrap();
        assert_eq!(silent.next().await.unwrap(), Some(Event::Text("早".into())));
        let idle = silent.next().await.unwrap_err();

        let mut cut = client.call(&request(), &Options::default()).await.unwrap();
        assert_eq!(cut.next().await.unwrap(), Some(Event::Text("早".into())));
        assert_eq!(cut.next().await.unwrap(), None);
        (idle, cut.finish().unwrap_err())
    };
    let ((idle, cut), _socket) = tokio::join!(calls, server);
    assert!(matches!(idle, Error::Idle(_)), "{idle:?}");
    assert!(matches!(cut, Error::Truncated), "{cut:?}");
    assert!(idle.retryable() && cut.retryable());
}
