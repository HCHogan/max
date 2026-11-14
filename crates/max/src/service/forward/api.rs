//! The HTTP APIs the VMs call through the host: a program in the VM sends
//! `/api/<name>/…` with no key, and it goes on to the API's base URL with
//! the key the host keeps, which never enters the VM. Only the calls the
//! configuration allows go, at most so many an hour; the answer comes back
//! as it is, a redirect too. Each VM has a forwarder of its own (see
//! `crate::forwarder`), and an API's hour is all the chats' together: the
//! forwarders count its calls in one file. See "Host-keyed APIs" in
//! docs/rust-rewrite.md.

use std::collections::{BTreeMap, VecDeque};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

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
use rustix::fs::{FlockOperation, flock};
use tokio::time::timeout;
use tracing::{info, warn};

use super::{CONNECT, LARGEST, chunks, refuse};
use crate::config::{self, Rule};
use max_core::limits::HOUR;

/// The response's headers and every piece after them must arrive within
/// this; a call as a whole has no limit.
const IDLE: Duration = Duration::from_secs(60);

/// A program's headers that don't go on: its connection's, `Expect`
/// among them, which the host's own server answers (curl sends one with a
/// large body); and its own key.
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
    /// Where each API's calls are counted with those of every other
    /// process that counts there, a file an API; without it, here alone.
    counted: Option<PathBuf>,
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
        for (name, api) in configured {
            let loaded = Api::load(api).wrap_err_with(|| format!("in api.{name}"))?;
            table.insert(name.clone(), loaded);
        }
        Ok(Self {
            table,
            counted: None,
        })
    }

    /// The same, their calls counted in `dir` with every other VM's
    /// forwarder's.
    #[must_use]
    pub fn counted_in(mut self, dir: PathBuf) -> Self {
        self.counted = Some(dir);
        self
    }

    /// Counts one more call of `api`, named `name`, if its hour has room.
    fn take(&self, name: &str, api: &Api) -> bool {
        let Some(per_hour) = api.per_hour else {
            return true;
        };
        if let Some(dir) = &self.counted {
            match counted(&dir.join(name), per_hour, SystemTime::now()) {
                Ok(room) => return room,
                // Counted here alone, then: an API isn't lost for a file.
                Err(error) => {
                    warn!(api = name, %error, "an API's calls can't be counted with the other VMs'");
                }
            }
        }
        api.take(Instant::now())
    }
}

/// The APIs' lines in the system prompt, which take no secret to write;
/// empty without any.
pub fn prompt(configured: &BTreeMap<String, config::Api>) -> String {
    let mut lines = Vec::new();
    for (name, api) in configured {
        let mut line = format!("- {name} ({}): {}", api.base_url, api.about.trim());
        if let Some(allow) = &api.allow {
            let allow: Vec<String> = allow.iter().map(Rule::to_string).collect();
            line.push_str(&format!(" Only {} allowed.", allow.join(", ")));
        }
        if let Some(per_hour) = api.per_hour {
            line.push_str(&format!(
                " At most {per_hour} calls an hour, all chats together."
            ));
        }
        lines.push(line);
    }
    lines.join("\n")
}

/// Counts one more call at `now` in `file`, if the hour has room: a line
/// a call of the last hour, the second it went. The file is locked while
/// it is read and written, so that the forwarders count as one; a few
/// file operations, done where they are asked for.
fn counted(file: &Path, per_hour: u32, now: SystemTime) -> io::Result<bool> {
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(file)?;
    // Until the file is closed.
    flock(&file, FlockOperation::LockExclusive)?;
    let mut written = String::new();
    file.read_to_string(&mut written)?;
    let now = now
        .duration_since(UNIX_EPOCH)
        .map_or(0, |now| now.as_secs());
    let mut sent: Vec<u64> = written
        .lines()
        .filter_map(|at| at.parse().ok())
        .filter(|&at| now.saturating_sub(at) < HOUR.as_secs())
        .collect();
    let room = sent.len() < per_hour as usize;
    if room {
        sent.push(now);
    }
    let written: String = sent.iter().map(|at| format!("{at}\n")).collect();
    file.set_len(0)?;
    file.seek(SeekFrom::Start(0))?;
    file.write_all(written.as_bytes())?;
    Ok(room)
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
            "the host has no keyed APIs configured".to_owned()
        } else {
            format!(
                "there is no API named {name}; there are: {}",
                names.join(", ")
            )
        };
        return refuse(StatusCode::NOT_FOUND, &message);
    };
    let Some((url, below)) = api.url(path, uri.query()) else {
        return refuse(StatusCode::BAD_REQUEST, &format!("{name} has no such path"));
    };
    if !api.allows(&method, &below) {
        info!(%conversation, api = name, %method, path = %below, "refused an API call");
        return refuse(
            StatusCode::FORBIDDEN,
            &format!("{name} doesn't allow {method} {below}"),
        );
    }
    if !forward.apis.take(name, api) {
        info!(%conversation, api = name, %method, path = %below, "an API's calls ran out for the hour");
        let per_hour = api.per_hour.unwrap_or_default();
        return refuse(
            StatusCode::TOO_MANY_REQUESTS,
            &format!("{name}'s {per_hour} calls for this hour are used up"),
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
            return refuse(
                StatusCode::BAD_GATEWAY,
                &format!("can't reach {name}: {error}"),
            );
        }
        Err(_) => {
            let quiet = format!("{name} said nothing for {} seconds", IDLE.as_secs());
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
        .unwrap_or_else(|_| {
            refuse(
                StatusCode::BAD_GATEWAY,
                &format!("{name}'s answer couldn't be passed on"),
            )
        })
}

#[cfg(test)]
mod tests;
