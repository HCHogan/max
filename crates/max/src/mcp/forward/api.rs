//! The HTTP APIs the VMs call through the host: a program in the VM sends
//! `/api/<name>/…` with no key, and it goes on to the API's base URL with
//! the key the host keeps, which never enters the VM. Only the calls the
//! configuration allows go, at most so many an hour; the answer comes back
//! as it is, a redirect too. See "Host-keyed APIs" in docs/rust-rewrite.md.

use std::collections::{BTreeMap, VecDeque};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use axum::Router;
use axum::body::{Body, Bytes};
use axum::extract::{DefaultBodyLimit, State};
use axum::http::header::{self, HeaderName, HeaderValue};
use axum::http::{HeaderMap, Method, StatusCode, Uri};
use axum::response::Response;
use axum::routing::any;
use color_eyre::eyre::{Result, WrapErr};
use max_core::ids::ConversationId;
use reqwest::Url;
use reqwest::redirect::Policy;
use tokio::time::timeout;
use tracing::info;

use super::{CONNECT, LARGEST, chunks, refuse};
use crate::config::{self, Rule};
use max_core::limits::HOUR;

/// The response's headers and every piece after them must arrive within
/// this; a call as a whole has no limit.
const IDLE: Duration = Duration::from_secs(60);

/// A program's headers that don't go on: its connection's, `Expect`
/// among them, which the host's own server answers (curl sends one with a
/// large body); and its own key, which may be its run's token.
const DROPPED: [HeaderName; 11] = [
    header::HOST,
    header::AUTHORIZATION,
    header::PROXY_AUTHORIZATION,
    header::CONNECTION,
    header::TE,
    header::TRAILER,
    header::TRANSFER_ENCODING,
    header::UPGRADE,
    header::CONTENT_LENGTH,
    header::EXPECT,
    header::ACCEPT_ENCODING,
];
/// The answer's headers that don't come back: the connection's.
const UNANSWERED: [HeaderName; 4] = [
    header::CONNECTION,
    header::TRAILER,
    header::TRANSFER_ENCODING,
    header::CONTENT_LENGTH,
];

/// The configured APIs, with their secrets.
#[derive(Default)]
pub struct Apis {
    table: BTreeMap<String, Api>,
    prompt: String,
}

struct Api {
    base: Url,
    headers: HeaderMap,
    query: Vec<(String, String)>,
    allow: Option<Vec<Rule>>,
    per_hour: Option<u32>,
    /// When its calls went, in the last hour.
    sent: Mutex<VecDeque<Instant>>,
}

impl Apis {
    /// The APIs `configured`, their secrets read.
    pub fn load(configured: &BTreeMap<String, config::Api>) -> Result<Self> {
        let mut table = BTreeMap::new();
        let mut lines = Vec::new();
        for (name, api) in configured {
            let loaded = Api::load(api).wrap_err_with(|| format!("in api.{name}"))?;
            table.insert(name.clone(), loaded);
            let mut line = format!("- {name}（{}）：{}", api.base_url, api.about.trim());
            if let Some(allow) = &api.allow {
                let allow: Vec<String> = allow.iter().map(Rule::to_string).collect();
                line.push_str(&format!("只许 {}。", allow.join("、")));
            }
            if let Some(per_hour) = api.per_hour {
                line.push_str(&format!("所有群加起来一小时最多 {per_hour} 次。"));
            }
            lines.push(line);
        }
        Ok(Self {
            table,
            prompt: lines.join("\n"),
        })
    }

    /// Their lines in the system prompt; empty without any.
    pub fn prompt(&self) -> &str {
        &self.prompt
    }
}

impl Api {
    fn load(api: &config::Api) -> Result<Self> {
        let secret = api.secret()?;
        let mut headers = HeaderMap::new();
        for (name, value) in &api.headers {
            let mut value = HeaderValue::from_str(&value.replace("{secret}", &secret))
                .wrap_err("the secret doesn't go in a header")?;
            value.set_sensitive(true);
            headers.insert(HeaderName::from_bytes(name.as_bytes())?, value);
        }
        let query = api
            .query
            .iter()
            .map(|(name, value)| (name.clone(), value.replace("{secret}", &secret)))
            .collect();
        Ok(Self {
            base: Url::parse(&api.base_url)?,
            headers,
            query,
            allow: api.allow.clone(),
            per_hour: api.per_hour,
            sent: Mutex::default(),
        })
    }

    /// Where a call to `path` with `query` goes, and the path below the
    /// base it is checked by; None if it would leave the base, or names
    /// a segment in a way the API may read otherwise.
    fn url(&self, path: &str, query: Option<&str>) -> Option<(Url, String)> {
        let lower = path.to_ascii_lowercase();
        if ["%2f", "%5c", "%2e"]
            .iter()
            .any(|code| lower.contains(code))
        {
            return None;
        }
        let mut text = self.base.as_str().trim_end_matches('/').to_owned();
        text.push_str(path);
        if let Some(query) = query {
            text.push('?');
            text.push_str(query);
        }
        let mut url = Url::parse(&text).ok()?;
        if url.origin() != self.base.origin() {
            return None;
        }
        let below = match url
            .path()
            .strip_prefix(self.base.path().trim_end_matches('/'))?
        {
            "" => "/".to_owned(),
            below if below.starts_with('/') => below.to_owned(),
            _ => return None,
        };
        if !self.query.is_empty() {
            let kept: Vec<(String, String)> = url
                .query_pairs()
                .filter(|(name, _)| self.query.iter().all(|(own, _)| own != name))
                .map(|(name, value)| (name.into_owned(), value.into_owned()))
                .collect();
            url.query_pairs_mut()
                .clear()
                .extend_pairs(kept)
                .extend_pairs(&self.query);
        }
        Some((url, below))
    }

    fn allows(&self, method: &Method, below: &str) -> bool {
        self.allow
            .as_ref()
            .is_none_or(|allow| allow.iter().any(|rule| rule.allows(method.as_str(), below)))
    }

    /// Counts one more call at `now`, if the hour has room for it.
    fn take(&self, now: Instant) -> bool {
        let Some(per_hour) = self.per_hour else {
            return true;
        };
        let mut sent = self.sent.lock().unwrap_or_else(PoisonError::into_inner);
        while sent
            .front()
            .is_some_and(|&at| now.duration_since(at) >= HOUR)
        {
            sent.pop_front();
        }
        if sent.len() >= per_hour as usize {
            return false;
        }
        sent.push_back(now);
        true
    }
}

#[derive(Clone)]
struct Forward {
    conversation: ConversationId,
    apis: Arc<Apis>,
    client: reqwest::Client,
}

/// `/api/…` for the VM of `conversation`.
pub fn router(conversation: ConversationId, apis: Arc<Apis>) -> Router {
    // A redirect goes back to the program: followed here, it would take
    // the key's headers to wherever the API pointed.
    let client = reqwest::Client::builder()
        .connect_timeout(CONNECT)
        .redirect(Policy::none())
        .build()
        .expect("a client with a connect timeout builds");
    let forward = Forward {
        conversation,
        apis,
        client,
    };
    Router::new()
        .route("/api/{*rest}", any(call))
        .layer(DefaultBodyLimit::max(LARGEST))
        .with_state(forward)
}

async fn call(
    State(forward): State<Forward>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let conversation = forward.conversation;
    let rest = uri.path().strip_prefix("/api/").unwrap_or_default();
    let (name, path) = rest.find('/').map_or((rest, ""), |at| rest.split_at(at));
    let Some(api) = forward.apis.table.get(name) else {
        let names: Vec<&str> = forward.apis.table.keys().map(String::as_str).collect();
        let message = if names.is_empty() {
            "宿主没配带 key 的 API".to_owned()
        } else {
            format!("没有叫 {name} 的 API，有：{}", names.join("、"))
        };
        return refuse(StatusCode::NOT_FOUND, &message);
    };
    let Some((url, below)) = api.url(path, uri.query()) else {
        return refuse(StatusCode::BAD_REQUEST, &format!("{name} 下面没有这个路径"));
    };
    if !api.allows(&method, &below) {
        info!(%conversation, api = name, %method, path = %below, "refused an API call");
        return refuse(
            StatusCode::FORBIDDEN,
            &format!("{name} 不许 {method} {below}"),
        );
    }
    if !api.take(Instant::now()) {
        info!(%conversation, api = name, %method, path = %below, "an API's calls ran out for the hour");
        let per_hour = api.per_hour.unwrap_or_default();
        return refuse(
            StatusCode::TOO_MANY_REQUESTS,
            &format!("{name} 这一小时的 {per_hour} 次用完了"),
        );
    }
    let mut sent = headers;
    for dropped in &DROPPED {
        sent.remove(dropped);
    }
    for (field, value) in &api.headers {
        sent.insert(field, value.clone());
    }
    let mut sending = forward.client.request(method.clone(), url).headers(sent);
    if !body.is_empty() {
        sending = sending.body(body);
    }
    let answer = match timeout(IDLE, sending.send()).await {
        Ok(Ok(answer)) => answer,
        // Without the URL, which may carry the key.
        Ok(Err(error)) => {
            let error = error.without_url();
            info!(%conversation, api = name, %method, path = %below, %error, "an API call failed");
            return refuse(StatusCode::BAD_GATEWAY, &format!("{name} 连不上：{error}"));
        }
        Err(_) => {
            let quiet = format!("{name} {} 秒没回话", IDLE.as_secs());
            return refuse(StatusCode::GATEWAY_TIMEOUT, &quiet);
        }
    };
    let status = answer.status();
    info!(%conversation, api = name, %method, path = %below, status = status.as_u16(), "called an API for the VM");
    let mut response = Response::builder().status(status);
    for (field, value) in answer.headers() {
        if !UNANSWERED.contains(field) {
            response = response.header(field, value);
        }
    }
    response
        .body(Body::from_stream(chunks(answer, IDLE)))
        .unwrap_or_else(|_| refuse(StatusCode::BAD_GATEWAY, &format!("{name} 的回答转不了")))
}

#[cfg(test)]
mod tests;
