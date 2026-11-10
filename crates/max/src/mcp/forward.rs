//! A background agent's model calls: pi in the VM posts them to `/llm/…`
//! with its session's token, and they go on to the provider with the
//! provider's key, as they came but for the model id: the other fields
//! are passed on as pi wrote them, not parsed. The answer streams
//! back as it is, and is broken off if the provider keeps quiet as long
//! as max-llm would wait: pi takes it for a failed call, and retries.
//! On the way back it is read for what the call used, the tools it
//! called and how long it took, which the job hears once the call is
//! over. See "Background agents" in docs/rust-rewrite.md.

use std::time::Duration;
use std::{fmt, io};

use axum::Router;
use axum::body::{Body, Bytes};
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::Response;
use axum::routing::post;
use futures_util::{Stream, StreamExt};
use max_core::ids::ConversationId;
use max_core::item::{Protocol, Timing};
use max_llm::Meter;
use serde::de::{MapAccess, Visitor};
use serde::ser::SerializeMap;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::json;
use serde_json::value::RawValue;
use tokio::sync::mpsc::UnboundedSender;
use tokio::time::{Instant, timeout};

use super::{Caller, Sessions};
use crate::job::Called;

pub mod api;

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
            "the token is wrong, or its job has ended",
        );
    };
    let Caller::Job(job) = &session.context.caller else {
        return refuse(StatusCode::FORBIDDEN, "this session may not call the model");
    };
    let upstream = &job.upstream;
    let endpoint = match upstream.protocol {
        Protocol::Chat => "chat/completions",
        Protocol::Responses => "responses",
    };
    if path != endpoint {
        return refuse(
            StatusCode::NOT_FOUND,
            &format!("there is only /llm/{endpoint}"),
        );
    }
    let Ok(Fields(mut fields)) = serde_json::from_slice::<Fields<'_>>(&body) else {
        return refuse(StatusCode::BAD_REQUEST, "the request isn't a JSON object");
    };
    let model = serde_json::value::to_raw_value(&upstream.model).expect("a string is JSON");
    match fields.iter_mut().find(|(name, _)| name == "model") {
        Some(field) => field.1 = &model,
        None => fields.push(("model".to_owned(), &model)),
    }
    let url = format!("{}/{endpoint}", upstream.base_url.trim_end_matches('/'));
    let mut sending = forward.client.post(url).json(&Fields(fields));
    if let Some(key) = &upstream.api_key {
        sending = sending.bearer_auth(key);
    }
    for (name, value) in &upstream.headers {
        sending = sending.header(name, value);
    }
    let idle = upstream.idle;
    // Told when dropped: here if no answer comes, or with the answer's body.
    let mut metering = Metering::new(upstream.protocol, job.called.clone());
    let sent = tokio::select! {
        sent = timeout(idle, sending.send()) => sent,
        () = session.closed.cancelled() => {
            return refuse(StatusCode::GONE, "this job has ended");
        }
    };
    metering.arrived();
    let answer = match sent {
        Ok(Ok(answer)) => answer,
        Ok(Err(error)) => {
            return refuse(
                StatusCode::BAD_GATEWAY,
                &format!("can't reach the model: {error}"),
            );
        }
        Err(_) => {
            let quiet = format!("the model said nothing for {} seconds", idle.as_secs());
            return refuse(StatusCode::GATEWAY_TIMEOUT, &quiet);
        }
    };
    let mut response = Response::builder().status(answer.status());
    if let Some(kind) = answer.headers().get(header::CONTENT_TYPE) {
        response = response.header(header::CONTENT_TYPE, kind);
    }
    response
        .body(Body::from_stream(chunks(answer, idle).map(move |chunk| {
            metering.arrived();
            if let Ok(chunk) = &chunk {
                metering.read(chunk);
            }
            chunk
        })))
        .unwrap_or_else(|_| {
            refuse(
                StatusCode::BAD_GATEWAY,
                "the model's answer couldn't be passed on",
            )
        })
}

/// A JSON object's fields in order, their values as they were written.
struct Fields<'a>(Vec<(String, &'a RawValue)>);

impl<'de> Deserialize<'de> for Fields<'de> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct Object;

        impl<'de> Visitor<'de> for Object {
            type Value = Fields<'de>;

            fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str("a JSON object")
            }

            fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Fields<'de>, A::Error> {
                let mut fields = Vec::new();
                while let Some(field) = map.next_entry()? {
                    fields.push(field);
                }
                Ok(Fields(fields))
            }
        }

        deserializer.deserialize_map(Object)
    }
}

impl Serialize for Fields<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(Some(self.0.len()))?;
        for (name, value) in &self.0 {
            map.serialize_entry(name, value)?;
        }
        map.end()
    }
}

/// The answer's body, ended with an error if no chunk comes within `idle`.
fn chunks(answer: reqwest::Response, idle: Duration) -> impl Stream<Item = io::Result<Bytes>> {
    futures_util::stream::unfold(Some(answer), move |answer| async move {
        let mut answer = answer?;
        match timeout(idle, answer.chunk()).await {
            Ok(Ok(Some(chunk))) => Some((Ok(chunk), Some(answer))),
            Ok(Ok(None)) => None,
            Ok(Err(error)) => Some((Err(io::Error::other(error)), None)),
            Err(_) => {
                let quiet = io::Error::new(io::ErrorKind::TimedOut, "the provider kept quiet");
                Some((Err(quiet), None))
            }
        }
    })
}

/// A model call as it goes: what it says read by a [`Meter`], and its
/// times, as max-llm keeps them for Max's own calls. Dropped, it tells
/// the job: the answer ended, broke off, or pi stopped reading it.
struct Metering {
    meter: Meter,
    sent: Instant,
    arrived: Instant,
    first: Option<Duration>,
    quiet: Duration,
    called: UnboundedSender<Called>,
}

impl Metering {
    /// Starts the clock.
    fn new(protocol: Protocol, called: UnboundedSender<Called>) -> Self {
        let now = Instant::now();
        Self {
            meter: Meter::new(protocol),
            sent: now,
            arrived: now,
            first: None,
            quiet: Duration::ZERO,
            called,
        }
    }

    /// Something came: the answer's head, a chunk, or an error.
    fn arrived(&mut self) {
        let now = Instant::now();
        self.quiet = self.quiet.max(now - self.arrived);
        self.arrived = now;
    }

    fn read(&mut self, chunk: &[u8]) {
        self.meter.push(chunk);
        if self.first.is_none() && self.meter.started() {
            self.first = Some(self.arrived - self.sent);
        }
    }
}

impl Drop for Metering {
    fn drop(&mut self) {
        let called = Called {
            usage: self.meter.usage(),
            timing: Timing {
                first: self.first,
                took: self.arrived - self.sent,
                quiet: self.quiet,
            },
            tools: self.meter.tools(),
        };
        // The job is over: nobody is counting.
        let _ = self.called.send(called);
    }
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
