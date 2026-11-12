//! The background agents' model calls: pi in a VM posts them to
//! `/llm/…`, and they go on to the provider with the provider's key, as
//! they came but for the model id: the other fields are passed on as pi
//! wrote them, not parsed. The answer streams back as it is, and is
//! broken off if the provider keeps quiet as long as max-llm would wait:
//! pi takes it for a failed call, and retries. On the way back it is read
//! for what the call used and how long it took, which is recorded for the
//! conversation.
//!
//! A call names its model as the configuration does, `provider/model`,
//! and any configured model can be named: Max starts an agent on the one
//! it wants (nix/max-agent.sh). A call that names none, or one that isn't
//! configured, goes to the agents' own, `llm.job`.
//!
//! Any call on a VM's socket is taken: the socket says which conversation
//! pays, and nothing in the VM holds a key or a token. An agent is a unit
//! of the guest's, which max keeps nothing of; `GET /llm` tells it what
//! the models are. See "Background agents" in docs/rust-rewrite.md.

use std::sync::Arc;
use std::time::Duration;
use std::{fmt, io};

use axum::Router;
use axum::body::{Body, Bytes};
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use chrono::Utc;
use futures_util::{Stream, StreamExt};
use max_core::ids::ConversationId;
use max_core::item::{Protocol, Timing, Usage};
use max_db::usage;
use max_llm::Meter;
use serde::de::{MapAccess, Visitor};
use serde::ser::SerializeMap;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::json;
use serde_json::value::RawValue;
use sqlx::PgPool;
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel};
use tokio::time::{Instant, timeout};

use crate::llm::{Upstream, Upstreams};
use crate::scope::Scope;

pub mod api;

/// A request carries the agent's whole context.
const LARGEST: usize = 64 << 20;
const CONNECT: Duration = Duration::from_secs(10);

/// The models the VMs call: where each one's calls go, and who is told
/// what each call used.
#[derive(Clone)]
pub struct Models {
    upstreams: Arc<Upstreams>,
    used: UnboundedSender<(ConversationId, Called)>,
}

/// A model call from a VM, as it was read on its way back; told however
/// the call ended.
#[derive(Debug)]
pub struct Called {
    /// The model it went to.
    pub upstream: Arc<Upstream>,
    /// How hard the request asked it to think, if it said.
    pub effort: Option<String>,
    pub usage: Usage,
    pub timing: Timing,
}

impl Models {
    /// The models at `upstreams`. A task in `scope` records each call's
    /// usage for the conversation whose VM made it.
    pub fn start(upstreams: Upstreams, pool: PgPool, scope: &mut Scope) -> Self {
        let (models, mut used) = Self::heard(upstreams);
        scope.spawn(move |_| async move {
            while let Some((conversation, called)) = used.recv().await {
                // A call that failed before the provider counted anything.
                if called.usage == Usage::default() {
                    continue;
                }
                let call = usage::Call {
                    conversation: Some(conversation),
                    turn: None,
                    purpose: usage::Purpose::Job,
                    provider: &called.upstream.provider,
                    model: &called.upstream.model,
                    effort: called.effort.as_deref(),
                    usage: called.usage,
                    cost_micros: None,
                    timing: Some(called.timing),
                    at: Utc::now(),
                };
                crate::llm::record(&pool, &call).await;
            }
        });
        models
    }

    /// The models at `upstreams`, and where what each call used is heard,
    /// for whoever counts it: `start` records it.
    pub fn heard(upstreams: Upstreams) -> (Self, UnboundedReceiver<(ConversationId, Called)>) {
        let (used, heard) = unbounded_channel();
        let models = Self {
            upstreams: Arc::new(upstreams),
            used,
        };
        (models, heard)
    }
}

#[derive(Clone)]
struct Forward {
    conversation: ConversationId,
    models: Option<Models>,
    client: reqwest::Client,
}

/// `/llm` and `/llm/…` for the VM of `conversation`: the `models` it may
/// call, if the agents have one.
pub fn router(conversation: ConversationId, models: Option<Models>) -> Router {
    let client = reqwest::Client::builder()
        .connect_timeout(CONNECT)
        .build()
        .expect("a client with a connect timeout builds");
    let forward = Forward {
        conversation,
        models,
        client,
    };
    Router::new()
        .route("/llm", get(about))
        .route("/llm/{*path}", post(call))
        .layer(DefaultBodyLimit::max(LARGEST))
        .with_state(forward)
}

/// Why there is no model to call.
const NONE: &str = "no model is configured for background agents";

/// What an agent's harness needs to know of a model before it calls it:
/// the protocol, as pi names it, the name to call it by, the window, and
/// the most it writes.
fn described(name: &str, upstream: &Upstream) -> serde_json::Value {
    let api = match upstream.protocol {
        Protocol::Chat => "openai-completions",
        Protocol::Responses => "openai-responses",
    };
    json!({
        "api": api,
        "model": name,
        "window": upstream.window,
        "max_output": upstream.max_output,
    })
}

/// The agents' own model, with its effort, and under `models` every one
/// a call can name.
async fn about(State(forward): State<Forward>) -> Response {
    let Some(models) = &forward.models else {
        return refuse(StatusCode::NOT_FOUND, NONE);
    };
    let upstreams = &models.upstreams;
    let mut about = described(&upstreams.default.reference(), &upstreams.default);
    about["effort"] = json!(upstreams.effort);
    about["models"] = upstreams
        .all
        .iter()
        .map(|(name, upstream)| described(name, upstream))
        .collect();
    let json = [(header::CONTENT_TYPE, "application/json")];
    (json, about.to_string()).into_response()
}

async fn call(State(forward): State<Forward>, Path(path): Path<String>, body: Bytes) -> Response {
    let Some(models) = &forward.models else {
        return refuse(StatusCode::NOT_FOUND, NONE);
    };
    let Ok(Fields(mut fields)) = serde_json::from_slice::<Fields<'_>>(&body) else {
        return refuse(StatusCode::BAD_REQUEST, "the request isn't a JSON object");
    };
    let named: Option<String> = field(&fields, "model");
    let upstream = Arc::clone(models.upstreams.named(named.as_deref()));
    let endpoint = match upstream.protocol {
        Protocol::Chat => "chat/completions",
        Protocol::Responses => "responses",
    };
    if path != endpoint {
        let name = upstream.reference();
        return refuse(
            StatusCode::NOT_FOUND,
            &format!("{name} is called at /llm/{endpoint}"),
        );
    }
    let effort = effort(upstream.protocol, &fields);
    let id = serde_json::value::to_raw_value(&upstream.model).expect("a string is JSON");
    match fields.iter_mut().find(|(name, _)| name == "model") {
        Some(field) => field.1 = &id,
        None => fields.push(("model".to_owned(), &id)),
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
    // Told when dropped: here if no answer comes, or with the answer's
    // body; and if the agent stops reading, as when its unit is stopped.
    let mut metering = Metering::new(
        Arc::clone(&upstream),
        effort,
        forward.conversation,
        models.used.clone(),
    );
    let sent = timeout(idle, sending.send()).await;
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

/// The field `name`, if it is there and is a `T`.
fn field<T: for<'de> Deserialize<'de>>(fields: &[(String, &RawValue)], name: &str) -> Option<T> {
    let (_, value) = fields.iter().find(|(field, _)| field == name)?;
    serde_json::from_str(value.get()).ok()
}

/// How hard a request asks its model to think, where each protocol says
/// it: read for the record, and passed on as it is.
fn effort(protocol: Protocol, fields: &[(String, &RawValue)]) -> Option<String> {
    #[derive(Deserialize)]
    struct Reasoning {
        effort: Option<String>,
    }
    match protocol {
        Protocol::Chat => field(fields, "reasoning_effort"),
        Protocol::Responses => field::<Reasoning>(fields, "reasoning")?.effort,
    }
}

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
/// what the call used: the answer ended, broke off, or pi stopped
/// reading it.
struct Metering {
    upstream: Arc<Upstream>,
    effort: Option<String>,
    meter: Meter,
    sent: Instant,
    arrived: Instant,
    first: Option<Duration>,
    quiet: Duration,
    conversation: ConversationId,
    used: UnboundedSender<(ConversationId, Called)>,
}

impl Metering {
    /// Starts the clock.
    fn new(
        upstream: Arc<Upstream>,
        effort: Option<String>,
        conversation: ConversationId,
        used: UnboundedSender<(ConversationId, Called)>,
    ) -> Self {
        let now = Instant::now();
        Self {
            meter: Meter::new(upstream.protocol),
            upstream,
            effort,
            sent: now,
            arrived: now,
            first: None,
            quiet: Duration::ZERO,
            conversation,
            used,
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
            upstream: Arc::clone(&self.upstream),
            effort: self.effort.take(),
            usage: self.meter.usage(),
            timing: Timing {
                first: self.first,
                took: self.arrived - self.sent,
                quiet: self.quiet,
            },
        };
        // max is stopping: nobody is counting.
        let _ = self.used.send((self.conversation, called));
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
