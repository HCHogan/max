//! The MCP service: Streamable HTTP, stateless, on a unix socket per VM.
//! A program authenticates with its run's token, which is good only while
//! the run lasts and only from its own conversation's VM.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use axum::http::request::Parts;
use max_core::ids::ConversationId;
use max_core::tools::{MAX_TOOLS, MaxTool};
use rmcp::model::{
    CallToolRequestParams, CallToolResponse, CallToolResult, JsonObject, ListToolsResult,
    PaginatedRequestParams, ServerCapabilities, ServerConfig, Tool,
};
use rmcp::service::RequestContext;
use rmcp::transport::streamable_http_server::session::never::NeverSessionManager;
use rmcp::transport::streamable_http_server::{StreamableHttpServerConfig, StreamableHttpService};
use rmcp::{ErrorData, RoleServer, ServerHandler};
use serde_json::{Value, json};
use tokio::net::UnixListener;
use tokio::sync::Semaphore;
use tokio::time::timeout;
use tokio_util::sync::CancellationToken;
use tracing::warn;

use super::{Context, Failure};

/// One call's wall clock.
const CALL_TIME: Duration = Duration::from_secs(60);
/// Calls a session runs at once; more wait their turn.
const CALLS_AT_ONCE: usize = 64;

/// The open sessions, by token.
#[derive(Clone, Default)]
pub struct Sessions(Arc<Mutex<HashMap<String, Arc<Session>>>>);

struct Session {
    context: Context,
    /// Cancelled when the session closes; its calls in flight end with it.
    closed: CancellationToken,
    slots: Semaphore,
    /// Per tool: calls that succeeded, and that failed.
    calls: Mutex<BTreeMap<String, (u32, u32)>>,
}

/// An open session. Dropping it closes the session: the token stops
/// working and calls in flight end.
pub struct Grant {
    sessions: Sessions,
    token: String,
    session: Arc<Session>,
}

impl Sessions {
    /// A session for programs in `context`'s conversation.
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
        });
        self.table().insert(token.clone(), Arc::clone(&session));
        Grant {
            sessions: self.clone(),
            token,
            session,
        }
    }

    fn get(&self, token: &str) -> Option<Arc<Session>> {
        self.table().get(token).cloned()
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
}

impl Drop for Grant {
    fn drop(&mut self) {
        self.sessions.table().remove(&self.token);
        self.session.closed.cancel();
    }
}

/// Serves the VM of `conversation` on `listener` until `stop`.
pub async fn serve(
    listener: UnixListener,
    conversation: ConversationId,
    sessions: Sessions,
    stop: CancellationToken,
) {
    let config = StreamableHttpServerConfig::default()
        .with_cancellation_token(stop.child_token())
        .with_json_response(true);
    let handler = Handler {
        conversation,
        sessions,
    };
    let service = StreamableHttpService::new(
        move || Ok(handler.clone()),
        Arc::new(NeverSessionManager::default()),
        config,
    );
    let app = axum::Router::new().nest_service("/mcp", service);
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
        let token = request
            .extensions
            .get::<Parts>()
            .and_then(|parts| parts.headers.get("authorization"))
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.strip_prefix("Bearer "));
        token
            .and_then(|token| self.sessions.get(token))
            .filter(|session| session.context.place.conversation == self.conversation)
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
        self.session(&request)?;
        Ok(ListToolsResult {
            tools: MAX_TOOLS.iter().map(tool).collect(),
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
        let outcome = tokio::select! {
            outcome = async {
                let _slot = session.slots.acquire().await;
                timeout(CALL_TIME, super::call(&call.name, &session.context, args)).await
            } => outcome.unwrap_or_else(|_| Err(Failure::new(
                "timeout",
                format!("{} 秒内没做完", CALL_TIME.as_secs()),
            ))),
            () = session.closed.cancelled() => Err(Failure::new("closed", "这次运行已经结束了")),
            () = request.ct.cancelled() => Err(Failure::new("cancelled", "调用取消了")),
        };
        let mut calls = session.calls.lock().unwrap_or_else(PoisonError::into_inner);
        let (succeeded, failed) = calls.entry(call.name.to_string()).or_default();
        let result = match outcome {
            Ok(value) => {
                *succeeded += 1;
                CallToolResult::structured(value)
            }
            Err(Failure { code, message }) => {
                *failed += 1;
                CallToolResult::structured_error(json!({ "code": code, "message": message }))
            }
        };
        Ok(result.into())
    }
}

fn tool(spec: &MaxTool) -> Tool {
    let schema = |text: &str| -> Arc<JsonObject> {
        Arc::new(serde_json::from_str(text).expect("max-core's tests check the schemas"))
    };
    Tool::new(spec.name, spec.description, schema(spec.input))
        .with_raw_output_schema(schema(spec.output))
}

#[cfg(test)]
mod tests {
    use chrono::Utc;
    use sqlx::PgPool;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::UnixStream;

    use super::*;
    use crate::conversation::ingest;
    use crate::conversation::testing::{from_xiaoming, group, offset, text};
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
            pool,
            place,
            offset: offset(),
            page_tokens: 2000,
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
        assert_eq!(listed["tools"][0]["name"], "context_read", "{listed}");
        assert_eq!(listed["tools"][0]["outputSchema"]["type"], "object");

        let id = hello.message.id.0;
        let read = json!({ "name": "context_read", "arguments": { "id": id } });
        let result = post(&socket, grant.token(), "tools/call", read.clone()).await;
        assert_eq!(result["isError"], false, "{result}");
        assert_eq!(
            result["structuredContent"]["text"],
            format!("[12:01 小明 #{id}]: 你好")
        );
        let missing = json!({ "name": "context_read", "arguments": { "id": id + 1 } });
        let result = post(&socket, grant.token(), "tools/call", missing).await;
        assert_eq!(result["isError"], true, "{result}");
        assert_eq!(result["structuredContent"]["code"], "not_found");
        assert_eq!(grant.calls()["context_read"], (1, 1));

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
}
