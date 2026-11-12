//! The MCP service: JSON-RPC posted over HTTP, stateless, answered with
//! JSON, on a unix socket per VM. Only what the runner's client uses:
//! `ping`, `tools/list` and `tools/call`; notifications are taken and
//! dropped, and a call is cancelled by closing its connection, which
//! drops it. A call is the VM's: the socket says which conversation it
//! is, whose actor runs it, and nothing says which program in the VM
//! made it. A turn's program, a background command, an agent and a unit
//! of Max's own call alike, and have every tool. Until 2026-11-12 a
//! token named the run a call belonged to; see "The MCP channel" in
//! docs/rust-rewrite.md.

use std::sync::Arc;
use std::time::Duration;

use axum::body::Bytes;
use axum::extract::State;
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use max_core::ids::ConversationId;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use tokio::sync::mpsc::UnboundedSender;
use tokio::sync::{Semaphore, oneshot};
use tokio::time::timeout;
use tokio_util::sync::CancellationToken;
use tracing::warn;

use super::Failure;
use super::tool::{self, Spec};
use crate::conversation::Signal;
use max_core::limits::{CALLS_AT_ONCE, Setting};

/// What a call that didn't finish may still have done. Nothing is retried
/// or classified by its effects: what acts on the group goes through the
/// timeline, where the model sees whether it happened.
const MAYBE_DONE: &str =
    "what acts in the chat may have taken effect: look at the records before trying again";
/// JSON-RPC's codes for a request Max doesn't answer.
const PARSE_ERROR: i32 = -32700;
const METHOD_NOT_FOUND: i32 = -32601;
const INVALID_PARAMS: i32 = -32602;

/// Serves the VM of `conversation` on `listener` until `stop`: `/mcp`,
/// whose calls go to the conversation's actor through `calls`, and the VM
/// service's own routes, `host`. A VM's listener is a unix socket; tests'
/// are TCP, which Node's fetch reaches.
pub async fn serve<L>(
    listener: L,
    conversation: ConversationId,
    calls: UnboundedSender<Signal>,
    host: axum::Router,
    stop: CancellationToken,
) where
    L: axum::serve::Listener,
    L::Addr: std::fmt::Debug,
{
    let handler = Handler {
        conversation,
        calls,
        slots: Arc::new(Semaphore::new(CALLS_AT_ONCE)),
    };
    // Only POST: there is nothing to stream or end, so a GET or a DELETE
    // gets 405, which clients take for that.
    let app = axum::Router::new()
        .route("/mcp", post(rpc))
        .with_state(handler)
        .merge(host);
    if let Err(error) = axum::serve(listener, app)
        .with_graceful_shutdown(stop.cancelled_owned())
        .await
    {
        warn!(%conversation, %error, "the MCP service stopped");
    }
}

#[derive(Clone)]
struct Handler {
    conversation: ConversationId,
    /// To the conversations' actors, through the table.
    calls: UnboundedSender<Signal>,
    /// How many calls the VM makes at once; more wait their turn.
    slots: Arc<Semaphore>,
}

/// A JSON-RPC request, or with no id a notification.
#[derive(Deserialize)]
struct Request {
    #[serde(default)]
    id: Option<Value>,
    method: String,
    #[serde(default)]
    params: Value,
}

/// `tools/call`'s parameters.
#[derive(Deserialize)]
struct Called {
    name: String,
    #[serde(default)]
    arguments: Option<Map<String, Value>>,
}

/// A request answered with a JSON-RPC error: not a call that failed,
/// which is a result.
#[derive(Serialize)]
struct Refusal {
    code: i32,
    message: String,
}

impl Refusal {
    fn new(code: i32, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

/// A JSON-RPC answer, written with its result as the result is.
#[derive(Serialize)]
struct Envelope {
    jsonrpc: &'static str,
    id: Value,
    #[serde(flatten)]
    outcome: Outcome,
}

#[derive(Serialize)]
#[serde(rename_all = "lowercase")]
enum Outcome {
    Result(Answer),
    Error(Refusal),
}

/// What a request is answered with.
#[derive(Serialize)]
#[serde(untagged)]
enum Answer {
    Value(Value),
    Tools { tools: Vec<Listed> },
    Called(ToolResult),
}

async fn rpc(State(handler): State<Handler>, body: Bytes) -> Response {
    let Ok(request) = serde_json::from_slice::<Request>(&body) else {
        let error = Refusal::new(PARSE_ERROR, "not a JSON-RPC request");
        let answer = Envelope {
            jsonrpc: "2.0",
            id: Value::Null,
            outcome: Outcome::Error(error),
        };
        return reply(StatusCode::BAD_REQUEST, &answer);
    };
    // Such as cancelled: closing the connection is what cancels a call
    // here.
    let Some(id) = request.id else {
        return StatusCode::ACCEPTED.into_response();
    };
    let outcome = match handler.answer(&request.method, request.params).await {
        Ok(result) => Outcome::Result(result),
        Err(refusal) => Outcome::Error(refusal),
    };
    let answer = Envelope {
        jsonrpc: "2.0",
        id,
        outcome,
    };
    reply(StatusCode::OK, &answer)
}

fn reply(status: StatusCode, body: &Envelope) -> Response {
    let json = [(header::CONTENT_TYPE, "application/json")];
    let body = serde_json::to_vec(body).expect("an answer is JSON");
    (status, json, body).into_response()
}

impl Handler {
    async fn answer(&self, method: &str, params: Value) -> Result<Answer, Refusal> {
        match method {
            "ping" => Ok(Answer::Value(json!({}))),
            "tools/list" => {
                let tools = tool::TOOLS.iter().map(listed).collect();
                Ok(Answer::Tools { tools })
            }
            "tools/call" => {
                let Called { name, arguments } =
                    serde_json::from_value(params).map_err(|error| {
                        Refusal::new(
                            INVALID_PARAMS,
                            format!("tools/call's parameters are wrong: {error}"),
                        )
                    })?;
                let args = Value::Object(arguments.unwrap_or_default());
                Ok(Answer::Called(called(self.call(&name, args).await)))
            }
            _ => Err(Refusal::new(
                METHOD_NOT_FOUND,
                format!("there is no method {method}"),
            )),
        }
    }

    /// Has the conversation's actor run the call: its result. The actor
    /// stops it when this stops waiting, as when the caller closes its
    /// connection.
    async fn call(&self, tool: &str, args: Value) -> Result<Value, Failure> {
        let call = async {
            let _slot = self.slots.acquire().await;
            let (reply, result) = oneshot::channel();
            let call = Signal::Call {
                conversation: self.conversation,
                tool: tool.to_owned(),
                args,
                reply,
            };
            self.calls
                .send(call)
                .map_err(|_| Failure::new("closed", "Max is stopping"))?;
            result
                .await
                .unwrap_or_else(|_| Err(Failure::new("closed", "Max stopped before it was done")))
        };
        // The actor holds the call to the conversation's own call time;
        // this is for one that never reaches the actor.
        let longest = Duration::from_secs(*Setting::CallTimeSecs.range().end());
        timeout(longest, call)
            .await
            .unwrap_or_else(|_| Err(late(longest)))
    }
}

/// A call that didn't end within `limit`.
pub(super) fn late(limit: Duration) -> Failure {
    Failure::new(
        "timeout",
        format!("not done in {} seconds; {MAYBE_DONE}", limit.as_secs()),
    )
}

/// A tool as `tools/list` shows it.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Listed {
    name: &'static str,
    description: &'static str,
    input_schema: &'static Map<String, Value>,
    output_schema: &'static Map<String, Value>,
}

fn listed(spec: &'static Spec) -> Listed {
    Listed {
        name: spec.name,
        description: spec.description,
        input_schema: &spec.input,
        output_schema: &spec.output,
    }
}

/// A call's outcome as MCP's tool result: the value, or `{code, message}`
/// with `isError`, structured and as JSON text.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ToolResult {
    content: [Text; 1],
    structured_content: Value,
    is_error: bool,
}

#[derive(Serialize)]
struct Text {
    r#type: &'static str,
    text: String,
}

fn called(outcome: Result<Value, Failure>) -> ToolResult {
    let (value, is_error) = match outcome {
        Ok(value) => (value, false),
        Err(Failure { code, message }) => (json!({ "code": code, "message": message }), true),
    };
    let text = value.to_string();
    ToolResult {
        content: [Text {
            r#type: "text",
            text,
        }],
        structured_content: value,
        is_error,
    }
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};
    use std::time::Duration;

    use chrono::Utc;
    use sqlx::PgPool;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{UnixListener, UnixStream};

    use super::*;
    use crate::conversation::ingest;
    use crate::conversation::testing::{from_xiaoming, group, offset, text};
    use crate::mcp::{Context, Services, testing};
    use crate::scope::Scope;

    /// A directory of the test's own for its sockets.
    fn sockets(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("max-mcp-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// Serves the VM of `context`'s conversation on the unix socket
    /// `socket`, in `scope`, its calls run in `context`.
    fn serve_at(scope: &mut Scope, socket: &Path, context: Context) {
        let _ = std::fs::remove_file(socket);
        let listener = UnixListener::bind(socket).unwrap();
        let conversation = context.place.conversation;
        let calls = testing::answering(scope, context);
        scope.spawn(move |stop| serve(listener, conversation, calls, axum::Router::new(), stop));
    }

    /// Sends `body` to /mcp at `socket` with `method` and `headers`, each a
    /// line ending in CRLF: the reply's status line, and its body.
    async fn exchange(socket: &Path, method: &str, headers: &str, body: &str) -> (String, String) {
        let request = format!(
            "{method} /mcp HTTP/1.1\r\nHost: 127.0.0.1:7777\r\nContent-Type: application/json\r\n\
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

    /// A JSON-RPC request as the runner sends it: the reply's `result` or
    /// `error`.
    async fn post(socket: &Path, method: &str, params: Value) -> Value {
        let mut params = params;
        let name = params["name"]
            .as_str()
            .map(|name| format!("Mcp-Name: {name}\r\n"))
            .unwrap_or_default();
        params["_meta"] = json!({
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities": {},
        });
        let body = json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params });
        let headers = format!("MCP-Protocol-Version: 2026-07-28\r\nMcp-Method: {method}\r\n{name}");
        let (_, reply) = exchange(socket, "POST", &headers, &body.to_string()).await;
        let reply: Value = serde_json::from_str(&reply).unwrap();
        reply
            .get("result")
            .or_else(|| reply.get("error"))
            .cloned()
            .unwrap()
    }

    #[sqlx::test(migrator = "max_db::MIGRATOR")]
    async fn a_call_is_its_vms_conversations(pool: PgPool) {
        let mut conn = pool.acquire().await.unwrap();
        let place = Arc::new(group(&mut conn).await);
        let hello = ingest::inbound(
            &mut conn,
            &place,
            from_xiaoming(1, vec![text("你好")]),
            Utc::now(),
            offset(),
        )
        .await
        .unwrap();
        drop(conn);
        let dir = sockets("calls");
        let socket = dir.join("mine.sock");
        let mut scope = Scope::new();
        let context = Context::check(Services::bare(pool), place);
        serve_at(&mut scope, &socket, context);

        // Every tool, those the prompt doesn't declare too.
        let listed = post(&socket, "tools/list", json!({})).await;
        assert_eq!(listed["tools"][0]["name"], "history", "{listed}");
        assert_eq!(listed["tools"][0]["outputSchema"]["type"], "object");
        let names: Vec<&str> = listed["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|tool| tool["name"].as_str().unwrap())
            .collect();
        let all: Vec<&str> = tool::TOOLS.iter().map(|tool| tool.name).collect();
        assert_eq!(names, all);
        assert!(
            names.contains(&"say") && names.contains(&"file"),
            "{names:?}"
        );

        let id = hello.message.id.0;
        let one = json!({ "around": id, "before": 0, "after": 0 });
        let read = json!({ "name": "history", "arguments": one });
        let result = post(&socket, "tools/call", read).await;
        assert_eq!(result["isError"], false, "{result}");
        assert_eq!(
            result["structuredContent"]["text"],
            format!("[12:01 小明 #{id}]: 你好")
        );
        let missing = json!({ "name": "history", "arguments": { "around": id + 1 } });
        let result = post(&socket, "tools/call", missing).await;
        assert_eq!(result["isError"], true, "{result}");
        assert_eq!(result["structuredContent"]["code"], "not_found");
        // What the runner asked the host for until 2026-11-12 isn't a tool.
        for name in ["histroy", "max.image", "max.file"] {
            let typo = json!({ "name": name, "arguments": {} });
            let result = post(&socket, "tools/call", typo).await;
            assert_eq!(
                result["structuredContent"]["code"], "unknown_tool",
                "{name}"
            );
        }

        scope.close(Duration::from_secs(5)).await;
        let _ = std::fs::remove_dir_all(dir);
    }

    /// What isn't a call: a notification is taken and dropped, there is
    /// nothing to GET, and a method Max doesn't have is an error.
    #[sqlx::test(migrator = "max_db::MIGRATOR")]
    async fn what_isnt_a_call_is_answered_plainly(pool: PgPool) {
        let mut conn = pool.acquire().await.unwrap();
        let place = Arc::new(group(&mut conn).await);
        drop(conn);
        let dir = sockets("plain");
        let socket = dir.join("mine.sock");
        let mut scope = Scope::new();
        serve_at(
            &mut scope,
            &socket,
            Context::check(Services::bare(pool), place),
        );
        // A token, as an older guest's client still sends: nobody reads it.
        let headers = "MCP-Protocol-Version: 2026-07-28\r\nAuthorization: Bearer old\r\n";
        let rpc = async |body: Value| {
            let (status, body) = exchange(&socket, "POST", headers, &body.to_string()).await;
            assert_eq!(status, "HTTP/1.1 200 OK", "{body}");
            serde_json::from_str::<Value>(&body).unwrap()
        };

        let note = json!({ "jsonrpc": "2.0", "method": "notifications/cancelled" });
        let (status, body) = exchange(&socket, "POST", headers, &note.to_string()).await;
        assert_eq!(
            (status.as_str(), body.as_str()),
            ("HTTP/1.1 202 Accepted", "")
        );
        let (status, _) = exchange(&socket, "GET", headers, "").await;
        assert_eq!(status, "HTTP/1.1 405 Method Not Allowed");

        // A result's text is its structured content, for a client that
        // reads only that.
        let call = json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": { "name": "history", "arguments": { "around": 1 } },
        });
        let result = rpc(call).await["result"].clone();
        assert_eq!(result["isError"], true, "{result}");
        let text = result["content"][0]["text"].as_str().unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(text).unwrap(),
            result["structuredContent"]
        );

        let ping = json!({ "jsonrpc": "2.0", "id": 3, "method": "ping" });
        assert_eq!(rpc(ping).await["result"], json!({}));
        for method in ["resources/list", "initialize"] {
            let unknown = json!({ "jsonrpc": "2.0", "id": 4, "method": method });
            assert_eq!(rpc(unknown).await["error"]["code"], METHOD_NOT_FOUND);
        }
        let (status, body) = exchange(&socket, "POST", headers, "{").await;
        assert_eq!(status, "HTTP/1.1 400 Bad Request", "{body}");

        scope.close(Duration::from_secs(5)).await;
        let _ = std::fs::remove_dir_all(dir);
    }
}
