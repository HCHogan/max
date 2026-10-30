//! The MCP service: Streamable HTTP, stateless, on a unix socket per VM.
//! A program authenticates with its run's token, which is good only while
//! the run lasts and only from its own conversation's VM. A background
//! agent's session calls only the tools that read, and its model calls go
//! through the same service; see [`super::forward`].

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use axum::http::request::Parts;
use max_core::ids::ConversationId;
use rmcp::model::{
    CallToolRequestParams, CallToolResponse, CallToolResult, ListToolsResult,
    PaginatedRequestParams, ServerCapabilities, ServerConfig, Tool,
};
use rmcp::service::RequestContext;
use rmcp::transport::streamable_http_server::session::never::NeverSessionManager;
use rmcp::transport::streamable_http_server::{StreamableHttpServerConfig, StreamableHttpService};
use rmcp::{ErrorData, RoleServer, ServerHandler};
use serde_json::{Value, json};
use tokio::sync::Semaphore;
use tokio::time::timeout;
use tokio_util::sync::CancellationToken;
use tracing::warn;

use super::tool::{self, Spec};
use super::{Caller, Context, Failure, chat_file, forward, show};

/// One call's wall clock.
const CALL_TIME: Duration = Duration::from_secs(60);
/// Calls a session runs at once; more wait their turn.
const CALLS_AT_ONCE: usize = 64;
/// A background agent's session lasts the job, as long as many programs:
/// its caps are a program's, this many times over.
const JOB_RUNS: u32 = 10;
/// What a call that didn't finish may still have done. Nothing is retried
/// or classified by its effects: what acts on the group goes through the
/// timeline, where the model sees whether it happened.
const MAYBE_DONE: &str = "会动群的操作可能已经生效，先看记录再决定要不要再来";

/// The open sessions, by token.
#[derive(Clone, Default)]
pub struct Sessions(Arc<Mutex<HashMap<String, Arc<Session>>>>);

pub(super) struct Session {
    pub(super) context: Context,
    /// Cancelled when the session closes; its calls in flight end with it.
    pub(super) closed: CancellationToken,
    slots: Semaphore,
    /// Per tool: calls that succeeded, and that failed.
    calls: Mutex<BTreeMap<String, (u32, u32)>>,
    /// Per tool with a cap: calls started.
    started: Mutex<HashMap<&'static str, u32>>,
    /// The pictures the program has shown the model, in order.
    shown: Mutex<Vec<String>>,
}

/// An open session. Dropping it closes the session: the token stops
/// working and calls in flight end.
pub struct Grant {
    sessions: Sessions,
    token: String,
    session: Arc<Session>,
}

impl Sessions {
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
            started: Mutex::default(),
            shown: Mutex::default(),
        });
        self.table().insert(token.clone(), Arc::clone(&session));
        Grant {
            sessions: self.clone(),
            token,
            session,
        }
    }

    pub(super) fn get(&self, token: &str) -> Option<Arc<Session>> {
        self.table().get(token).cloned()
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

    fn table(&self) -> std::sync::MutexGuard<'_, HashMap<String, Arc<Session>>> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl Grant {
    pub fn token(&self) -> &str {
        &self.token
    }

    /// Per tool called so far: how many calls succeeded, and failed.
    pub fn calls(&self) -> BTreeMap<String, (u32, u32)> {
        self.session
            .calls
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// The pictures shown so far, by SHA-256, in order.
    pub fn shown(&self) -> Vec<String> {
        self.session
            .shown
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }
}

impl Drop for Grant {
    fn drop(&mut self) {
        self.sessions.table().remove(&self.token);
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
    // Clients of the protocol before 2026-07-28, such as pi's, begin with
    // `initialize`; with no sessions, each of their requests stands alone.
    let config = StreamableHttpServerConfig::default()
        .with_cancellation_token(stop.child_token())
        .with_legacy_session_mode(false)
        .with_json_response(true);
    let handler = Handler {
        conversation,
        sessions: sessions.clone(),
    };
    let service = StreamableHttpService::new(
        move || Ok(handler.clone()),
        Arc::new(NeverSessionManager::default()),
        config,
    );
    let app = axum::Router::new()
        .nest_service("/mcp", service)
        .merge(forward::router(conversation, sessions));
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
}

impl Handler {
    /// The session whose token the request carries, if it is open and
    /// belongs to this VM's conversation.
    fn session(&self, request: &RequestContext<RoleServer>) -> Result<Arc<Session>, ErrorData> {
        let authorization = request
            .extensions
            .get::<Parts>()
            .and_then(|parts| parts.headers.get("authorization"))
            .and_then(|value| value.to_str().ok());
        self.sessions
            .bearer(authorization, self.conversation)
            .ok_or_else(|| ErrorData::invalid_request("token 不对，或者这次运行已经结束了", None))
    }
}

impl ServerHandler for Handler {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
    }

    async fn list_tools(
        &self,
        _: Option<PaginatedRequestParams>,
        request: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        let session = self.session(&request)?;
        Ok(ListToolsResult {
            tools: tool::TOOLS
                .iter()
                .filter(|spec| session.context.caller.allows(spec.name))
                .map(listed)
                .collect(),
            ..ListToolsResult::default()
        })
    }

    async fn call_tool(
        &self,
        call: CallToolRequestParams,
        request: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, ErrorData> {
        let session = self.session(&request)?;
        let args = Value::Object(call.arguments.unwrap_or_default());
        let started = if session.context.caller.allows(&call.name) {
            session.start(&call.name)
        } else {
            Err(Failure::new(
                "not_allowed",
                format!("后台 agent 用不了 {}", call.name),
            ))
        };
        let outcome = match started {
            Err(failure) => Err(failure),
            Ok(()) => tokio::select! {
            outcome = async {
                let _slot = session.slots.acquire().await;
                timeout(CALL_TIME, session.call(&call.name, args)).await
            } => outcome.unwrap_or_else(|_| Err(Failure::new(
                "timeout",
                format!("{} 秒内没做完；{MAYBE_DONE}", CALL_TIME.as_secs()),
            ))),
            () = session.closed.cancelled() => Err(Failure::new("closed", "这次运行已经结束了")),
            () = request.ct.cancelled() => Err(Failure::new("cancelled", format!("调用取消了；{MAYBE_DONE}"))),
            },
        };
        // Not Max's tools: the model sees the pictures shown themselves,
        // and a file fetched is the program's.
        if call.name != show::NAME && call.name != chat_file::NAME {
            let mut calls = session.calls.lock().unwrap_or_else(PoisonError::into_inner);
            let (succeeded, failed) = calls.entry(call.name.to_string()).or_default();
            *if outcome.is_ok() { succeeded } else { failed } += 1;
        }
        let result = match outcome {
            Ok(value) => CallToolResult::structured(value),
            Err(Failure { code, message }) => {
                CallToolResult::structured_error(json!({ "code": code, "message": message }))
            }
        };
        Ok(result.into())
    }
}

impl Session {
    async fn call(&self, name: &str, args: Value) -> Result<Value, Failure> {
        if name == show::NAME {
            return show::run(&self.context, &self.shown, args).await;
        }
        if name == chat_file::NAME {
            return chat_file::run(&self.context, args).await;
        }
        super::call(name, &self.context, args).await
    }

    /// Counts a call against its tool's cap, if it has one and the run, or
    /// the job, hasn't reached it.
    fn start(&self, name: &str) -> Result<(), Failure> {
        let Some((name, most)) =
            tool::find(name).and_then(|tool| tool.per_run.map(|most| (tool.name, most)))
        else {
            return Ok(());
        };
        let (most, whose) = match self.context.caller {
            Caller::Job(_) => (most * JOB_RUNS, "一个后台 agent"),
            Caller::Turn(_) | Caller::Check => (most, "一次运行"),
        };
        let mut started = self.started.lock().unwrap_or_else(PoisonError::into_inner);
        let count = started.entry(name).or_default();
        if *count >= most {
            return Err(Failure::new(
                "too_many",
                format!("{whose}最多调 {most} 次 {name}"),
            ));
        }
        *count += 1;
        Ok(())
    }
}

fn listed(spec: &Spec) -> Tool {
    Tool::new(spec.name, spec.description, Arc::clone(&spec.input))
        .with_raw_output_schema(Arc::clone(&spec.output))
}

#[cfg(test)]
mod tests {
    use chrono::Utc;
    use sqlx::PgPool;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{UnixListener, UnixStream};

    use super::*;
    use crate::conversation::ingest;
    use crate::conversation::testing::{from_xiaoming, group, offset, text};
    use crate::mcp::{Caller, Services};
    use crate::scope::Scope;

    /// A JSON-RPC request as the runner sends it: the reply's `result` or
    /// `error`.
    async fn post(socket: &std::path::Path, token: &str, method: &str, params: Value) -> Value {
        let name = params["name"].as_str().map(str::to_owned);
        let mut params = params;
        params["_meta"] = json!({
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities": {},
        });
        let body =
            json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params }).to_string();
        let name = name
            .map(|name| format!("Mcp-Name: {name}\r\n"))
            .unwrap_or_default();
        let request = format!(
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:7777\r\nContent-Type: application/json\r\n\
             Accept: application/json, text/event-stream\r\nMCP-Protocol-Version: 2026-07-28\r\n\
             Mcp-Method: {method}\r\n{name}Authorization: Bearer {token}\r\n\
             Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let mut stream = UnixStream::connect(socket).await.unwrap();
        stream.write_all(request.as_bytes()).await.unwrap();
        let mut reply = String::new();
        stream.read_to_string(&mut reply).await.unwrap();
        let (_, body) = reply.split_once("\r\n\r\n").unwrap();
        let reply: Value = serde_json::from_str(body).unwrap();
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
            &from_xiaoming(1, vec![text("你好")]),
            Utc::now(),
            offset(),
        )
        .await
        .unwrap();
        drop(conn);
        let conversation = place.conversation;
        let sessions = Sessions::default();
        let grant = sessions.open(Context {
            services: Arc::new(Services::bare(pool)),
            place,
            page_tokens: 2000,
            work: None,
            caller: Caller::Check,
        });

        let dir = std::env::temp_dir().join(format!("max-mcp-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mine.sock");
        let other = dir.join("other.sock");
        let mut scope = Scope::new();
        for (path, conversation) in [
            (&socket, conversation),
            (&other, ConversationId(conversation.0 + 1)),
        ] {
            let _ = std::fs::remove_file(path);
            let listener = UnixListener::bind(path).unwrap();
            let sessions = sessions.clone();
            scope.spawn(move |stop| serve(listener, conversation, sessions, stop));
        }

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

    /// A request as a client of the 2025-11-25 protocol sends it: no
    /// `_meta`, and no `Mcp-Method` header.
    async fn post_legacy(
        socket: &std::path::Path,
        token: &str,
        method: &str,
        params: Value,
    ) -> Value {
        let body =
            json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params }).to_string();
        let version = if method == "initialize" {
            String::new()
        } else {
            "MCP-Protocol-Version: 2025-11-25\r\n".to_owned()
        };
        let request = format!(
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:7777\r\nContent-Type: application/json\r\n\
             Accept: application/json, text/event-stream\r\n{version}\
             Authorization: Bearer {token}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        let mut stream = UnixStream::connect(socket).await.unwrap();
        stream.write_all(request.as_bytes()).await.unwrap();
        let mut reply = String::new();
        stream.read_to_string(&mut reply).await.unwrap();
        let (head, body) = reply.split_once("\r\n\r\n").unwrap();
        assert!(head.starts_with("HTTP/1.1 200"), "{reply}");
        let reply: Value = serde_json::from_str(body).unwrap();
        reply["result"].clone()
    }

    #[sqlx::test(migrator = "max_db::MIGRATOR")]
    async fn a_client_of_the_older_protocol_is_served(pool: PgPool) {
        let mut conn = pool.acquire().await.unwrap();
        let place = Arc::new(group(&mut conn).await);
        drop(conn);
        let conversation = place.conversation;
        let sessions = Sessions::default();
        let grant = sessions.open(Context {
            services: Arc::new(Services::bare(pool)),
            place,
            page_tokens: 2000,
            work: None,
            caller: Caller::Check,
        });
        let dir = std::env::temp_dir().join(format!("max-mcp-legacy-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mine.sock");
        let _ = std::fs::remove_file(&socket);
        let listener = UnixListener::bind(&socket).unwrap();
        let mut scope = Scope::new();
        let served = sessions.clone();
        scope.spawn(move |stop| serve(listener, conversation, served, stop));

        let hello = json!({
            "protocolVersion": "2025-11-25",
            "capabilities": {},
            "clientInfo": { "name": "pi", "version": "1.4.0" },
        });
        let initialized = post_legacy(&socket, grant.token(), "initialize", hello).await;
        assert_eq!(
            initialized["protocolVersion"], "2025-11-25",
            "{initialized}"
        );
        let listed = post_legacy(&socket, grant.token(), "tools/list", json!({})).await;
        assert_eq!(listed["tools"][0]["name"], "history", "{listed}");

        scope.close(Duration::from_secs(5)).await;
        let _ = std::fs::remove_dir_all(dir);
    }

    #[sqlx::test(migrator = "max_db::MIGRATOR")]
    async fn a_capped_tool_stops_at_its_cap(pool: PgPool) {
        let mut conn = pool.acquire().await.unwrap();
        let place = Arc::new(group(&mut conn).await);
        drop(conn);
        let conversation = place.conversation;
        let sessions = Sessions::default();
        let context = |caller| Context {
            services: Arc::new(Services::bare(pool.clone())),
            place: Arc::clone(&place),
            page_tokens: 2000,
            work: None,
            caller,
        };
        let grant = sessions.open(context(Caller::Check));
        let upstream = crate::llm::Upstream {
            provider: "cliproxy".into(),
            protocol: max_core::item::Protocol::Chat,
            base_url: "http://127.0.0.1:9/v1".into(),
            api_key: None,
            headers: Vec::new(),
            model: "gemini-3.8-flash-high".into(),
            window: 1_000_000,
            max_output: None,
            effort: None,
            idle: Duration::from_secs(120),
        };
        let job = sessions.open(context(Caller::Job(Arc::new(upstream))));
        let dir = std::env::temp_dir().join(format!("max-mcp-cap-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mine.sock");
        let _ = std::fs::remove_file(&socket);
        let listener = UnixListener::bind(&socket).unwrap();
        let mut scope = Scope::new();
        let served = sessions.clone();
        scope.spawn(move |stop| serve(listener, conversation, served, stop));

        let search = json!({ "name": "web_search", "arguments": { "query": "示波器" } });
        let code = async |grant: &Grant| {
            let result = post(&socket, grant.token(), "tools/call", search.clone()).await;
            result["structuredContent"]["code"]
                .as_str()
                .unwrap()
                .to_owned()
        };
        for _ in 0..20 {
            assert_eq!(code(&grant).await, "unavailable", "no search here");
        }
        assert_eq!(code(&grant).await, "too_many");
        assert_eq!(grant.calls()["web_search"], (0, 21));
        // A job's session lasts the job: its cap is many programs'.
        for _ in 0..20 * JOB_RUNS {
            assert_eq!(code(&job).await, "unavailable");
        }
        assert_eq!(code(&job).await, "too_many");

        scope.close(Duration::from_secs(5)).await;
        let _ = std::fs::remove_dir_all(dir);
    }
}
