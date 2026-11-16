//! The background agents' model calls: pi in a VM posts them to
//! `/llm/…`, and they go on to the provider with the provider's key, as
//! they came but for the model id: the other fields are passed on as pi
//! wrote them, not parsed. The answer streams back as it is, and is
//! broken off if the provider keeps quiet as long as max-llm would wait:
//! pi takes it for a failed call, and retries.
//!
//! A call names its model as the configuration does, `provider/model`,
//! and any configured model can be named: Max starts an agent on the one
//! it wants (nix/max-agent.sh). A call that names none, or one that isn't
//! configured, goes to the agents' own, `llm.job`.
//!
//! Each VM's forwarder serves this, a process that outlives max as the
//! VM does (`crate::forwarder`): a call isn't cut when max is deployed.
//!
//! Any call on a VM's socket is taken: nothing in the VM holds a key or
//! a token, and nothing is counted of what it calls, which is the
//! provider's to say. An agent is a unit of the guest's, which max keeps
//! nothing of; `GET /llm` tells it what the models are. See "Background
//! agents" in docs/design/jobs.md.

use std::sync::Arc;
use std::time::Duration;
use std::{fmt, io};

use axum::Router;
use axum::body::{Body, Bytes};
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use futures_util::Stream;
use max_core::item::Protocol;
use serde::de::{MapAccess, Visitor};
use serde::ser::SerializeMap;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::json;
use serde_json::value::RawValue;
use tokio::time::timeout;

use crate::llm::{Upstream, Upstreams};

pub mod api;

/// A request carries the agent's whole context.
const LARGEST: usize = 64 << 20;
const CONNECT: Duration = Duration::from_secs(10);

#[derive(Clone)]
struct Forward {
    /// The models the VMs call, and where each one's calls go.
    models: Option<Arc<Upstreams>>,
    client: reqwest::Client,
}

/// `/llm` and `/llm/…` for a VM: the `models` it may call, if the agents
/// have one.
pub fn router(models: Option<Arc<Upstreams>>) -> Router {
    let client = reqwest::Client::builder()
        .connect_timeout(CONNECT)
        .build()
        .expect("a client with a connect timeout builds");
    Router::new()
        .route("/llm", get(about))
        .route("/llm/{*path}", post(call))
        .layer(DefaultBodyLimit::max(LARGEST))
        .with_state(Forward { models, client })
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
    let Some(upstreams) = &forward.models else {
        return refuse(StatusCode::NOT_FOUND, NONE);
    };
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
    let upstream = models.named(named.as_deref());
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
    let id = serde_json::value::to_raw_value(&upstream.model).expect("a string is JSON");
    // One `model`, where the first was: of two, the provider might take
    // the one max didn't read, and the call go to another's model.
    let mut named = false;
    fields.retain_mut(|(name, value)| {
        if name != "model" {
            return true;
        }
        *value = &id;
        !std::mem::replace(&mut named, true)
    });
    if !named {
        fields.push(("model".to_owned(), &id));
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
    let answer = match timeout(idle, sending.send()).await {
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
        .body(Body::from_stream(chunks(answer, idle)))
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
