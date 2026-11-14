//! A VM's forwarder, `max forward`: a process of its own for each VM,
//! which its unit starts and stops with the VM's (nix/module.nix), so
//! that what it carries outlives a restart of max as the VM does. It is
//! where everything in the guest reaches the host: it listens where
//! cloud-hypervisor connects when the guest connects to the host's port,
//! `notify.vsock_7777` in the VM's directory.
//!
//! What needs none of max it does itself: the models' calls, `/llm`, and
//! the APIs the host keeps the keys of, `/api` (service/forward.rs and
//! forward/api.rs). An agent's model call, or a `git push` through
//! `/api`, isn't cut when max is deployed. Everything else it passes on
//! to max, which listens at `max.sock` beside it: the tools, the
//! timeline's rows, the units' count. While max is away it says so, 503
//! with `max-away`, with nothing of the request passed on, and the
//! guest's client asks again.
//!
//! Which configuration it reads is a link in the VM's directory,
//! `forward.config`, which max makes when it boots the VM and makes
//! again each time it attaches to it. Each time, the forwarder reads
//! what the link names, and the keys that names: a deploy's new models
//! and keys reach a forwarder that runs when the new max is back,
//! without a restart of its own. A configuration this build can't read,
//! as a newer one may be, is left, and it goes on with the one it has.
//! See "A VM's forwarder" in docs/rust-rewrite.md.

use std::os::unix::fs::MetadataExt;
use std::os::unix::net::UnixListener as StdListener;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use axum::Router;
use axum::body::Body;
use axum::extract::Request;
use axum::http::header::{self, HeaderName};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use color_eyre::eyre::{Result, WrapErr, eyre};
use max_core::ids::ConversationId;
use serde_json::json;
use sqlx::PgPool;
use tokio::net::UnixListener;
use tokio::time::sleep;
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};

use crate::config::Forwarded;
use crate::llm;
use crate::scope::Scope;
use crate::service::{self, api};

/// Where the guest's calls arrive: the hybrid vsock's port 7777, as
/// cloud-hypervisor names its socket.
pub const SOCKET: &str = "notify.vsock_7777";
/// Where max listens for what a forwarder passes on.
pub const MAX: &str = "max.sock";
/// The link to the configuration a VM's forwarder reads.
pub const CONFIG: &str = "forward.config";

/// How often the link is looked at.
const LOOK: Duration = Duration::from_secs(2);
/// The largest request passed on to max: a tool's arguments.
const LARGEST: usize = 16 << 20;
/// How long the calls in flight have once it is told to stop. Not long:
/// it is stopped with its VM, whose unit waits for it, and whatever in
/// the guest was calling is about to end with the guest.
const GRACE: Duration = Duration::from_secs(1);

/// A request's headers that are its connection's, and don't go on; the
/// length is written again from what is sent.
const HOP: [HeaderName; 7] = [
    header::HOST,
    header::CONNECTION,
    header::TE,
    header::TRAILER,
    header::TRANSFER_ENCODING,
    header::UPGRADE,
    header::CONTENT_LENGTH,
];
/// An answer's that don't come back.
const UNANSWERED: [HeaderName; 3] = [header::CONNECTION, header::TRAILER, header::UPGRADE];

/// The configuration max named a forwarder, and the naming of it: max
/// makes the link again each time, so one that names the same file is
/// still another, and the file's keys are read again.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Named {
    pub path: PathBuf,
    /// The link itself: its inode, and when it was made.
    link: (u64, i64, i64),
}

impl Named {
    /// What `dir`'s link names now.
    fn now(dir: &Path) -> std::io::Result<Self> {
        let link = dir.join(CONFIG);
        let made = std::fs::symlink_metadata(&link)?;
        Ok(Self {
            path: std::fs::read_link(&link)?,
            link: (made.ino(), made.mtime(), made.mtime_nsec()),
        })
    }
}

/// What a forwarder reads of the configuration `dir`'s link names, and
/// the naming it was read at.
pub fn configured(dir: &Path) -> Result<(Named, Forwarded)> {
    let named = Named::now(dir)
        .wrap_err_with(|| format!("reading the link {}", dir.join(CONFIG).display()))?;
    let config = Forwarded::load(&named.path)?;
    Ok((named, config))
}

/// Makes `dir`'s link name the configuration at `config`, all at once: a
/// forwarder that looks sees the old one or the new.
pub async fn configure(dir: &Path, config: &Path) -> std::io::Result<()> {
    let new = dir.join(format!("{CONFIG}.new"));
    let _ = tokio::fs::remove_file(&new).await;
    tokio::fs::symlink(config, &new).await?;
    tokio::fs::rename(&new, dir.join(CONFIG)).await
}

/// Serves the VM whose directory is `dir`, with the configuration max
/// `named` it, until `stop`.
pub async fn run(
    dir: &Path,
    named: Named,
    config: Forwarded,
    stop: CancellationToken,
) -> Result<()> {
    let conversation = dir
        .file_name()
        .and_then(|name| name.to_str()?.parse().ok())
        .map(ConversationId)
        .ok_or_else(|| eyre!("{} isn't a VM's directory", dir.display()))?;
    let socket = dir.join(SOCKET);
    // One that an earlier forwarder left, which nothing listens on.
    let _ = std::fs::remove_file(&socket);
    let listener = StdListener::bind(&socket)
        .wrap_err_with(|| format!("listening at {}", socket.display()))?;
    listener.set_nonblocking(true)?;
    let max = Max::at(&dir.join(MAX))?;
    // Every API's calls are counted beside the VMs' directories, with
    // the other VMs' forwarders'.
    let counted = dir.parent().unwrap_or(dir).join("api");

    let mut tasks = Scope::new();
    let mut serving = Serving {
        conversation,
        listener,
        max,
        counted,
        current: CancellationToken::new(),
    };
    serving.serve(&config, &mut tasks)?;
    info!(%conversation, config = %named.path.display(), commit = crate::COMMIT, "forwarding for a VM");
    let (mut read, mut refused) = (named, None);
    loop {
        tokio::select! {
            () = stop.cancelled() => break,
            () = sleep(LOOK) => {}
        }
        // Gone for a moment, or for good: it goes on with what it has.
        // A look is two calls on a link, done where it is asked for.
        let Ok(now) = Named::now(dir) else {
            continue;
        };
        if now == read || refused.as_ref() == Some(&now) {
            continue;
        }
        let loaded =
            Forwarded::load(&now.path).and_then(|config| serving.serve(&config, &mut tasks));
        match loaded {
            Ok(()) => {
                info!(%conversation, config = %now.path.display(), "a VM's forwarder reads the configuration max named it anew");
                read = now;
                refused = None;
            }
            Err(error) => {
                warn!(%conversation, config = %now.path.display(), error = format!("{error:#}"), "a VM's forwarder can't read the configuration max named it, and keeps the one it has");
                refused = Some(now);
            }
        }
    }
    tasks.close(GRACE).await;
    Ok(())
}

/// What is served for a VM, and with which configuration just now.
struct Serving {
    conversation: ConversationId,
    listener: StdListener,
    max: Max,
    counted: PathBuf,
    /// Ends the server that reads the configuration before the newest.
    current: CancellationToken,
}

impl Serving {
    /// Serves with `config` from here on. The server before it takes no
    /// more connections, and ends once those it has are done: a call in
    /// flight goes on as it was made.
    fn serve(&mut self, config: &Forwarded, tasks: &mut Scope) -> Result<()> {
        let app = self.app(config, tasks)?;
        let listener = UnixListener::from_std(self.listener.try_clone()?)?;
        let ended = CancellationToken::new();
        let (replaced, conversation) = (ended.clone(), self.conversation);
        tasks.spawn(move |stop| async move {
            let done = async move {
                tokio::select! {
                    () = stop.cancelled() => {}
                    () = replaced.cancelled() => {}
                }
            };
            let served = axum::serve(listener, app).with_graceful_shutdown(done);
            if let Err(error) = served.await {
                warn!(%conversation, %error, "a VM's forwarder stopped serving");
            }
        });
        std::mem::replace(&mut self.current, ended).cancel();
        Ok(())
    }

    /// `/llm` and `/api` with `config`'s models, APIs and keys, which are
    /// read now; and the rest, passed on.
    fn app(&self, config: &Forwarded, tasks: &mut Scope) -> Result<Router> {
        let conversation = self.conversation;
        let agents = match llm::Models::new(&config.llm)?.job().transpose()? {
            Some(upstreams) => {
                // Not waited for: a call's usage is recorded when the
                // call ends, whatever the database is doing now.
                let pool = PgPool::connect_lazy(&config.database.url)?;
                Some(service::Models::start(upstreams, pool, tasks))
            }
            None => None,
        };
        let apis = api::Apis::load(&config.api)?.counted_in(self.counted.clone());
        let max = self.max.clone();
        Ok(service::agents(conversation, agents)
            .merge(api::router(conversation, Arc::new(apis)))
            .fallback(move |request: Request| {
                let max = max.clone();
                async move { max.pass(request).await }
            }))
    }
}

/// max, as a forwarder reaches it: its socket beside the forwarder's.
#[derive(Clone)]
pub struct Max {
    client: reqwest::Client,
}

impl Max {
    /// max at `socket`. Each request is a connection of its own: one
    /// kept from before max restarted would fail a call that max never
    /// saw, with no way to tell.
    pub fn at(socket: &Path) -> Result<Self> {
        let client = reqwest::Client::builder()
            .unix_socket(socket)
            .pool_max_idle_per_host(0)
            .no_proxy()
            .build()?;
        Ok(Self { client })
    }

    /// Passes `request` on to max, and its answer back as it comes: a
    /// stream of rows as a stream. Dropped, as when the guest closes its
    /// connection, it closes max's, which cancels the call.
    pub async fn pass(&self, request: Request) -> Response {
        let (parts, body) = request.into_parts();
        let Ok(body) = axum::body::to_bytes(body, LARGEST).await else {
            let large = format!("a request to max is at most {} MiB", LARGEST >> 20);
            return (StatusCode::PAYLOAD_TOO_LARGE, large).into_response();
        };
        let whole = parts
            .uri
            .path_and_query()
            .map_or("/", |whole| whole.as_str());
        let mut headers = parts.headers;
        for hop in &HOP {
            headers.remove(hop);
        }
        let sending = self
            .client
            .request(parts.method, format!("http://max{whole}"))
            .headers(headers)
            .body(body);
        let answer = match sending.send().await {
            Ok(answer) => answer,
            // Nothing listens: max is away, and has seen none of it.
            Err(error) if error.is_connect() => return away(),
            Err(_) => return closed(),
        };
        let status = answer.status();
        let mut answered = HeaderMap::new();
        for (name, value) in answer.headers() {
            if !UNANSWERED.contains(name) {
                answered.append(name, value.clone());
            }
        }
        let mut response = Response::new(Body::from_stream(answer.bytes_stream()));
        *response.status_mut() = status;
        *response.headers_mut() = answered;
        response
    }
}

/// As max says itself of a call that comes as it stops, and the guest
/// while nothing listens on the host (nix/guest.nix): the caller asks
/// again.
fn away() -> Response {
    (StatusCode::SERVICE_UNAVAILABLE, [("max-away", "1")]).into_response()
}

/// max went with the request in its hands: a call's outcome, as max
/// gives one that it stopped in the middle of (service/http.rs).
fn closed() -> Response {
    let outcome = json!({
        "ok": false,
        "error": {
            "code": "closed",
            "message": "Max stopped before it was done; what acts in the chat may have taken effect: look at the records before trying again",
        },
    });
    let json = [(header::CONTENT_TYPE, "application/json")];
    (StatusCode::BAD_GATEWAY, json, outcome.to_string()).into_response()
}

#[cfg(test)]
mod tests;
