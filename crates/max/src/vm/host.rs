//! The VM service's own route on each group's MCP service: max-units
//! POSTs `{"units": 2}` to `/units` and gets `{"ok": true, "said": "…"}`
//! back. Which group it comes from is the VM's own socket's to say, so
//! there is no token. See "Resident programs" in docs/rust-rewrite.md.

use std::time::Duration;

use axum::Router;
use axum::body::Bytes;
use axum::extract::State;
use axum::http::header;
use axum::response::IntoResponse;
use axum::routing::post;
use max_core::ids::ConversationId;
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc::UnboundedSender;
use tokio::sync::oneshot;
use tokio::time::timeout;

use super::Internal;

/// How long Max has to answer.
const WAIT: Duration = Duration::from_secs(10);

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Units {
    units: u32,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
struct Answer {
    ok: bool,
    said: String,
}

impl Answer {
    fn refused(said: impl Into<String>) -> Self {
        Self {
            ok: false,
            said: said.into(),
        }
    }
}

#[derive(Clone)]
struct Host {
    conversation: ConversationId,
    service: UnboundedSender<Internal>,
}

pub fn router(conversation: ConversationId, service: UnboundedSender<Internal>) -> Router {
    Router::new().route("/units", post(units)).with_state(Host {
        conversation,
        service,
    })
}

async fn units(State(host): State<Host>, body: Bytes) -> impl IntoResponse {
    let answer = answered(&host, &body).await;
    let json = serde_json::to_string(&answer).expect("an answer is JSON");
    ([(header::CONTENT_TYPE, "application/json")], json)
}

async fn answered(host: &Host, body: &[u8]) -> Answer {
    let units = match serde_json::from_slice::<Units>(body) {
        Ok(Units { units }) => units,
        Err(error) => return Answer::refused(format!("看不懂的请求：{error}")),
    };
    let (reply, said) = oneshot::channel();
    let asked = Internal::Units {
        conversation: host.conversation,
        count: units,
        reply,
    };
    if host.service.send(asked).is_err() {
        return Answer::refused("Max 正在停");
    }
    match timeout(WAIT, said).await {
        Ok(Ok(Ok(said))) => Answer { ok: true, said },
        Ok(Ok(Err(said))) => Answer::refused(said),
        _ => Answer::refused("没等到 Max 的回答"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scope::Scope;

    #[tokio::test]
    async fn the_units_are_answered_by_the_service() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/units", listener.local_addr().unwrap());
        let (service, mut asked) = tokio::sync::mpsc::unbounded_channel();
        let app = router(ConversationId(7), service);
        let mut scope = Scope::new();
        scope.spawn(move |stop| async move {
            let _ = axum::serve(listener, app)
                .with_graceful_shutdown(stop.cancelled_owned())
                .await;
        });
        scope.spawn(move |_| async move {
            while let Some(Internal::Units {
                conversation,
                count,
                reply,
            }) = asked.recv().await
            {
                let _ = reply.send(Ok(format!("会话 {conversation}：{count} 个")));
            }
        });
        let client = reqwest::Client::new();
        let answer = client.post(&url).json(&serde_json::json!({"units": 2}));
        let answer = answer.send().await.unwrap().text().await.unwrap();
        assert_eq!(answer, "{\"ok\":true,\"said\":\"会话 7：2 个\"}");
        let refused = client.post(&url).json(&serde_json::json!({"sleep": 1}));
        let refused = refused.send().await.unwrap().text().await.unwrap();
        assert!(
            refused.starts_with("{\"ok\":false,\"said\":\"看不懂的请求"),
            "{refused}"
        );
        scope.close(Duration::from_secs(1)).await;
    }
}
