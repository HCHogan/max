//! `/events` on max's service to each group's VM: the group's timeline as it is
//! committed, a JSON line a row, for the programs Max keeps in the VM,
//! which read it with `maxx events`. `?after=<id>` first sends the rows
//! after that one, the latest [`EVENTS_CAUGHT_UP`] of them, from the database. A
//! line with nothing on it is the heartbeat. With `full=1` a line has the
//! row as data too, as the `rows` tool gives it (service/rows.rs). Which
//! group it is is the VM's own socket's to say, as for the programs'
//! calls. See "Resident programs" in docs/rust-rewrite.md.

use std::borrow::Borrow;
use std::collections::{BTreeMap, VecDeque};
use std::io;
use std::time::Duration;

use axum::Router;
use axum::body::{Body, Bytes};
use axum::extract::State;
use axum::http::{StatusCode, Uri, header};
use axum::response::Response;
use axum::routing::get;
use chrono::SecondsFormat;
use futures_util::Stream;
use max_core::ids::{ConversationId, MessageId};
use max_core::message::{Content, Message};
use max_core::render::Render;
use max_db::ledger;
use serde::Serialize;
use serde_json::{Value, json};
use tokio::sync::broadcast::error::RecvError;
use tokio::sync::mpsc::UnboundedSender;
use tokio::sync::oneshot;
use tokio::time::{sleep, timeout};
use tokio_util::sync::CancellationToken;
use tracing::warn;

use crate::conversation::Signal;
use crate::conversation::{Subscription, ingest, project};
use crate::service::rows;
use max_core::limits::EVENTS_CAUGHT_UP;

/// A stream with no row for this long sends the heartbeat, so that the
/// program knows it is still there.
const HEARTBEAT: Duration = Duration::from_secs(30);
/// How long the group's conversation has to answer.
const WAIT: Duration = Duration::from_secs(10);
/// The rows read from the database at once.
const PAGE: usize = 100;
/// The response's header with the last row before the stream: where a
/// program that has had no row yet starts again from.
const HEAD: &str = "max-head";

#[derive(Clone)]
struct Events {
    conversation: ConversationId,
    signals: UnboundedSender<Signal>,
    stop: CancellationToken,
    heartbeat: Duration,
}

/// A row as the program reads it.
#[derive(Serialize)]
struct Line<'a> {
    id: i64,
    /// Local time, in RFC 3339.
    at: String,
    sender: &'a str,
    /// The sender's person, as `[mention#…]` writes them.
    #[serde(skip_serializing_if = "Option::is_none")]
    person: Option<i64>,
    /// `max` or `program`, for what Max or a program of its said.
    #[serde(skip_serializing_if = "Option::is_none")]
    by: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reply_to: Option<i64>,
    /// As `history` shows it.
    text: String,
    /// The row as data, and whose its accounts are, for a stream that
    /// asked for them: as `rows` gives both.
    #[serde(skip_serializing_if = "Option::is_none")]
    row: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    people: Option<BTreeMap<String, i64>>,
}

/// What a stream's query asks for.
#[derive(Debug, Default, PartialEq, Eq)]
struct Asked {
    /// The rows after this one first; from now without it.
    after: Option<i64>,
    /// Each row as data too.
    full: bool,
}

/// `/events` for the VM of `conversation`; its streams end at `stop`.
pub fn router(
    conversation: ConversationId,
    signals: UnboundedSender<Signal>,
    stop: CancellationToken,
) -> Router {
    beating(conversation, signals, stop, HEARTBEAT)
}

fn beating(
    conversation: ConversationId,
    signals: UnboundedSender<Signal>,
    stop: CancellationToken,
    heartbeat: Duration,
) -> Router {
    Router::new()
        .route("/events", get(events))
        .with_state(Events {
            conversation,
            signals,
            stop,
            heartbeat,
        })
}

async fn events(State(events): State<Events>, uri: Uri) -> Response {
    let Some(Asked { after, full }) = asked(uri.query()) else {
        return refuse(
            StatusCode::BAD_REQUEST,
            "only after=<number> and full=1 are taken",
        );
    };
    let conversation = events.conversation;
    let (reply, subscribed) = oneshot::channel();
    if events
        .signals
        .send(Signal::Subscribe {
            conversation,
            reply,
        })
        .is_err()
    {
        return refuse(StatusCode::SERVICE_UNAVAILABLE, "Max is stopping");
    }
    let Ok(Ok(subscription)) = timeout(WAIT, subscribed).await else {
        return refuse(
            StatusCode::SERVICE_UNAVAILABLE,
            "this chat's conversation didn't answer",
        );
    };
    let head = subscription.head;
    let backlog = match after {
        Some(after) if after < head.0 => match backlog(&subscription, after).await {
            Ok(backlog) => backlog,
            Err(error) => {
                warn!(%conversation, %error, "couldn't read the rows a program missed");
                return refuse(StatusCode::INTERNAL_SERVER_ERROR, "can't read the records");
            }
        },
        _ => VecDeque::new(),
    };
    let following = Following {
        last: after.map_or(head, MessageId),
        subscription,
        backlog,
        full,
        heartbeat: events.heartbeat,
        stop: events.stop,
    };
    Response::builder()
        .header(header::CONTENT_TYPE, "application/x-ndjson")
        .header(HEAD, head.0)
        .body(Body::from_stream(following.lines()))
        .unwrap_or_else(|_| {
            refuse(
                StatusCode::INTERNAL_SERVER_ERROR,
                "the answer couldn't be made",
            )
        })
}

/// What `?after=<id>&full=1` asks for, either of them or neither; None
/// for anything else in a query.
fn asked(query: Option<&str>) -> Option<Asked> {
    let mut asked = Asked::default();
    for pair in query.unwrap_or_default().split('&') {
        match pair.split_once('=') {
            _ if pair.is_empty() => {}
            Some(("after", id)) => asked.after = Some(id.parse().ok()?),
            Some(("full", "1")) => asked.full = true,
            _ => return None,
        }
    }
    Some(asked)
}

/// The rows after `after` up to the head, the latest [`EVENTS_CAUGHT_UP`].
async fn backlog(subscription: &Subscription, after: i64) -> sqlx::Result<VecDeque<MessageId>> {
    let mut conn = subscription.services.pool.acquire().await?;
    let between = (
        Some(MessageId(after + 1)),
        Some(MessageId(subscription.head.0 + 1)),
    );
    let conversation = subscription.place.conversation;
    let mut ids = ledger::stretch(
        &mut conn,
        conversation,
        between,
        None,
        true,
        EVENTS_CAUGHT_UP,
    )
    .await?;
    ids.reverse();
    Ok(ids.into())
}

/// A program's stream: the backlog, then the rows as they come.
struct Following {
    subscription: Subscription,
    backlog: VecDeque<MessageId>,
    /// The last row sent; or where the stream starts.
    last: MessageId,
    /// Whether a line has its row as data too.
    full: bool,
    heartbeat: Duration,
    stop: CancellationToken,
}

impl Following {
    fn lines(self) -> impl Stream<Item = io::Result<Bytes>> {
        futures_util::stream::unfold(Some(self), |following| async move {
            let mut following = following?;
            match following.next().await {
                Ok(Some(lines)) => Some((Ok(lines), Some(following))),
                Ok(None) => None,
                Err(error) => {
                    let conversation = following.subscription.place.conversation;
                    warn!(%conversation, %error, "a program's stream of the timeline broke");
                    Some((Err(io::Error::other(error)), None))
                }
            }
        })
    }

    /// A page of the backlog, a row just committed, or the heartbeat;
    /// None once the stream ends.
    async fn next(&mut self) -> sqlx::Result<Option<Bytes>> {
        if !self.backlog.is_empty() {
            let page: Vec<MessageId> = self.backlog.drain(..self.backlog.len().min(PAGE)).collect();
            let mut conn = self.subscription.services.pool.acquire().await?;
            let conversation = self.subscription.place.conversation;
            let rows = ledger::picked(&mut conn, conversation, &page).await?;
            drop(conn);
            let messages: Vec<Message> = rows.into_iter().map(|row| row.message).collect();
            return self.written(&messages).await.map(Some);
        }
        loop {
            let received = tokio::select! {
                () = self.stop.cancelled() => return Ok(None),
                received = self.subscription.rows.recv() => received,
                () = sleep(self.heartbeat) => return Ok(Some(Bytes::from_static(b"\n"))),
            };
            match received {
                Ok(message) if message.id <= self.last => {}
                Ok(message) => return self.written(std::slice::from_ref(&message)).await.map(Some),
                // Too far behind, the program asks again from its last
                // row, which the database has; or the actor stopped.
                Err(RecvError::Lagged(_) | RecvError::Closed) => return Ok(None),
            }
        }
    }

    /// `messages`, a line each.
    async fn written<M: Borrow<Message>>(&mut self, messages: &[M]) -> sqlx::Result<Bytes> {
        let messages: Vec<&Message> = messages.iter().map(Borrow::borrow).collect();
        let place = &self.subscription.place;
        let mut conn = self.subscription.services.pool.acquire().await?;
        let people = project::people(&mut conn, messages.iter().copied(), place).await?;
        // As the ledger has them now: a row just committed has no more
        // to it than its message, and one caught up on may.
        let mut stored = BTreeMap::new();
        if self.full {
            let ids: Vec<MessageId> = messages.iter().map(|message| message.id).collect();
            for row in ledger::picked(&mut conn, place.conversation, &ids).await? {
                stored.insert(row.message.id, rows::data(&row));
            }
        }
        drop(conn);
        let render = Render {
            people: &people,
            offset: self.subscription.services.offset,
        };
        let mut out = Vec::new();
        for message in messages {
            let by = if ingest::by(message) == ingest::By::Program {
                Some("program")
            } else if message.sender.identity == place.me.identity {
                Some("max")
            } else {
                None
            };
            let reply_to = match &message.content {
                Content::Message { reply_to, .. } => reply_to.map(|id| id.0),
                _ => None,
            };
            let line = Line {
                id: message.id.0,
                at: message
                    .at
                    .with_timezone(&render.offset)
                    .to_rfc3339_opts(SecondsFormat::Secs, true),
                sender: &message.sender.name,
                person: people.get(&message.sender.identity).map(|person| person.0),
                by,
                reply_to,
                text: render.body(message),
                people: self.full.then(|| rows::known(message, &people)),
                row: stored.remove(&message.id),
            };
            serde_json::to_writer(&mut out, &line).expect("a line is JSON");
            out.push(b'\n');
            self.last = message.id;
        }
        Ok(Bytes::from(out))
    }
}

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
