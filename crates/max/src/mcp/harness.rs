//! `/job/…` on each group's MCP service: what a background agent's
//! harness calls, by its job's token, for what only a job does; see "Decoupling
//! from the harness" in docs/rust-rewrite.md.
//!
//! - `POST /job/turn`, at each turn's end: `{"steers": […], "stop": …}`.
//! - `GET /job/stop`, open the whole job: a line `{"stop": true}` once it
//!   is to stop, at once if it already is; the stream ends with nothing
//!   when the job does.
//! - `POST /job/ask` `{"question"}`, `ask_max`'s question to Max: a line
//!   `{"answer": …}`, null if none came.
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
use crate::job::{Hook, Link, Question, Report};

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
        .route("/job/ask", post(ask))
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

async fn turn(State(harness): State<Harness>, headers: HeaderMap) -> Response {
    let (session, link) = match job(&harness, &headers) {
        Ok(job) => job,
        Err((status, why)) => return refuse(status, why),
    };
    let (reply, replied) = oneshot::channel();
    if link.hooks.send(Hook::Turn(reply)).is_err() {
        return refuse(StatusCode::GONE, OVER);
    }
    let turn = tokio::select! {
        turn = replied => turn.ok(),
        () = session.closed.cancelled() => None,
    };
    match turn {
        Some(turn) => answer(StatusCode::OK, &json!(turn)),
        None => refuse(StatusCode::GONE, OVER),
    }
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

#[derive(Deserialize)]
struct Asked {
    question: String,
}

async fn ask(State(harness): State<Harness>, headers: HeaderMap, body: Bytes) -> Response {
    let (session, link) = match job(&harness, &headers) {
        Ok(job) => job,
        Err((status, why)) => return refuse(status, why),
    };
    let Ok(Asked { question }) = serde_json::from_slice(&body) else {
        return refuse(StatusCode::BAD_REQUEST, r#"expected {"question": "…"}"#);
    };
    let (answer, answered) = oneshot::channel();
    let asked = Question {
        text: question,
        answer,
    };
    if link.hooks.send(Hook::Ask(asked)).is_err() {
        return refuse(StatusCode::GONE, OVER);
    }
    // Null if the job gave up on the question, or ended.
    let closed = session.closed.clone();
    let answered = async move {
        let answer = tokio::select! {
            answer = answered => answer.ok().flatten(),
            () = closed.cancelled() => None,
        };
        Some(json!({ "answer": answer }))
    };
    streamed(lines(answered, harness.heartbeat))
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
