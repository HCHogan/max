//! The VM service's own route on max's service to the groups' VMs: `maxx
//! units apply` POSTs `{"units": 2}` to `/units` and gets `{"ok": true,
//! "said": "…"}` back. Which group it comes from is its connection's to
//! say (`service::Calling`), so there is no token. See "Resident
//! programs" in docs/design/jobs.md.

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
use crate::service::Calling;

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

pub fn router(service: UnboundedSender<Internal>) -> Router {
    Router::new()
        .route("/units", post(units))
        .with_state(service)
}

async fn units(
    State(service): State<UnboundedSender<Internal>>,
    Calling(conversation): Calling,
    body: Bytes,
) -> impl IntoResponse {
    let answer = answered(&service, conversation, &body).await;
    let json = serde_json::to_string(&answer).expect("an answer is JSON");
    ([(header::CONTENT_TYPE, "application/json")], json)
}

async fn answered(
    service: &UnboundedSender<Internal>,
    conversation: ConversationId,
    body: &[u8],
) -> Answer {
    let units = match serde_json::from_slice::<Units>(body) {
        Ok(Units { units }) => units,
        Err(error) => return Answer::refused(format!("can't make out the request: {error}")),
    };
    let (reply, said) = oneshot::channel();
    let asked = Internal::Units {
        conversation,
        count: units,
        reply,
    };
    if service.send(asked).is_err() {
        return Answer::refused("Max is stopping");
    }
    match timeout(WAIT, said).await {
        Ok(Ok(said)) => Answer { ok: true, said },
        _ => Answer::refused("Max never answered"),
    }
}
