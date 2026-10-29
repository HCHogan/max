//! A background agent's model calls: pi in the VM posts them to `/llm/…`
//! with its session's token, and they go on to the provider with the
//! provider's key, as they came but for the model id. The answer streams
//! back as it is. See "后台 agent" in docs/rust-rewrite.md.

use std::time::Duration;

use axum::Router;
use axum::body::{Body, Bytes};
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::Response;
use axum::routing::post;
use max_core::ids::ConversationId;
use max_core::item::Protocol;
use serde_json::{Value, json};

use super::Sessions;

/// A request carries the agent's whole context.
const LARGEST: usize = 64 << 20;
const CONNECT: Duration = Duration::from_secs(10);

#[derive(Clone)]
struct Forward {
    conversation: ConversationId,
    sessions: Sessions,
    client: reqwest::Client,
}

/// `/llm/…` for the VM of `conversation`.
pub fn router(conversation: ConversationId, sessions: Sessions) -> Router {
    let client = reqwest::Client::builder()
        .connect_timeout(CONNECT)
        .build()
        .expect("a client with a connect timeout builds");
    let forward = Forward {
        conversation,
        sessions,
        client,
    };
    Router::new()
        .route("/llm/{*path}", post(call))
        .layer(DefaultBodyLimit::max(LARGEST))
        .with_state(forward)
}

async fn call(
    State(forward): State<Forward>,
    Path(path): Path<String>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let authorization = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok());
    let Some(session) = forward.sessions.bearer(authorization, forward.conversation) else {
        return refuse(
            StatusCode::UNAUTHORIZED,
            "token 不对，或者这个 job 已经结束了",
        );
    };
    let Some(upstream) = session.upstream.clone() else {
        return refuse(StatusCode::FORBIDDEN, "这个会话不能调模型");
    };
    let endpoint = match upstream.protocol {
        Protocol::Chat => "chat/completions",
        Protocol::Responses => "responses",
    };
    if path != endpoint {
        return refuse(StatusCode::NOT_FOUND, &format!("只有 /llm/{endpoint}"));
    }
    let mut request = match serde_json::from_slice::<Value>(&body) {
        Ok(request @ Value::Object(_)) => request,
        _ => return refuse(StatusCode::BAD_REQUEST, "请求不是 JSON 对象"),
    };
    request["model"] = Value::String(upstream.model.clone());
    let url = format!("{}/{endpoint}", upstream.base_url.trim_end_matches('/'));
    let mut sending = forward.client.post(url).json(&request);
    if let Some(key) = &upstream.api_key {
        sending = sending.bearer_auth(key);
    }
    for (name, value) in &upstream.headers {
        sending = sending.header(name, value);
    }
    let sent = tokio::select! {
        sent = sending.send() => sent,
        () = session.closed.cancelled() => {
            return refuse(StatusCode::GONE, "这个 job 已经结束了");
        }
    };
    let answer = match sent {
        Ok(answer) => answer,
        Err(error) => return refuse(StatusCode::BAD_GATEWAY, &format!("模型连不上：{error}")),
    };
    let mut response = Response::builder().status(answer.status());
    if let Some(kind) = answer.headers().get(header::CONTENT_TYPE) {
        response = response.header(header::CONTENT_TYPE, kind);
    }
    response
        .body(Body::from_stream(answer.bytes_stream()))
        .unwrap_or_else(|_| refuse(StatusCode::BAD_GATEWAY, "模型的回答转不了"))
}

/// An error as OpenAI's APIs put it, which pi shows the model.
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
