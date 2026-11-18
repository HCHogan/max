//! Max's tools over HTTP, on the unix socket the VMs' guests reach max
//! at: `GET /tools` lists them, with their schemas, and `POST
//! /tools/<name>`, with the arguments as a JSON object, calls one. The
//! answer is the call's outcome, `{"ok": true, "value": …}` or `{"ok":
//! false, "error": {"code", "message"}}`; a call is cancelled by closing
//! its connection, which drops it. A call is the VM's: whose VM made its
//! connection says which conversation it is ([`Calling`]), whose actor
//! runs it, and nothing says which program in the VM made it. A turn's
//! program, a background command, an agent and a unit of Max's own call
//! alike, and have every tool. See "The guest's calls" in
//! docs/design/tools.md.

use std::collections::HashMap;
use std::fmt;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use axum::body::Bytes;
use axum::extract::connect_info::Connected;
use axum::extract::{ConnectInfo, FromRequestParts, Path, State};
use axum::http::request::Parts;
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::serve::{IncomingStream, Listener};
use futures_util::future::BoxFuture;
use max_core::ids::ConversationId;
use rustix::event::{PollFd, PollFlags, Timespec, poll};
use serde::Serialize;
use serde_json::{Map, Value, json};
use tokio::net::{UnixListener, UnixStream};
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

/// max's service to the VMs: the tools, whose calls go to their
/// conversations' actors through `calls`, and the VM service's own
/// routes, `host`.
pub fn router(calls: UnboundedSender<Signal>, host: axum::Router) -> axum::Router {
    let handler = Handler {
        calls,
        slots: Arc::default(),
    };
    axum::Router::new()
        .route("/tools", get(list))
        .route("/tools/{name}", post(call))
        .with_state(handler)
        .merge(host)
}

/// Whose VM the process with this pid is of, if it is one's: the VM
/// service's to say (`vm::machine::whose`).
pub type Whose = Arc<dyn Fn(i32) -> BoxFuture<'static, Option<ConversationId>> + Send + Sync>;

/// Whose VM a connection at max's socket is from: the conversation of the
/// VM whose process made it. A guest's connection to the host is made
/// for it by its VM's cloud-hypervisor, which nothing in the guest
/// chooses, so no VM speaks for another's. None for a connection that no
/// VM's process made.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Caller(pub Option<ConversationId>);

/// The socket the VMs' guests reach max at, every VM's port for the host
/// being a link to it (`vm::machine`). It says whose VM each connection
/// is from, by the process at its other end, and takes none whose other
/// end is gone. The socket waits through a restart of max (`maxx.socket`,
/// nix/module.nix), so a call made meanwhile is there when max is back,
/// with its request to read, even if its caller has left since: its turn
/// was cut off, or its unit stopped. Its connection closed when its
/// caller went, and the kernel says so of it before anything is read: it
/// is dropped, and the call never begun. One that hangs up later is
/// dropped as any call is whose caller closes.
pub struct Waited {
    listener: UnixListener,
    whose: Whose,
}

impl fmt::Debug for Waited {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Waited")
            .field("listener", &self.listener)
            .finish_non_exhaustive()
    }
}

impl Waited {
    pub fn new(listener: UnixListener, whose: Whose) -> Self {
        Self { listener, whose }
    }
}

impl Listener for Waited {
    type Io = UnixStream;
    type Addr = Caller;

    async fn accept(&mut self) -> (UnixStream, Caller) {
        loop {
            let (stream, _) = Listener::accept(&mut self.listener).await;
            if hung_up(&stream) {
                continue;
            }
            let pid = stream.peer_cred().ok().and_then(|peer| peer.pid());
            let caller = match pid {
                Some(pid) => (self.whose)(pid).await,
                None => None,
            };
            if caller.is_none() {
                warn!(
                    pid,
                    "a connection at max's socket that no VM's process made"
                );
            }
            return (stream, Caller(caller));
        }
    }

    /// This end is max's, and no VM's.
    fn local_addr(&self) -> std::io::Result<Caller> {
        Ok(Caller(None))
    }
}

impl Connected<IncomingStream<'_, Waited>> for Caller {
    fn connect_info(stream: IncomingStream<'_, Waited>) -> Self {
        *stream.remote_addr()
    }
}

/// Whether the other end of `stream` is gone, as it stands now.
fn hung_up(stream: &UnixStream) -> bool {
    // Asked for what there is to read, since not every system says of a
    // connection it is asked nothing about that it has hung up.
    let mut asked = [PollFd::new(stream, PollFlags::IN)];
    let at_once = Timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    poll(&mut asked, Some(&at_once)).is_ok() && asked[0].revents().contains(PollFlags::HUP)
}

/// Serves `app` to the VMs on `listener` until `stop`, each request with
/// whose VM its connection is from.
pub async fn serve(listener: Waited, app: axum::Router, stop: CancellationToken) {
    let app = app.into_make_service_with_connect_info::<Caller>();
    if let Err(error) = axum::serve(listener, app)
        .with_graceful_shutdown(stop.cancelled_owned())
        .await
    {
        warn!(%error, "the service to the VMs stopped");
    }
}

/// The conversation whose VM a request comes from, by its connection
/// ([`Caller`]). One from no VM is nobody's call.
#[derive(Debug)]
pub struct Calling(pub ConversationId);

impl<S: Sync> FromRequestParts<S> for Calling {
    type Rejection = Response;

    async fn from_request_parts(parts: &mut Parts, _: &S) -> Result<Self, Response> {
        match parts.extensions.get::<ConnectInfo<Caller>>() {
            Some(ConnectInfo(Caller(Some(conversation)))) => Ok(Self(*conversation)),
            _ => {
                let nobody = Failure::new("bad_request", "the request comes from no VM");
                Err(answer(StatusCode::BAD_REQUEST, &outcome(Err(nobody))))
            }
        }
    }
}

#[derive(Clone)]
struct Handler {
    /// To the conversations' actors, through the table.
    calls: UnboundedSender<Signal>,
    /// How many calls a VM makes at once; more wait their turn.
    slots: Arc<Mutex<HashMap<ConversationId, Arc<Semaphore>>>>,
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
async fn call(
    State(handler): State<Handler>,
    Calling(conversation): Calling,
    Path(name): Path<String>,
    body: Bytes,
) -> Response {
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
    let done = handler.call(conversation, &name, Value::Object(args)).await;
    answer(StatusCode::OK, &outcome(done))
}

/// A call's outcome, as its caller reads it.
fn outcome(done: Result<Value, Failure>) -> Value {
    match done {
        Ok(value) => json!({ "ok": true, "value": value }),
        Err(Failure { code, message, .. }) => {
            json!({ "ok": false, "error": { "code": code, "message": message } })
        }
    }
}

impl Handler {
    /// Has the conversation's actor run the call: its result. The actor
    /// stops it when this stops waiting, as when the caller closes its
    /// connection. One Max stopped with it in its hands is `closed`: it
    /// may have acted.
    async fn call(
        &self,
        conversation: ConversationId,
        tool: &str,
        args: Value,
    ) -> Result<Value, Failure> {
        let slots = {
            let mut slots = self.slots.lock().unwrap_or_else(PoisonError::into_inner);
            let slots = slots.entry(conversation);
            Arc::clone(slots.or_insert_with(|| Arc::new(Semaphore::new(CALLS_AT_ONCE))))
        };
        let call = async {
            let _slot = slots.acquire().await;
            let (reply, result) = oneshot::channel();
            let call = Signal::Call {
                conversation,
                tool: tool.to_owned(),
                args,
                reply,
            };
            self.calls.send(call).map_err(|_| Failure::closed())?;
            result.await.unwrap_or_else(|_| Err(Failure::closed()))
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
    use std::path::PathBuf;
    use std::time::Duration;

    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    use super::*;

    use crate::scope::Scope;

    /// A directory of the test's own for its sockets.
    fn sockets(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("max-http-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// Every process is of `conversation`'s VM, or of none's.
    fn all(conversation: Option<i64>) -> Whose {
        Arc::new(move |_| Box::pin(async move { conversation.map(ConversationId::new) }))
    }

    /// A call is the VM's whose process made its connection, whatever the
    /// request says of itself; one that no VM's process made is nobody's.
    #[tokio::test]
    async fn a_call_is_the_vms_that_made_its_connection() {
        let dir = sockets("whose");
        let (calls, mut called) = tokio::sync::mpsc::unbounded_channel();
        let mut scope = Scope::new();
        // Two sockets: at one every connection is the test's own process
        // and is taken for conversation 9's VM's, at the other for no
        // VM's.
        let (mine, nobodys) = (dir.join("mine.sock"), dir.join("nobodys.sock"));
        let me = i32::try_from(std::process::id()).unwrap();
        let whose: Whose = Arc::new(move |pid| {
            Box::pin(async move { (pid == me).then_some(ConversationId::new(9)) })
        });
        for (socket, whose) in [(&mine, whose), (&nobodys, all(None))] {
            let _ = std::fs::remove_file(socket);
            let listener = Waited::new(UnixListener::bind(socket).unwrap(), whose);
            let app = router(calls.clone(), axum::Router::new());
            scope.spawn(move |stop| serve(listener, app, stop));
        }
        let asked = async |socket: &PathBuf| {
            let request = "POST /tools/say HTTP/1.1\r\nHost: max\r\nmax-conversation: 7\r\n\
                 Content-Length: 2\r\nConnection: close\r\n\r\n{}";
            let mut stream = UnixStream::connect(socket).await.unwrap();
            stream.write_all(request.as_bytes()).await.unwrap();
            let mut reply = String::new();
            stream.read_to_string(&mut reply).await.unwrap();
            reply
        };

        let actor = async {
            let Some(Signal::Call {
                conversation,
                reply,
                ..
            }) = called.recv().await
            else {
                panic!("no call came");
            };
            let _ = reply.send(Ok(json!({ "of": conversation.get() })));
        };
        let (reply, ()) = tokio::join!(asked(&mine), actor);
        assert!(
            reply.ends_with(r#"{"ok":true,"value":{"of":9}}"#),
            "{reply}"
        );

        let reply = asked(&nobodys).await;
        assert!(reply.starts_with("HTTP/1.1 400 Bad Request"), "{reply}");
        assert!(reply.contains(r#""code":"bad_request""#), "{reply}");
        assert!(called.try_recv().is_err(), "nobody's call was begun");

        scope.close(Duration::from_secs(5)).await;
        let _ = std::fs::remove_dir_all(dir);
    }

    /// A call waits at the socket while max restarts. One whose caller
    /// gave up meanwhile is still there to read when max is back, and
    /// isn't begun; one whose caller waits is.
    #[tokio::test]
    async fn a_call_whose_caller_left_while_it_waited_isnt_begun() {
        let dir = sockets("left");
        let socket = dir.join("mine.sock");
        let _ = std::fs::remove_file(&socket);
        let listener = UnixListener::bind(&socket).unwrap();
        let request = |text: &str| {
            let body = json!({ "text": text }).to_string();
            format!(
                "POST /tools/say HTTP/1.1\r\nHost: max\r\nContent-Length: {}\r\n\r\n{body}",
                body.len()
            )
        };
        // Nobody takes connections yet: both wait, and the first one's
        // caller goes.
        let mut left = UnixStream::connect(&socket).await.unwrap();
        left.write_all(request("走了").as_bytes()).await.unwrap();
        drop(left);
        let mut waits = UnixStream::connect(&socket).await.unwrap();
        waits.write_all(request("还在").as_bytes()).await.unwrap();

        let (calls, mut called) = tokio::sync::mpsc::unbounded_channel();
        let mut scope = Scope::new();
        let app = router(calls, axum::Router::new());
        scope.spawn(move |stop| serve(Waited::new(listener, all(Some(1))), app, stop));
        let Some(Signal::Call { args, reply, .. }) = called.recv().await else {
            panic!("no call came");
        };
        assert_eq!(args, json!({ "text": "还在" }));
        let _ = reply.send(Ok(json!({})));
        let mut answer = vec![0; 1024];
        let read = waits.read(&mut answer).await.unwrap();
        assert!(answer[..read].starts_with(b"HTTP/1.1 200 OK"));
        assert!(called.try_recv().is_err(), "the call nobody waits for");

        scope.close(Duration::from_secs(5)).await;
        let _ = std::fs::remove_dir_all(dir);
    }
}
