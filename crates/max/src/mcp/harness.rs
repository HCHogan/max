//! `/job/…` on each group's MCP service: what a background agent's
//! harness calls, by its job's token, for what only a job does; see "Decoupling
//! from the harness" in docs/rust-rewrite.md.
//!
//! - `POST /job/turn` `{"settling"}`, at each turn's end, and once more
//!   as the agent is about to settle: a line `{"steers": […], "stop": …}`.
//!   One about to settle while the agent's questions wait for their
//!   answers is answered once something comes for it, or after a while.
//! - `GET /job/stop`, open the whole job: a line `{"stop": true}` once it
//!   is to stop, at once if it already is; the stream ends with nothing
//!   when the job does.
//! - `POST /job/report` `{"text", "error"}`, once the agent has settled.
//!
//! A stream sends a line with nothing on it every so often, as `/events`
//! does, so that the harness's client doesn't give up on a wait of
//! minutes, or takes a stream gone quiet for broken.

use std::io;
use std::sync::Arc;
use std::time::Duration;

use axum::Router;
use axum::body::{Body, Bytes};
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::Response;
use axum::routing::{get, post};
use futures_util::Stream;
use max_core::ids::ConversationId;
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::oneshot;
use tokio::time::sleep;

use super::service::Session;
use super::{Caller, Sessions};
use crate::job::{Hook, Link, Report};

/// How long a stream goes without a line before the heartbeat.
const HEARTBEAT: Duration = Duration::from_secs(30);

#[derive(Clone)]
struct Harness {
    conversation: ConversationId,
    sessions: Sessions,
    heartbeat: Duration,
}

/// `/job/…` for the VM of `conversation`.
pub fn router(conversation: ConversationId, sessions: Sessions) -> Router {
    beating(conversation, sessions, HEARTBEAT)
}

fn beating(conversation: ConversationId, sessions: Sessions, heartbeat: Duration) -> Router {
    Router::new()
        .route("/job/turn", post(turn))
        .route("/job/stop", get(stop))
        .route("/job/report", post(report))
        .with_state(Harness {
            conversation,
            sessions,
            heartbeat,
        })
}

const OVER: &str = "this job has ended";

/// Why a call isn't a job's: the status, and the message.
type Refused = (StatusCode, &'static str);

/// The job whose token `headers` carry, and its session.
fn job(harness: &Harness, headers: &HeaderMap) -> Result<(Arc<Session>, Arc<Link>), Refused> {
    let authorization = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok());
    let Some(session) = harness.sessions.bearer(authorization, harness.conversation) else {
        return Err((
            StatusCode::UNAUTHORIZED,
            "the token is wrong, or its job has ended",
        ));
    };
    let Caller::Job(link) = &session.context.caller else {
        return Err((
            StatusCode::FORBIDDEN,
            "only a background agent may use /job",
        ));
    };
    let link = Arc::clone(link);
    Ok((session, link))
}

#[derive(Default, Deserialize)]
struct Ended {
    /// The agent is about to settle, rather than going on.
    #[serde(default)]
    settling: bool,
}

async fn turn(State(harness): State<Harness>, headers: HeaderMap, body: Bytes) -> Response {
    let (session, link) = match job(&harness, &headers) {
        Ok(job) => job,
        Err((status, why)) => return refuse(status, why),
    };
    // An empty body is a turn's end that goes on.
    let ended = match body.is_empty() {
        true => Ok(Ended::default()),
        false => serde_json::from_slice(&body),
    };
    let Ok(Ended { settling }) = ended else {
        return refuse(StatusCode::BAD_REQUEST, r#"expected {"settling": false}"#);
    };
    let (reply, replied) = oneshot::channel();
    if link.hooks.send(Hook::Turn { settling, reply }).is_err() {
        return refuse(StatusCode::GONE, OVER);
    }
    let closed = session.closed.clone();
    let turned = async move {
        tokio::select! {
            turn = replied => turn.ok().map(|turn| json!(turn)),
            () = closed.cancelled() => None,
        }
    };
    if !settling {
        return match turned.await {
            Some(turn) => answer(StatusCode::OK, &turn),
            None => refuse(StatusCode::GONE, OVER),
        };
    }
    // It may be held for a while: heartbeats until its line, or nothing
    // if the job ends first. Dropped with the stream, it took none of the
    // steers.
    streamed(lines(turned, harness.heartbeat))
}

async fn stop(State(harness): State<Harness>, headers: HeaderMap) -> Response {
    let (session, link) = match job(&harness, &headers) {
        Ok(job) => job,
        Err((status, why)) => return refuse(status, why),
    };
    let closed = session.closed.clone();
    let stopped = async move {
        tokio::select! {
            biased;
            () = link.stop.cancelled() => Some(json!({ "stop": true })),
            () = closed.cancelled() => None,
        }
    };
    streamed(lines(stopped, harness.heartbeat))
}

async fn report(State(harness): State<Harness>, headers: HeaderMap, body: Bytes) -> Response {
    let link = match job(&harness, &headers) {
        Ok((_, link)) => link,
        Err((status, why)) => return refuse(status, why),
    };
    let Ok(report) = serde_json::from_slice::<Report>(&body) else {
        return refuse(
            StatusCode::BAD_REQUEST,
            r#"expected {"text": "the last text", "error": null}"#,
        );
    };
    if link.hooks.send(Hook::Report(report)).is_err() {
        return refuse(StatusCode::GONE, OVER);
    }
    answer(StatusCode::OK, &json!({}))
}

/// The heartbeat until `until` is done, then its line, if it has one.
fn lines(
    until: impl Future<Output = Option<Value>> + Send + 'static,
    heartbeat: Duration,
) -> impl Stream<Item = io::Result<Bytes>> {
    futures_util::stream::unfold(Some(Box::pin(until)), move |until| async move {
        let mut until = until?;
        tokio::select! {
            line = &mut until => line.map(|line| (Ok(Bytes::from(format!("{line}\n"))), None)),
            () = sleep(heartbeat) => Some((Ok(Bytes::from_static(b"\n")), Some(until))),
        }
    })
}

fn streamed(lines: impl Stream<Item = io::Result<Bytes>> + Send + 'static) -> Response {
    Response::builder()
        .header(header::CONTENT_TYPE, "application/x-ndjson")
        .body(Body::from_stream(lines))
        .unwrap_or_else(|_| {
            refuse(
                StatusCode::INTERNAL_SERVER_ERROR,
                "the answer couldn't be made",
            )
        })
}

fn answer(status: StatusCode, body: &Value) -> Response {
    Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(body.to_string()))
        .unwrap_or_default()
}

fn refuse(status: StatusCode, message: &str) -> Response {
    answer(status, &json!({ "error": { "message": message } }))
}

#[cfg(test)]
mod tests;
