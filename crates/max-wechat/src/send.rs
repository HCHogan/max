//! WeChat's sender: the only writer of `deliveries` for WeChat. What a
//! conversation says goes to wxdesk in the order it was committed, one
//! message at a time, as wxdesk says everything in one window: the text,
//! with its mentions first, then the picture or file. See "Outbound" in
//! docs/design/wechat.md.

use std::sync::Arc;
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use chrono::Utc;
use max_core::message::{Content, MediaKind, MediaRef, MentionTarget, Node, Sha256};
use max_db::ledger::{self, Sent as Delivered};
use max_db::platform::{self, ConversationKind};
use max_db::{PgConnection, PgPool};
use tokio::sync::mpsc::{self, UnboundedReceiver};
use tokio::task::spawn_blocking;
use tracing::{info, warn};
use wxdesk_proto::ToDriver;

use super::link::{Failed, Link};
use super::title;
use max::conversation::{Outgoing, Refused};
use max::media::prepare;
use max::media::store::Store;
use max::scope::Scope;

/// The largest file sent: it goes to wxdesk whole, in base64.
const LARGEST: u64 = 64 << 20;

struct Shared {
    link: Arc<Link>,
    pool: PgPool,
    store: Option<Arc<Store>>,
}

/// Until every conversation's sender handle is gone, then until what was
/// queued is sent or `drain` runs out.
pub async fn run(
    link: Arc<Link>,
    pool: PgPool,
    store: Option<Arc<Store>>,
    mut outbound: UnboundedReceiver<Outgoing>,
    drain: Duration,
) {
    let shared = Shared { link, pool, store };
    let (queue, rx) = mpsc::unbounded_channel();
    let mut workers = Scope::new();
    workers.spawn(move |_| worker(shared, rx));
    while let Some(outgoing) = outbound.recv().await {
        let _ = queue.send(outgoing);
    }
    drop(queue);
    workers.close(drain).await;
    info!("the WeChat sender is done");
}

async fn worker(shared: Shared, mut queue: UnboundedReceiver<Outgoing>) {
    while let Some(outgoing) = queue.recv().await {
        let id = outgoing.message.id;
        if let Err(error) = shared.deliver(outgoing).await {
            warn!(message = %id, %error, "couldn't send or record a message");
        }
    }
}

impl Shared {
    async fn deliver(&self, outgoing: Outgoing) -> sqlx::Result<()> {
        let place = &outgoing.place;
        let message = &outgoing.message;
        let result = match (title(&place.native_id), &message.content) {
            (None, _) => Err(Failed::Refused("not a WeChat chat".to_owned())),
            (Some(chat), Content::Message { nodes, .. }) => {
                self.message(chat, place.kind, nodes).await?
            }
            (Some(_), _) => Err(Failed::Refused(
                "WeChat lets Max neither recall nor edit a message".to_owned(),
            )),
        };
        if let Err(Failed::Refused(error) | Failed::Unknown(error)) = &result {
            warn!(message = %message.id, error, "WeChat's driver didn't send a message");
        }
        // WeChat shows no id for what Max says: the row's own stands in.
        let native_id = format!("out-{}", message.id);
        let delivered = match &result {
            Ok(()) => Delivered::Delivered {
                native_id: &native_id,
                quote_id: None,
            },
            Err(Failed::Refused(error)) => Delivered::Failed { error },
            Err(Failed::Unknown(_)) => Delivered::Unknown,
        };
        let mut conn = self.pool.acquire().await?;
        ledger::record_delivery(
            &mut conn,
            message.id,
            place.endpoint,
            &delivered,
            Utc::now(),
        )
        .await?;
        if let Some(receipt) = outgoing.receipt {
            let _ = receipt.send(result.map(|()| message.id).map_err(told));
        }
        Ok(())
    }

    /// A row Max says: its text, then what it attaches.
    async fn message(
        &self,
        chat: &str,
        kind: ConversationKind,
        nodes: &[Node],
    ) -> sqlx::Result<Result<(), Failed>> {
        // No connection is held while waiting for wxdesk.
        let mut conn = self.pool.acquire().await?;
        let Lowered {
            text,
            mentions,
            attached,
        } = lower(&mut conn, kind, nodes).await?;
        drop(conn);
        let text = text.trim().to_owned();
        if text.is_empty() && mentions.is_empty() && attached.is_none() {
            return Ok(Err(Failed::Refused("nothing to send".to_owned())));
        }
        if !text.is_empty() || !mentions.is_empty() {
            let said = self.link.call(|id| ToDriver::SendText {
                id,
                chat: chat.to_owned(),
                text,
                mentions,
            });
            if let Err(failed) = said.await {
                return Ok(Err(failed));
            }
        }
        Ok(match attached {
            Some(attached) => self.attach(chat, attached).await,
            None => Ok(()),
        })
    }

    /// A picture as a picture, as PNG; anything else as a file.
    async fn attach(&self, chat: &str, attached: Attached) -> Result<(), Failed> {
        let refused = |why: String| Failed::Refused(why);
        let store = self
            .store
            .as_ref()
            .ok_or_else(|| refused("no content store".to_owned()))?;
        let path = store.path(&attached.sha256);
        let size = tokio::fs::metadata(&path)
            .await
            .map_err(|e| refused(e.to_string()))?
            .len();
        if size > LARGEST {
            return Err(refused(format!(
                "{size} bytes, more than the {LARGEST} Max sends on WeChat"
            )));
        }
        let bytes = tokio::fs::read(&path)
            .await
            .map_err(|e| refused(e.to_string()))?;
        let chat = chat.to_owned();
        match attached.kind {
            MediaKind::Image | MediaKind::Sticker => {
                let png = if bytes.starts_with(b"\x89PNG") {
                    bytes
                } else {
                    let png = spawn_blocking(move || prepare::png(&bytes)).await;
                    png.map_err(|e| refused(e.to_string()))?
                        .map_err(|e| refused(format!("a picture that doesn't decode: {e}")))?
                };
                let png = STANDARD.encode(png);
                self.link
                    .call(|id| ToDriver::SendImage { id, chat, png })
                    .await
            }
            _ => {
                let data = STANDARD.encode(bytes);
                let name = attached.name.unwrap_or_else(|| "file".to_owned());
                self.link
                    .call(|id| ToDriver::SendFile {
                        id,
                        chat,
                        name,
                        data,
                    })
                    .await
            }
        }
    }
}

/// As whoever waits on it is told.
fn told(failed: Failed) -> Refused {
    Refused::Unsent(match failed {
        Failed::Refused(text) => text,
        Failed::Unknown(text) => {
            format!("WeChat's driver never answered, so it isn't known whether it was sent: {text}")
        }
    })
}

/// A row of Max's for wxdesk.
#[derive(Default)]
struct Lowered {
    text: String,
    /// Who it mentions, by the names the client shows them by: wxdesk
    /// mentions them before the text.
    mentions: Vec<String>,
    /// The picture or file it sends, if any: one a message.
    attached: Option<Attached>,
}

struct Attached {
    sha256: Sha256,
    kind: MediaKind,
    name: Option<String>,
}

async fn lower(
    conn: &mut PgConnection,
    kind: ConversationKind,
    nodes: &[Node],
) -> sqlx::Result<Lowered> {
    let mut lowered = Lowered::default();
    for node in nodes {
        match node {
            Node::Text { text } => lowered.text.push_str(text),
            Node::Mention {
                target: MentionTarget::Identity(identity),
                display,
            } => match platform::native_user_id(conn, *identity).await? {
                Some(name) if kind == ConversationKind::Group => lowered.mentions.push(name),
                _ => lowered.text.push_str(&format!("@{display}")),
            },
            Node::Mention { display, .. } => lowered.text.push_str(&format!("@{display}")),
            Node::Media {
                media: Some(MediaRef::Blob(sha256)),
                meta,
            } if lowered.attached.is_none() => {
                lowered.attached = Some(Attached {
                    sha256: sha256.clone(),
                    kind: meta.kind,
                    name: meta.name.clone(),
                });
            }
            Node::Emote(_)
            | Node::Media { .. }
            | Node::Card(_)
            | Node::Forward(_)
            | Node::Unsupported(_) => {}
        }
    }
    Ok(lowered)
}
