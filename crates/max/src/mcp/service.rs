//! The MCP service: JSON-RPC posted over HTTP, stateless, answered with
//! JSON, on a unix socket per VM. Only what the runner's client and pi's
//! MCP adapter use: `initialize`, `ping`, `tools/list` and `tools/call`;
//! notifications are taken and dropped, and a call is cancelled by
//! closing its connection, which drops it. A program authenticates with
//! its run's token, which is good only while the run lasts and only from
//! its own conversation's VM. A background agent's session calls only
//! the tools that read, and its model calls go through the same service;
//! see [`super::forward`]. A call with no token is from a program Max
//! keeps in the VM, outside any turn: the VM says which group it is, and
//! the group's actor runs it; see "Resident programs" in docs/rust-rewrite.md.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::body::Bytes;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use max_core::ids::ConversationId;
use max_core::item::Part;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use tokio::sync::mpsc::UnboundedSender;
use tokio::sync::{Semaphore, oneshot};
use tokio::time::timeout;
use tokio_util::sync::CancellationToken;
use tracing::warn;

use super::tool::{self, Spec};
use super::{Call, Context, Failure, Route, chat_file, forward, harness, lock, show};
use crate::conversation::Signal;
use max_core::limits::{CALLS_AT_ONCE, Setting};

/// What a call that didn't finish may still have done. Nothing is retried
/// or classified by its effects: what acts on the group goes through the
/// timeline, where the model sees whether it happened.
const MAYBE_DONE: &str =
    "what acts in the chat may have taken effect: look at the records before trying again";
/// The protocol versions `initialize` agrees to, newest first: a client
/// gets its own if it is here, else the newest. The runner's client
/// speaks 2026-07-28, which needs no `initialize`; pi's 2025-11-25.
const VERSIONS: [&str; 4] = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26"];
/// JSON-RPC's codes for a request Max doesn't answer.
const PARSE_ERROR: i32 = -32700;
const INVALID_REQUEST: i32 = -32600;
const METHOD_NOT_FOUND: i32 = -32601;
const INVALID_PARAMS: i32 = -32602;

/// The open sessions, by token, and where calls without one go.
#[derive(Clone, Default)]
pub struct Sessions {
    table: Arc<Mutex<HashMap<String, Arc<Session>>>>,
    /// To the conversations' actors, for the programs Max keeps in the
    /// VMs; None where there are none, as in most tests.
    programs: Option<UnboundedSender<Signal>>,
}

pub(super) struct Session {
    pub(super) context: Context,
    /// Cancelled when the session closes; its calls in flight end with it.
    pub(super) closed: CancellationToken,
    slots: Semaphore,
    /// Per tool: calls that succeeded, and that failed.
    calls: Mutex<BTreeMap<String, (u32, u32)>>,
    /// The pictures and videos the program has shown the model, in order.
    shown: Mutex<Vec<Part>>,
}

/// An open session. Dropping it closes the session: the token stops
/// working and calls in flight end.
pub struct Grant {
    sessions: Sessions,
    token: String,
    session: Arc<Session>,
}

impl Sessions {
    /// Sessions whose VMs' programs call through `programs` without a
    /// token.
    pub fn with_programs(programs: UnboundedSender<Signal>) -> Self {
        Self {
            programs: Some(programs),
            ..Self::default()
        }
    }

    /// A session for `context`'s caller, in its conversation.
    pub fn open(&self, context: Context) -> Grant {
        let token = format!(
            "{:032x}{:032x}",
            rand::random::<u128>(),
            rand::random::<u128>()
        );
        let session = Arc::new(Session {
            context,
            closed: CancellationToken::new(),
            slots: Semaphore::new(CALLS_AT_ONCE),
            calls: Mutex::default(),
            shown: Mutex::default(),
        });
        lock(&self.table).insert(token.clone(), Arc::clone(&session));
        Grant {
            sessions: self.clone(),
            token,
            session,
        }
    }

    pub(super) fn get(&self, token: &str) -> Option<Arc<Session>> {
        lock(&self.table).get(token).cloned()
    }

    /// The session `authorization` names, if it is open and belongs to
    /// `conversation`'s VM.
    pub(super) fn bearer(
        &self,
        authorization: Option<&str>,
        conversation: ConversationId,
    ) -> Option<Arc<Session>> {
        authorization
            .and_then(|value| value.strip_prefix("Bearer "))
            .and_then(|token| self.get(token))
            .filter(|session| session.context.place.conversation == conversation)
    }
}

impl Grant {
    pub fn token(&self) -> &str {
        &self.token
    }

    /// Per tool called so far: how many calls succeeded, and failed.
    pub fn calls(&self) -> BTreeMap<String, (u32, u32)> {
        lock(&self.session.calls).clone()
    }

    /// The pictures and videos shown so far, in order.
    pub fn shown(&self) -> Vec<Part> {
        lock(&self.session.shown).clone()
    }
}

impl Drop for Grant {
    fn drop(&mut self) {
        lock(&self.sessions.table).remove(&self.token);
        self.session.closed.cancel();
    }
}

/// Serves the VM of `conversation` on `listener` until `stop`. A VM's
/// listener is a unix socket; tests' are TCP, which Node's fetch reaches.
pub async fn serve<L>(
    listener: L,
    conversation: ConversationId,
    sessions: Sessions,
    stop: CancellationToken,
) where
    L: axum::serve::Listener,
    L::Addr: std::fmt::Debug,
{
    serve_with(listener, conversation, sessions, axum::Router::new(), stop).await;
}

/// As `serve`, with the VM service's own routes, `host`.
pub async fn serve_with<L>(
    listener: L,
    conversation: ConversationId,
    sessions: Sessions,
    host: axum::Router,
    stop: CancellationToken,
) where
    L: axum::serve::Listener,
    L::Addr: std::fmt::Debug,
{
    let handler = Handler {
        conversation,
        sessions: sessions.clone(),
        programs: Arc::new(Semaphore::new(CALLS_AT_ONCE)),
    };
    // Only POST: with no sessions there is nothing to stream or end, so a
    // GET or a DELETE gets 405, which clients take for that.
    let app = axum::Router::new()
        .route("/mcp", post(rpc))
        .with_state(handler)
        .merge(forward::router(conversation, sessions.clone()))
        .merge(harness::router(conversation, sessions))
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
    sessions: Sessions,
    /// The calls the VM's programs make outside any turn, together, as a
    /// session's slots.
    programs: Arc<Semaphore>,
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

async fn rpc(State(handler): State<Handler>, headers: HeaderMap, body: Bytes) -> Response {
    let Ok(request) = serde_json::from_slice::<Request>(&body) else {
        let error = Refusal::new(PARSE_ERROR, "not a JSON-RPC request");
        let answer = Envelope {
            jsonrpc: "2.0",
            id: Value::Null,
            outcome: Outcome::Error(error),
        };
        return reply(StatusCode::BAD_REQUEST, &answer);
    };
    // Such as initialized, and cancelled: closing the connection is what
    // cancels a call here.
    let Some(id) = request.id else {
        return StatusCode::ACCEPTED.into_response();
    };
    let authorization = headers
        .get(header::AUTHORIZATION)
        .map(|value| value.to_str().unwrap_or_default());
    let outcome = match handler
        .answer(&request.method, request.params, authorization)
        .await
    {
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
    async fn answer(
        &self,
        method: &str,
        params: Value,
        authorization: Option<&str>,
    ) -> Result<Answer, Refusal> {
        match method {
            "initialize" => Ok(Answer::Value(initialized(&params))),
            "ping" => Ok(Answer::Value(json!({}))),
            "tools/list" => {
                let session = self.session(authorization)?;
                // With no session, a program's: every tool is its.
                let listed_to = |spec: &&'static Spec| match &session {
                    Some(session) => {
                        session.context.caller.route(Call::Tool(spec)) != Route::Refused
                    }
                    None => true,
                };
                let tools = tool::TOOLS.iter().filter(listed_to).map(listed).collect();
                Ok(Answer::Tools { tools })
            }
            "tools/call" => {
                let session = self.session(authorization)?;
                let Called { name, arguments } =
                    serde_json::from_value(params).map_err(|error| {
                        Refusal::new(
                            INVALID_PARAMS,
                            format!("tools/call's parameters are wrong: {error}"),
                        )
                    })?;
                let args = Value::Object(arguments.unwrap_or_default());
                Ok(Answer::Called(called(
                    self.call(session, &name, args).await,
                )))
            }
            _ => Err(Refusal::new(
                METHOD_NOT_FOUND,
                format!("there is no method {method}"),
            )),
        }
    }

    /// The session whose token the request carries, if it is open and
    /// belongs to this VM's conversation; None for a request with no
    /// token, a program's outside any turn.
    fn session(&self, authorization: Option<&str>) -> Result<Option<Arc<Session>>, Refusal> {
        let Some(authorization) = authorization else {
            return Ok(None);
        };
        self.sessions
            .bearer(Some(authorization), self.conversation)
            .map(Some)
            .ok_or_else(|| {
                Refusal::new(INVALID_REQUEST, "the token is wrong, or its run has ended")
            })
    }

    /// Runs `name` in its session, or as a program's call outside any turn
    /// with no session, or when only programs make it: so Max can try out
    /// from a turn's command the program it writes.
    async fn call(
        &self,
        session: Option<Arc<Session>>,
        name: &str,
        args: Value,
    ) -> Result<Value, Failure> {
        let Some(call) = Call::find(name) else {
            return Err(super::unknown(name));
        };
        let route = match &session {
            Some(session) => session.context.caller.route(call),
            None => Route::AsProgram,
        };
        match (session, route) {
            // A refusal is the session's to count.
            (Some(session), Route::Here | Route::Refused) => session.run(call, args).await,
            _ => self.program(name, args).await,
        }
    }

    /// Has the conversation's actor run a program's call: its result. The
    /// actor stops it when this stops waiting.
    async fn program(&self, tool: &str, args: Value) -> Result<Value, Failure> {
        let Some(programs) = &self.sessions.programs else {
            return Err(Failure::new(
                "unavailable",
                "programs kept in the VM can't call from here",
            ));
        };
        let call = async {
            let _slot = self.programs.acquire().await;
            let (reply, result) = oneshot::channel();
            let call = Signal::Call {
                conversation: self.conversation,
                tool: tool.to_owned(),
                args,
                reply,
            };
            programs
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

impl Session {
    /// Runs `call` if the caller may make it, and counts it if it is one
    /// of Max's tools: the model sees the pictures and videos shown
    /// themselves, and a file fetched is the program's.
    async fn run(&self, call: Call, args: Value) -> Result<Value, Failure> {
        let outcome = match self.context.caller.route(call) {
            Route::Refused => Err(self.context.caller.refusal(call)),
            Route::Here | Route::AsProgram => tokio::select! {
                outcome = async {
                    let _slot = self.slots.acquire().await;
                    timeout(self.context.call_time, self.dispatch(call, args)).await
                } => outcome.unwrap_or_else(|_| Err(late(self.context.call_time))),
                () = self.closed.cancelled() => Err(Failure::new("closed", "this run has ended")),
            },
        };
        if let Call::Tool(spec) = call {
            let mut calls = lock(&self.calls);
            let (succeeded, failed) = calls.entry(spec.name.to_owned()).or_default();
            *if outcome.is_ok() { succeeded } else { failed } += 1;
        }
        outcome
    }

    async fn dispatch(&self, call: Call, args: Value) -> Result<Value, Failure> {
        match call {
            Call::Tool(spec) => spec.call(&self.context, args).await,
            Call::Image => show::image(&self.context, &self.shown, args).await,
            Call::Video => show::video(&self.context, &self.shown, args).await,
            Call::File => chat_file::run(&self.context, args).await,
        }
    }
}

/// A call that didn't end within `limit`.
pub(super) fn late(limit: Duration) -> Failure {
    Failure::new(
        "timeout",
        format!("not done in {} seconds; {MAYBE_DONE}", limit.as_secs()),
    )
}

/// The answer to `initialize`, from a client of an older protocol than
/// the runner's: tools, at the client's version if Max knows it.
fn initialized(params: &Value) -> Value {
    let asked = params["protocolVersion"].as_str();
    let version = VERSIONS
        .into_iter()
        .find(|version| Some(*version) == asked)
        .unwrap_or(VERSIONS[0]);
    json!({
        "protocolVersion": version,
        "capabilities": { "tools": {} },
        "serverInfo": { "name": "max", "version": env!("CARGO_PKG_VERSION") },
    })
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
    use crate::mcp::Services;
    use crate::scope::Scope;

    /// A directory of the test's own for its sockets.
    fn sockets(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("max-mcp-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// Serves `conversation`'s VM on the unix socket `socket`, in `scope`.
    fn serve_at(
        scope: &mut Scope,
        socket: &Path,
        conversation: ConversationId,
        sessions: &Sessions,
    ) {
        let _ = std::fs::remove_file(socket);
        let listener = UnixListener::bind(socket).unwrap();
        let sessions = sessions.clone();
        scope.spawn(move |stop| serve(listener, conversation, sessions, stop));
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
    async fn post(socket: &Path, token: &str, method: &str, params: Value) -> Value {
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
        let headers = format!(
            "MCP-Protocol-Version: 2026-07-28\r\nMcp-Method: {method}\r\n{name}\
             Authorization: Bearer {token}\r\n"
        );
        let (_, reply) = exchange(socket, "POST", &headers, &body.to_string()).await;
        let reply: Value = serde_json::from_str(&reply).unwrap();
        reply
            .get("result")
            .or_else(|| reply.get("error"))
            .cloned()
            .unwrap()
    }

    #[sqlx::test(migrator = "max_db::MIGRATOR")]
    async fn a_program_calls_with_its_runs_token(pool: PgPool) {
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
        let conversation = place.conversation;
        let sessions = Sessions::default();
        let grant = sessions.open(Context::check(Services::bare(pool), place));

        let dir = sockets("token");
        let (socket, other) = (dir.join("mine.sock"), dir.join("other.sock"));
        let mut scope = Scope::new();
        serve_at(&mut scope, &socket, conversation, &sessions);
        let elsewhere = ConversationId(conversation.0 + 1);
        serve_at(&mut scope, &other, elsewhere, &sessions);

        let listed = post(&socket, grant.token(), "tools/list", json!({})).await;
        assert_eq!(listed["tools"][0]["name"], "history", "{listed}");
        assert_eq!(listed["tools"][0]["outputSchema"]["type"], "object");

        let id = hello.message.id.0;
        let one = json!({ "around": id, "before": 0, "after": 0 });
        let read = json!({ "name": "history", "arguments": one });
        let result = post(&socket, grant.token(), "tools/call", read.clone()).await;
        assert_eq!(result["isError"], false, "{result}");
        assert_eq!(
            result["structuredContent"]["text"],
            format!("[12:01 小明 #{id}]: 你好")
        );
        let missing = json!({ "name": "history", "arguments": { "around": id + 1 } });
        let result = post(&socket, grant.token(), "tools/call", missing).await;
        assert_eq!(result["isError"], true, "{result}");
        assert_eq!(result["structuredContent"]["code"], "not_found");
        assert_eq!(grant.calls()["history"], (1, 1));
        let typo = json!({ "name": "histroy", "arguments": {} });
        let result = post(&socket, grant.token(), "tools/call", typo).await;
        assert_eq!(result["structuredContent"]["code"], "unknown_tool");

        // Another conversation's VM, a wrong token, a run that ended.
        let refused = |reply: &Value| reply["message"].as_str().unwrap().contains("token");
        assert!(refused(
            &post(&other, grant.token(), "tools/call", read.clone()).await
        ));
        assert!(refused(
            &post(&socket, "nope", "tools/call", read.clone()).await
        ));
        let token = grant.token().to_owned();
        drop(grant);
        assert!(refused(
            &post(&socket, &token, "tools/list", json!({})).await
        ));

        scope.close(Duration::from_secs(5)).await;
        let _ = std::fs::remove_dir_all(dir);
    }

    /// A client of the 2025-11-25 protocol, as pi's MCP adapter is: it
    /// begins with `initialize`, says it is initialized, asks with a GET
    /// for a stream of the server's own messages and does without, and
    /// reads a result's text.
    #[sqlx::test(migrator = "max_db::MIGRATOR")]
    async fn a_client_of_the_older_protocol_is_served(pool: PgPool) {
        let mut conn = pool.acquire().await.unwrap();
        let place = Arc::new(group(&mut conn).await);
        drop(conn);
        let conversation = place.conversation;
        let sessions = Sessions::default();
        let grant = sessions.open(Context::check(Services::bare(pool), place));
        let dir = sockets("legacy");
        let socket = dir.join("mine.sock");
        let mut scope = Scope::new();
        serve_at(&mut scope, &socket, conversation, &sessions);
        let first = format!("Authorization: Bearer {}\r\n", grant.token());
        let then = format!("MCP-Protocol-Version: 2025-11-25\r\n{first}");
        let rpc = async |headers: &str, body: Value| {
            let (status, body) = exchange(&socket, "POST", headers, &body.to_string()).await;
            assert_eq!(status, "HTTP/1.1 200 OK", "{body}");
            serde_json::from_str::<Value>(&body).unwrap()
        };

        let hello = json!({
            "protocolVersion": "2025-11-25",
            "capabilities": {},
            "clientInfo": { "name": "pi", "version": "1.4.0" },
        });
        let initialize =
            json!({ "jsonrpc": "2.0", "id": 0, "method": "initialize", "params": hello });
        let initialized = rpc(&first, initialize).await;
        assert_eq!(
            initialized["result"]["protocolVersion"], "2025-11-25",
            "{initialized}"
        );
        assert_eq!(
            initialized["result"]["capabilities"],
            json!({ "tools": {} })
        );
        let note = json!({ "jsonrpc": "2.0", "method": "notifications/initialized" });
        let (status, body) = exchange(&socket, "POST", &then, &note.to_string()).await;
        assert_eq!(
            (status.as_str(), body.as_str()),
            ("HTTP/1.1 202 Accepted", "")
        );
        let (status, _) = exchange(&socket, "GET", &then, "").await;
        assert_eq!(status, "HTTP/1.1 405 Method Not Allowed");

        let list = json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" });
        let listed = rpc(&then, list).await;
        assert_eq!(listed["result"]["tools"][0]["name"], "history", "{listed}");
        let call = json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": { "name": "history", "arguments": { "around": 1 } },
        });
        let result = rpc(&then, call).await["result"].clone();
        assert_eq!(result["isError"], true, "{result}");
        let text = result["content"][0]["text"].as_str().unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(text).unwrap(),
            result["structuredContent"]
        );

        let ping = json!({ "jsonrpc": "2.0", "id": 3, "method": "ping" });
        assert_eq!(rpc(&then, ping).await["result"], json!({}));
        let unknown = json!({ "jsonrpc": "2.0", "id": 4, "method": "resources/list" });
        assert_eq!(rpc(&then, unknown).await["error"]["code"], METHOD_NOT_FOUND);
        let (status, body) = exchange(&socket, "POST", &then, "{").await;
        assert_eq!(status, "HTTP/1.1 400 Bad Request", "{body}");

        scope.close(Duration::from_secs(5)).await;
        let _ = std::fs::remove_dir_all(dir);
    }
}
