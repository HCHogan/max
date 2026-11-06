//! `/job/…` on each group's MCP service: what a background agent's
//! harness calls, by its job's token, for what only a job does. So far
//! `POST /job/ask`, `ask_max`'s question to Max: the answer is a JSON line,
//! `{"answer": …}`, null if none came; until then a line with nothing on
//! it every so often, as `/events` sends, so that the harness's client
//! doesn't give up on a wait of minutes. See "和 harness 脱钩" in
//! docs/rust-rewrite.md.

use std::io;
use std::time::Duration;

use axum::Router;
use axum::body::{Body, Bytes};
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::Response;
use axum::routing::post;
use futures_util::Stream;
use max_core::ids::ConversationId;
use serde::Deserialize;
use serde_json::json;
use tokio::sync::oneshot;
use tokio::time::sleep;
use tokio_util::sync::CancellationToken;

use super::{Caller, Sessions};
use crate::job::Question;

/// How long the answer's stream goes without a line before the heartbeat.
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
        .route("/job/ask", post(ask))
        .with_state(Harness {
            conversation,
            sessions,
            heartbeat,
        })
}

#[derive(Deserialize)]
struct Asked {
    question: String,
}

async fn ask(State(harness): State<Harness>, headers: HeaderMap, body: Bytes) -> Response {
    let authorization = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok());
    let Some(session) = harness.sessions.bearer(authorization, harness.conversation) else {
        return refuse(
            StatusCode::UNAUTHORIZED,
            "token 不对，或者这个 job 已经结束了",
        );
    };
    let Caller::Job(job) = &session.context.caller else {
        return refuse(StatusCode::FORBIDDEN, "只有后台 agent 能问 Max");
    };
    let Ok(Asked { question }) = serde_json::from_slice(&body) else {
        return refuse(StatusCode::BAD_REQUEST, r#"要 {"question": "问题"}"#);
    };
    let (answer, answered) = oneshot::channel();
    let asked = Question {
        text: question,
        answer,
    };
    if job.asks.send(asked).is_err() {
        return refuse(StatusCode::GONE, "这个 job 已经结束了");
    }
    let lines = lines(answered, session.closed.clone(), harness.heartbeat);
    Response::builder()
        .header(header::CONTENT_TYPE, "application/x-ndjson")
        .body(Body::from_stream(lines))
        .unwrap_or_else(|_| refuse(StatusCode::INTERNAL_SERVER_ERROR, "回答做不出来"))
}

/// The heartbeat until the answer comes, then the answer: null if the job
/// gave up on the question, or ended.
fn lines(
    answered: oneshot::Receiver<Option<String>>,
    closed: CancellationToken,
    heartbeat: Duration,
) -> impl Stream<Item = io::Result<Bytes>> {
    futures_util::stream::unfold(Some(answered), move |answered| {
        let closed = closed.clone();
        async move {
            let mut answered = answered?;
            let answer = tokio::select! {
                answer = &mut answered => answer.ok().flatten(),
                () = closed.cancelled() => None,
                () = sleep(heartbeat) => return Some((Ok(Bytes::from_static(b"\n")), Some(answered))),
            };
            let line = format!("{}\n", json!({ "answer": answer }));
            Some((Ok(Bytes::from(line)), None))
        }
    })
}

fn refuse(status: StatusCode, message: &str) -> Response {
    let body = json!({ "error": { "message": message } }).to_string();
    Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(body))
        .unwrap_or_default()
}

#[cfg(test)]
mod tests;
