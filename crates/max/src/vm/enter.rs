//! `/connect/<n>` on max's service to the VMs: a guest's ssh into another
//! conversation's VM, along a link from A to B. A's ssh asks for an
//! upgrade at `/connect/9` (`maxx
//! connect`, the guest's ProxyCommand); max checks the link, boots B's VM
//! if it isn't running, and once the upgrade is done copies the bytes both
//! ways between the connection and B's sshd. A connection holds B's VM as
//! a call does, and ends when either end closes or as max stops; one that
//! is open as the link is removed runs on. See "Entering another
//! conversation's VM" in docs/design/vm.md.

use axum::Router;
use axum::body::Body;
use axum::extract::{Path, Request, State};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use hyper::upgrade::OnUpgrade;
use hyper_util::rt::TokioIo;
use max_core::ids::ConversationId;
use max_db::{PgPool, links};
use tokio::net::UnixStream;
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};
use tokio::task::JoinSet;
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};

use super::{Vm, Vms};
use crate::service::Calling;

#[derive(Clone)]
struct Enter {
    pool: PgPool,
    vms: Vms,
    joins: UnboundedSender<Join>,
}

/// The route, which gives `joins` each connection to join.
pub(super) fn router(pool: PgPool, vms: Vms, joins: UnboundedSender<Join>) -> Router {
    Router::new()
        .route("/connect/{to}", get(connect))
        .with_state(Enter { pool, vms, joins })
}

impl Enter {
    /// Whether Max in `from` may enter `to`'s VM.
    async fn linked(&self, from: ConversationId, to: ConversationId) -> sqlx::Result<bool> {
        let mut conn = self.pool.acquire().await?;
        links::linked(&mut conn, from, to).await
    }
}

/// The calling VM's connection, upgraded, joined to the sshd of `to`'s.
async fn connect(
    State(enter): State<Enter>,
    Calling(from): Calling,
    Path(to): Path<String>,
    mut request: Request,
) -> Response {
    let Some(to) = links::named(&to) else {
        return refuse(StatusCode::BAD_REQUEST, "which conversation: /connect/9");
    };
    if !upgrading(request.headers()) {
        let how = "it is an upgrade: Connection: upgrade, Upgrade: ssh";
        return refuse(StatusCode::BAD_REQUEST, how);
    }
    match enter.linked(from, to).await {
        Ok(true) => {}
        Ok(false) => {
            let why = format!("no link from c#{from} to c#{to}");
            return refuse(StatusCode::FORBIDDEN, &why);
        }
        Err(error) => {
            warn!(%from, %to, %error, "couldn't read a link");
            return refuse(StatusCode::SERVICE_UNAVAILABLE, "the links can't be read");
        }
    }
    let vm = match enter.vms.get(to).await {
        Ok(vm) => vm,
        Err(why) => return refuse(StatusCode::SERVICE_UNAVAILABLE, &why.to_string()),
    };
    let sshd = match vm.sshd().await {
        Ok(sshd) => sshd,
        Err(error) => {
            warn!(%from, %to, %error, "a guest's sshd didn't answer for another VM");
            return refuse(StatusCode::BAD_GATEWAY, "its sshd didn't answer");
        }
    };
    let join = Join {
        upgrade: hyper::upgrade::on(&mut request),
        sshd,
        vm,
    };
    if enter.joins.send(join).is_err() {
        return refuse(StatusCode::SERVICE_UNAVAILABLE, "Max is stopping");
    }
    info!(%from, %to, "a VM enters another's");
    Response::builder()
        .status(StatusCode::SWITCHING_PROTOCOLS)
        .header(header::CONNECTION, "upgrade")
        .header(header::UPGRADE, "ssh")
        .body(Body::empty())
        .expect("a response with its headers")
}

/// Whether the request asks for an upgrade to ssh.
fn upgrading(headers: &HeaderMap) -> bool {
    let said = |name, word: &str| {
        headers.get_all(name).iter().any(|value| {
            value.to_str().is_ok_and(|value| {
                value
                    .split(',')
                    .any(|part| part.trim().eq_ignore_ascii_case(word))
            })
        })
    };
    said(header::CONNECTION, "upgrade") && said(header::UPGRADE, "ssh")
}

fn refuse(status: StatusCode, why: &str) -> Response {
    let body = format!("{why}\n");
    (status, [(header::CONTENT_TYPE, "text/plain")], body).into_response()
}

/// A connection to join, once its upgrade is done: the VM it enters is
/// held until it ends.
pub(super) struct Join {
    upgrade: OnUpgrade,
    sshd: UnixStream,
    vm: Vm,
}

impl Join {
    async fn run(self) {
        let Self {
            upgrade,
            mut sshd,
            vm,
        } = self;
        if let Ok(upgraded) = upgrade.await {
            let mut guest = TokioIo::new(upgraded);
            let _ = tokio::io::copy_bidirectional(&mut guest, &mut sshd).await;
        }
        drop(vm);
    }
}

/// Joins the connections `joins` gives, each until it ends, all of them
/// until `stop`.
pub(super) async fn join(mut joins: UnboundedReceiver<Join>, stop: CancellationToken) {
    let mut running = JoinSet::new();
    loop {
        tokio::select! {
            join = joins.recv() => match join {
                Some(join) => {
                    running.spawn(join.run());
                }
                None => break,
            },
            Some(_) = running.join_next() => {}
            () = stop.cancelled() => break,
        }
    }
}
