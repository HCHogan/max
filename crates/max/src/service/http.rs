//! Max's tools over HTTP, on a unix socket per VM: `GET /tools` lists
//! them, with their schemas, and `POST /tools/<name>`, with the arguments
//! as a JSON object, calls one. The answer is the call's outcome, `{"ok":
//! true, "value": …}` or `{"ok": false, "error": {"code", "message"}}`;
//! a call is cancelled by closing its connection, which drops it. A call
//! is the VM's: the socket says which conversation it is, whose actor runs
//! it, and nothing says which program in the VM made it. A turn's program,
//! a background command, an agent and a unit of Max's own call alike, and
//! have every tool. Until 2026-11-14 this was a slice of MCP, which
//! nothing but the guest's own client spoke any more; see "The guest's
//! calls" in docs/rust-rewrite.md.

use std::sync::Arc;
use std::time::Duration;

use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use max_core::ids::ConversationId;
use serde::Serialize;
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

/// Serves the VM of `conversation` on `listener` until `stop`: the tools,
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
    let app = axum::Router::new()
        .route("/tools", get(list))
        .route("/tools/{name}", post(call))
        .with_state(handler)
        .merge(host);
    if let Err(error) = axum::serve(listener, app)
        .with_graceful_shutdown(stop.cancelled_owned())
        .await
    {
        warn!(%conversation, %error, "the service to a VM stopped");
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

/// Every tool, those the prompt doesn't declare too.
async fn list() -> Response {
    let tools: Vec<Listed> = tool::TOOLS.iter().map(listed).collect();
    answer(StatusCode::OK, &json!({ "tools": tools }))
}

fn answer(status: StatusCode, body: &Value) -> Response {
    let json = [(header::CONTENT_TYPE, "application/json")];
    let body = serde_json::to_vec(body).expect("an answer is JSON");
    (status, json, body).into_response()
}

/// A call of the tool `name`, its arguments the body: a JSON object, or
/// nothing for none. Its outcome is the answer, whichever way it went;
/// what isn't a call is 400, with why as a failed call's.
async fn call(State(handler): State<Handler>, Path(name): Path<String>, body: Bytes) -> Response {
    let args = if body.is_empty() {
        Ok(Map::new())
    } else {
        serde_json::from_slice::<Map<String, Value>>(&body)
    };
    let Ok(args) = args else {
        let wrong = Failure::new(
            "bad_arguments",
            format!("{name}'s arguments are a JSON object"),
        );
        return answer(StatusCode::BAD_REQUEST, &outcome(Err(wrong)));
    };
    match handler.call(&name, Value::Object(args)).await {
        // With nothing done, Max stopping: as the guest answers once max
        // is gone, 503 with `max-away`, so that the caller asks again
        // when Max is back (nix/client.js).
        Err(failure) if failure.is_away() => {
            (StatusCode::SERVICE_UNAVAILABLE, [("max-away", "1")]).into_response()
        }
        done => answer(StatusCode::OK, &outcome(done)),
    }
}

/// A call's outcome, as its caller reads it.
fn outcome(done: Result<Value, Failure>) -> Value {
    match done {
        Ok(value) => json!({ "ok": true, "value": value }),
        Err(Failure { code, message }) => {
            json!({ "ok": false, "error": { "code": code, "message": message } })
        }
    }
}

impl Handler {
    /// Has the conversation's actor run the call: its result. The actor
    /// stops it when this stops waiting, as when the caller closes its
    /// connection. One that comes as Max stops isn't begun, and is away;
    /// one Max stopped in the middle of isn't, since it may have acted.
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
            self.calls.send(call).map_err(|_| Failure::away())?;
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

/// A tool as the list shows it.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Listed {
    name: &'static str,
    description: &'static str,
    guide: &'static str,
    input_schema: &'static Map<String, Value>,
    output_schema: &'static Map<String, Value>,
}

fn listed(spec: &'static Spec) -> Listed {
    Listed {
        name: spec.name,
        description: spec.description,
        guide: &spec.guide,
        input_schema: &spec.input,
        output_schema: &spec.output,
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
    use crate::scope::Scope;
    use crate::service::{Context, Services, testing};

    /// A directory of the test's own for its sockets.
    fn sockets(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("max-http-{name}-{}", std::process::id()));
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

    /// Asks at `socket` with `method` for `path`, `body` sent as JSON:
    /// the reply's head, and its body.
    async fn exchanged(socket: &Path, method: &str, path: &str, body: &str) -> (String, String) {
        let request = format!(
            "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:7777\r\nContent-Type: application/json\r\n\
             Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let mut stream = UnixStream::connect(socket).await.unwrap();
        stream.write_all(request.as_bytes()).await.unwrap();
        let mut reply = String::new();
        stream.read_to_string(&mut reply).await.unwrap();
        let (head, body) = reply.split_once("\r\n\r\n").unwrap();
        (head.to_owned(), body.to_owned())
    }

    /// The same: the reply's status line, and its body as JSON.
    async fn asked(socket: &Path, method: &str, path: &str, body: &str) -> (String, Value) {
        let (head, body) = exchanged(socket, method, path, body).await;
        let answer = serde_json::from_str(&body).unwrap_or(Value::Null);
        (head.lines().next().unwrap().to_owned(), answer)
    }

    /// A call of `tool` with `args`, as the guest's client makes it: its
    /// outcome.
    async fn called(socket: &Path, tool: &str, args: Value) -> Value {
        let path = format!("/tools/{tool}");
        let (status, outcome) = asked(socket, "POST", &path, &args.to_string()).await;
        assert_eq!(status, "HTTP/1.1 200 OK", "{outcome}");
        outcome
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
        let (status, listed) = asked(&socket, "GET", "/tools", "").await;
        assert_eq!(status, "HTTP/1.1 200 OK", "{listed}");
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
        let read = called(&socket, "history", one).await;
        assert_eq!(read["ok"], true, "{read}");
        assert_eq!(read["value"]["text"], format!("[12:01 小明 #{id}]: 你好"));
        let missing = called(&socket, "history", json!({ "around": id + 1 })).await;
        assert_eq!(missing["ok"], false, "{missing}");
        assert_eq!(missing["error"]["code"], "not_found");
        assert!(missing["error"]["message"].is_string(), "{missing}");
        // What isn't a tool: a typo, and one of the guest's own, which no
        // host is asked for.
        for name in ["histroy", "show", "agent_start"] {
            let outcome = called(&socket, name, json!({})).await;
            assert_eq!(outcome["error"]["code"], "unknown_tool", "{name}");
        }

        scope.close(Duration::from_secs(5)).await;
        let _ = std::fs::remove_dir_all(dir);
    }

    /// A call that comes as Max stops isn't begun, and is answered as the
    /// guest answers once max is gone, for its caller to make again; one
    /// Max stopped in the middle of may have acted, and is a failure.
    #[tokio::test]
    async fn a_call_max_doesnt_begin_is_away() {
        let dir = sockets("away");
        let socket = dir.join("mine.sock");
        let _ = std::fs::remove_file(&socket);
        let listener = UnixListener::bind(&socket).unwrap();
        let (calls, mut called) = tokio::sync::mpsc::unbounded_channel();
        let mut scope = Scope::new();
        let conversation = ConversationId(1);
        scope.spawn(move |stop| serve(listener, conversation, calls, axum::Router::new(), stop));
        let say = json!({ "text": "在吗" }).to_string();
        let asked = || exchanged(&socket, "POST", "/tools/say", &say);
        let away = |head: &str| {
            head.starts_with("HTTP/1.1 503 Service Unavailable\r\n") && head.contains("max-away: 1")
        };

        // The table, stopping, takes it and says so.
        let table = async {
            let Some(Signal::Call { reply, .. }) = called.recv().await else {
                panic!("no call came");
            };
            let _ = reply.send(Err(Failure::away()));
        };
        let ((head, body), ()) = tokio::join!(asked(), table);
        assert!(away(&head) && body.is_empty(), "{head}\n{body}");

        // An actor that ended under it.
        let actor = async {
            let Some(Signal::Call { reply, .. }) = called.recv().await else {
                panic!("no call came");
            };
            drop(reply);
        };
        let ((head, body), ()) = tokio::join!(asked(), actor);
        assert!(head.starts_with("HTTP/1.1 200 OK"), "{head}");
        let outcome: Value = serde_json::from_str(&body).unwrap();
        assert_eq!(outcome["error"]["code"], "closed", "{body}");

        // The table gone.
        drop(called);
        let (head, body) = asked().await;
        assert!(away(&head) && body.is_empty(), "{head}\n{body}");

        scope.close(Duration::from_secs(5)).await;
        let _ = std::fs::remove_dir_all(dir);
    }

    /// What isn't a call: arguments that are no JSON object, a tool asked
    /// for with GET, and the path the service had while it spoke MCP.
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

        for body in ["{", "[1]", "\"around\""] {
            let (status, outcome) = asked(&socket, "POST", "/tools/history", body).await;
            assert_eq!(status, "HTTP/1.1 400 Bad Request", "{body}");
            assert_eq!(outcome["ok"], false, "{body}");
            assert_eq!(outcome["error"]["code"], "bad_arguments", "{body}");
        }
        // No body is no arguments, which a tool may still refuse.
        let (status, outcome) = asked(&socket, "POST", "/tools/history", "").await;
        assert_eq!(status, "HTTP/1.1 200 OK", "{outcome}");
        assert!(outcome["ok"].is_boolean(), "{outcome}");
        let (status, _) = asked(&socket, "GET", "/tools/history", "").await;
        assert_eq!(status, "HTTP/1.1 405 Method Not Allowed");
        let (status, _) = asked(&socket, "POST", "/tools", "{}").await;
        assert_eq!(status, "HTTP/1.1 405 Method Not Allowed");
        let (status, _) = asked(&socket, "POST", "/mcp", "{}").await;
        assert_eq!(status, "HTTP/1.1 404 Not Found");

        scope.close(Duration::from_secs(5)).await;
        let _ = std::fs::remove_dir_all(dir);
    }
}
