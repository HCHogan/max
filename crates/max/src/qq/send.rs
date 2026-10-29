//! QQ's sender: the only writer of `deliveries` for QQ. What a
//! conversation says goes out in the order it was committed, one chat at a
//! time and chats side by side; see "出站" under "QQ 官方机器人".
//!
//! Every message goes out proactively, never as a passive reply: a group
//! Max is in allows that (机器人主动发言). It keeps within QQ's rates: it
//! waits, it isn't dropped. It goes as Markdown, and once more as plain
//! text if that fails. A picture is uploaded to the chat first, unless it
//! was lately, and goes with plain text under it, if any.

use std::collections::{HashMap, VecDeque};
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::Utc;
use max_core::ids::MessageId;
use max_core::message::{Content, MediaRef, MentionTarget, Node, Platform};
use max_db::ledger::{self, Sent as Delivered};
use max_db::platform::{self, ConversationKind};
use max_db::{PgConnection, PgPool};
use qqbot::api::Uploaded;
use qqbot::message::{Body, Outgoing as Message, Sent};
use qqbot::{Chat, api};
use tokio::sync::mpsc::{self, UnboundedReceiver};
use tokio::time::{Instant, sleep_until};
use tracing::{info, warn};

use crate::conversation::Outgoing;
use crate::media::store::Store;
use crate::scope::Scope;

/// QQ's answer, some time later.
pub type Answer<'a, T> = Pin<Box<dyn Future<Output = Result<T, api::Error>> + Send + 'a>>;

/// Sends messages and uploads pictures. QQ's client in service; a
/// recorder in tests.
pub trait Api: Send + Sync + 'static {
    fn send<'a>(&'a self, chat: Chat<'a>, message: &'a Message) -> Answer<'a, Sent>;
    fn upload<'a>(&'a self, chat: Chat<'a>, picture: &'a [u8]) -> Answer<'a, Uploaded>;
}

impl Api for qqbot::Client {
    fn send<'a>(&'a self, chat: Chat<'a>, message: &'a Message) -> Answer<'a, Sent> {
        Box::pin(qqbot::Client::send(self, chat, message))
    }

    fn upload<'a>(&'a self, chat: Chat<'a>, picture: &'a [u8]) -> Answer<'a, Uploaded> {
        Box::pin(qqbot::Client::upload(self, chat, picture))
    }
}

const MINUTE: Duration = Duration::from_secs(60);
/// Proactive messages a minute, for the whole bot and for one chat.
const BOT_RATE: usize = 60;
const CHAT_RATE: usize = 20;
/// How long before QQ forgets an upload it is uploaded again.
const EARLY: Duration = Duration::from_secs(3600);

struct Shared {
    api: Arc<dyn Api>,
    pool: PgPool,
    /// Where the pictures Max sends are, if anywhere.
    store: Option<Arc<Store>>,
    /// When proactive messages went out, per chat and (None) for the bot.
    sent: Mutex<HashMap<Option<String>, VecDeque<Instant>>>,
    uploads: Mutex<Uploads>,
}

/// Pictures uploaded, by chat and SHA-256: the `file_info` and until when
/// it is used, if not for good. Lost when Max stops.
type Uploads = HashMap<(String, String), (String, Option<Instant>)>;

/// Before anything is said: what the last process committed and never
/// heard back about may or may not have gone out. It isn't sent again.
pub async fn recover(pool: &PgPool) -> sqlx::Result<u64> {
    let mut conn = pool.acquire().await?;
    ledger::mark_unknown(&mut conn, Platform::Qq, Utc::now()).await
}

/// Until every conversation's sender handle is gone, then until what was
/// queued is sent or `drain` runs out.
pub async fn run(
    api: Arc<dyn Api>,
    pool: PgPool,
    store: Option<Arc<Store>>,
    mut outbound: UnboundedReceiver<Outgoing>,
    drain: Duration,
) {
    let shared = Arc::new(Shared {
        api,
        pool,
        store,
        sent: Mutex::default(),
        uploads: Mutex::default(),
    });
    let mut chats = HashMap::new();
    let mut workers = Scope::new();
    while let Some(outgoing) = outbound.recv().await {
        let chat = outgoing.place.native_id.clone();
        let queue = chats.entry(chat).or_insert_with(|| {
            let (queue, rx) = mpsc::unbounded_channel();
            let shared = Arc::clone(&shared);
            workers.spawn(move |_| worker(shared, rx));
            queue
        });
        let _ = queue.send(outgoing);
    }
    drop(chats);
    workers.close(drain).await;
    info!("the QQ sender is done");
}

async fn worker(shared: Arc<Shared>, mut queue: UnboundedReceiver<Outgoing>) {
    while let Some(outgoing) = queue.recv().await {
        if let Err(error) = shared.deliver(&outgoing).await {
            warn!(message = %outgoing.message.id, %error, "couldn't send or record a message");
        }
    }
}

impl Shared {
    async fn deliver(&self, outgoing: &Outgoing) -> sqlx::Result<()> {
        let place = &outgoing.place;
        let message = &outgoing.message;
        // No connection is held while waiting for QQ.
        let mut conn = self.pool.acquire().await?;
        let lowered = lower(&mut conn, place.kind, &message.content).await?;
        drop(conn);
        let Some(chat) = chat(&place.native_id) else {
            warn!(endpoint = place.native_id, "not a QQ chat");
            return Ok(());
        };
        let Lowered {
            text,
            quote,
            picture,
        } = lowered;
        let result = match picture {
            Some(sha256) => {
                let caption = Some(text.trim().to_owned()).filter(|text| !text.is_empty());
                self.picture(chat, &place.native_id, message.id, &sha256, caption, quote)
                    .await
            }
            None if !text.trim().is_empty() => {
                self.text(chat, &place.native_id, message.id, text, quote)
                    .await
            }
            None => Err("nothing to send".to_owned()),
        };
        let delivered = match &result {
            Ok(sent) => Delivered::Delivered {
                native_id: &sent.id,
                quote_id: sent.ref_idx.as_deref(),
            },
            Err(error) => Delivered::Failed { error },
        };
        let mut conn = self.pool.acquire().await?;
        ledger::record_delivery(
            &mut conn,
            message.id,
            place.endpoint,
            &delivered,
            Utc::now(),
        )
        .await
    }

    /// Markdown, or plain text if QQ refuses that.
    async fn text(
        &self,
        chat: Chat<'_>,
        native_id: &str,
        id: MessageId,
        text: String,
        quote: Option<String>,
    ) -> Result<Sent, String> {
        let mut result = Err(String::new());
        for body in [Body::Markdown(text.clone()), Body::Text(text)] {
            self.proactive(native_id).await;
            let qq = Message {
                body,
                reply: None,
                quote: quote.clone(),
            };
            match self.api.send(chat, &qq).await {
                Ok(sent) => return Ok(sent),
                Err(error) => {
                    warn!(message = %id, %error, "QQ refused a message");
                    result = Err(error.to_string());
                }
            }
        }
        result
    }

    async fn picture(
        &self,
        chat: Chat<'_>,
        native_id: &str,
        id: MessageId,
        sha256: &str,
        caption: Option<String>,
        quote: Option<String>,
    ) -> Result<Sent, String> {
        let file_info = self
            .upload(chat, native_id, sha256)
            .await
            .map_err(|error| {
                warn!(message = %id, sha256, %error, "couldn't upload a picture");
                error
            })?;
        self.proactive(native_id).await;
        let qq = Message {
            body: Body::Media { file_info, caption },
            reply: None,
            quote,
        };
        self.api.send(chat, &qq).await.map_err(|error| {
            warn!(message = %id, %error, "QQ refused a picture");
            // In case QQ forgot it early: the next one uploads it again.
            let key = (native_id.to_owned(), sha256.to_owned());
            self.uploads
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .remove(&key);
            error.to_string()
        })
    }

    /// The picture's `file_info` in `chat`, uploaded unless it was lately.
    async fn upload(
        &self,
        chat: Chat<'_>,
        native_id: &str,
        sha256: &str,
    ) -> Result<String, String> {
        let key = (native_id.to_owned(), sha256.to_owned());
        let now = Instant::now();
        let fresh = |until: &Option<Instant>| until.is_none_or(|until| now < until);
        {
            let mut uploads = self.uploads.lock().unwrap_or_else(|p| p.into_inner());
            uploads.retain(|_, (_, until)| fresh(until));
            if let Some((file_info, _)) = uploads.get(&key) {
                return Ok(file_info.clone());
            }
        }
        let Some(store) = &self.store else {
            return Err("no content store".to_owned());
        };
        let bytes = tokio::fs::read(store.path(sha256))
            .await
            .map_err(|error| format!("reading {sha256}: {error}"))?;
        let uploaded = self
            .api
            .upload(chat, &bytes)
            .await
            .map_err(|error| error.to_string())?;
        let until = (uploaded.ttl > 0)
            .then(|| Instant::now() + Duration::from_secs(uploaded.ttl).saturating_sub(EARLY));
        let file_info = uploaded.file_info;
        let mut uploads = self.uploads.lock().unwrap_or_else(|p| p.into_inner());
        uploads.insert(key, (file_info.clone(), until));
        Ok(file_info)
    }

    /// Waits until a proactive message to `chat` is within QQ's rates.
    async fn proactive(&self, chat: &str) {
        loop {
            let now = Instant::now();
            let wait = {
                let mut sent = self.sent.lock().unwrap_or_else(|p| p.into_inner());
                let mut until = None;
                for (key, rate) in [(None, BOT_RATE), (Some(chat.to_owned()), CHAT_RATE)] {
                    let times = sent.entry(key).or_default();
                    while times.front().is_some_and(|at| now >= *at + MINUTE) {
                        times.pop_front();
                    }
                    if times.len() >= rate {
                        until = until.max(times.front().map(|at| *at + MINUTE));
                    }
                }
                if until.is_none() {
                    for key in [None, Some(chat.to_owned())] {
                        sent.entry(key).or_default().push_back(now);
                    }
                }
                until
            };
            match wait {
                None => return,
                Some(until) => {
                    info!(chat, "waiting for QQ's proactive message rate");
                    sleep_until(until).await;
                }
            }
        }
    }
}

/// `group:<group_openid>` or `c2c:<user_openid>`.
fn chat(native_id: &str) -> Option<Chat<'_>> {
    if let Some(group) = native_id.strip_prefix("group:") {
        Some(Chat::Group(group))
    } else {
        native_id.strip_prefix("c2c:").map(Chat::User)
    }
}

/// A row of Max's for QQ.
#[derive(Default)]
struct Lowered {
    /// As Markdown.
    text: String,
    /// The id to quote, if it quotes a row QQ knows.
    quote: Option<String>,
    /// The SHA-256 of the picture it sends, if any: one a message.
    picture: Option<String>,
}

async fn lower(
    conn: &mut PgConnection,
    kind: ConversationKind,
    content: &Content,
) -> sqlx::Result<Lowered> {
    let Content::Message { reply_to, nodes } = content else {
        return Ok(Lowered::default());
    };
    let quote = match reply_to {
        Some(target) => ledger::quote_id(conn, *target).await?,
        None => None,
    };
    let mut text = String::new();
    let mut picture = None;
    for node in nodes {
        match node {
            Node::Text { text: piece } => text.push_str(&markdown(piece)),
            Node::Mention {
                target: MentionTarget::Identity(identity),
                display,
            } => match platform::native_user_id(conn, *identity).await? {
                Some(openid) if kind == ConversationKind::Group => {
                    text.push_str(&format!("<qqbot-at-user id=\"{openid}\" />"));
                }
                _ => text.push_str(&format!("@{display}")),
            },
            Node::Mention { display, .. } => text.push_str(&format!("@{display}")),
            Node::Media {
                media: Some(MediaRef::Blob(sha256)),
                ..
            } if picture.is_none() => picture = Some(sha256.clone()),
            Node::Emote(_)
            | Node::Media { .. }
            | Node::Card(_)
            | Node::Forward(_)
            | Node::Unsupported(_) => {}
        }
    }
    Ok(Lowered {
        text,
        quote,
        picture,
    })
}

/// QQ renders `$$…$$` but not `\[…\]`.
fn markdown(text: &str) -> String {
    text.replace("\\[", "$$").replace("\\]", "$$")
}

#[cfg(test)]
mod tests;
