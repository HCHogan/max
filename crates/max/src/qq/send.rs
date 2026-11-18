//! QQ's sender: the only writer of `deliveries` for QQ. What a
//! conversation says goes out in the order it was committed, one chat at a
//! time and chats side by side; see "Outbound" under "The official QQ bot".
//!
//! Every message goes out proactively, never as a passive reply: a group
//! Max is in allows that (机器人主动发言). It keeps within QQ's rates: it
//! waits, it isn't dropped. It goes as Markdown, and once more as plain
//! text if that fails. A picture or file is uploaded to the chat first,
//! unless it was lately; a picture goes with plain text under it, if any,
//! and a file alone. An unsend recalls what its row went out or came in
//! as.

use std::collections::{HashMap, VecDeque};
use std::fmt::Write;
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::Utc;
use max_core::ids::{EndpointId, MessageId};
use max_core::message::{
    Content, MediaKind, MediaRef, MentionTarget, Message as Row, Node, Platform, Sha256,
};
use max_db::ledger::{self, Sent as Delivered};
use max_db::platform::{self, ConversationKind};
use max_db::{PgConnection, PgPool};
use qqbot::api::{Media, Uploaded};
use qqbot::message::{Body, Outgoing as Message, Sent};
use qqbot::{Chat, api};
use tokio::sync::mpsc::{self, UnboundedReceiver};
use tokio::time::{Instant, sleep_until};
use tracing::{info, warn};

use super::chat;
use crate::conversation::{Outgoing, Place, Refused};
use crate::media::store::Store;
use crate::scope::Scope;

/// QQ's answer, some time later.
pub type Answer<'a, T> = Pin<Box<dyn Future<Output = Result<T, api::Error>> + Send + 'a>>;

/// Sends messages, uploads pictures and files, and recalls messages. QQ's
/// client in service; a recorder in tests.
pub trait Api: Send + Sync + 'static {
    /// Sends a message to a chat.
    fn send<'a>(&'a self, chat: Chat<'a>, message: &'a Message) -> Answer<'a, Sent>;
    /// Uploads a picture, a voice message or a file for a chat.
    fn upload<'a>(&'a self, chat: Chat<'a>, media: Media<'a>) -> Answer<'a, Uploaded>;
    /// Recalls a message from a chat.
    fn recall<'a>(&'a self, chat: Chat<'a>, message_id: &'a str) -> Answer<'a, ()>;
}

impl Api for qqbot::Client {
    fn send<'a>(&'a self, chat: Chat<'a>, message: &'a Message) -> Answer<'a, Sent> {
        Box::pin(Self::send(self, chat, message))
    }

    fn upload<'a>(&'a self, chat: Chat<'a>, media: Media<'a>) -> Answer<'a, Uploaded> {
        Box::pin(Self::upload(self, chat, media))
    }

    fn recall<'a>(&'a self, chat: Chat<'a>, message_id: &'a str) -> Answer<'a, ()> {
        Box::pin(Self::recall(self, chat, message_id))
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
    /// Where the pictures, voice messages and files Max sends are, if
    /// anywhere.
    store: Option<Arc<Store>>,
    /// When proactive messages went out, for each thing QQ's rates count.
    sent: Mutex<HashMap<Rated, VecDeque<Instant>>>,
    uploads: Mutex<Uploads>,
}

/// What a rate of QQ's counts the proactive messages of.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum Rated {
    /// The whole bot.
    Bot,
    /// One chat, by its native id.
    Chat(String),
}

/// Pictures, voice messages and files uploaded. Lost when Max stops.
type Uploads = HashMap<Upload, Kept>;

/// What was uploaded where: QQ keeps an upload for the chat it was made
/// to.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct Upload {
    /// The chat's native id.
    chat: String,
    attached: Attached,
}

/// An upload as QQ keeps it.
struct Kept {
    file_info: String,
    /// Until when it is used, if not for good.
    until: Option<Instant>,
}

/// Before anything is said: what the last process committed and never
/// heard back about may or may not have gone out. It isn't sent again.
///
/// # Errors
///
/// If the query fails.
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
        let Some(chat) = chat(&place.native_id) else {
            warn!(endpoint = place.native_id, "not a QQ chat");
            return Ok(());
        };
        // None for what has no id of its own.
        let result: Result<Option<Sent>, Unsent> = match message.content {
            Content::Unsend { target } => self
                .recall(chat, place.endpoint, message.id, target)
                .await?
                .map(|()| None),
            _ => self.message(chat, place.as_ref(), message).await?.map(Some),
        };
        let delivered = match &result {
            Ok(Some(sent)) => Delivered::Delivered {
                native_id: &sent.id,
                quote_id: sent.ref_idx.as_deref(),
            },
            Ok(None) => Delivered::Done,
            Err(Unsent::Refused(error)) => Delivered::Failed { error },
            Err(Unsent::Unknown(_)) => Delivered::Unknown,
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
            let _ = receipt.send(result.map(|_| message.id).map_err(Unsent::told));
        }
        Ok(())
    }

    /// A row Max says, as one QQ message.
    async fn message(
        &self,
        chat: Chat<'_>,
        place: &Place,
        message: &Row,
    ) -> sqlx::Result<Result<Sent, Unsent>> {
        // No connection is held while waiting for QQ.
        let mut conn = self.pool.acquire().await?;
        let Lowered {
            text,
            quote,
            attached,
        } = lower(&mut conn, place.kind, &message.content).await?;
        drop(conn);
        Ok(match attached {
            Some(attached) => {
                // Under a picture alone: a voice message and a file have
                // no text.
                let caption = Some(text.trim().to_owned())
                    .filter(|text| !text.is_empty() && attached.kind == Kind::Picture);
                self.attached(chat, &place.native_id, message.id, attached, caption, quote)
                    .await
            }
            None if !text.trim().is_empty() => {
                self.text(chat, &place.native_id, message.id, text, quote)
                    .await
            }
            None => Err(Unsent::Refused("nothing to send".to_owned())),
        })
    }

    /// Recalls `target` as it went out or came in at `endpoint`.
    async fn recall(
        &self,
        chat: Chat<'_>,
        endpoint: EndpointId,
        id: MessageId,
        target: MessageId,
    ) -> sqlx::Result<Result<(), Unsent>> {
        let mut conn = self.pool.acquire().await?;
        let native = ledger::native(&mut conn, target, endpoint).await?;
        drop(conn);
        let Some((native_id, _)) = native else {
            return Ok(Err(Unsent::Refused("QQ has no such message".to_owned())));
        };
        Ok(self.api.recall(chat, &native_id).await.map_err(|error| {
            warn!(message = %id, %target, %error, "QQ didn't recall a message");
            Unsent::from(&error).map(|_| refusal(&error))
        }))
    }

    /// Markdown, or plain text if QQ refuses that. When QQ's answer is lost,
    /// the message may have gone out: it isn't sent again.
    async fn text(
        &self,
        chat: Chat<'_>,
        native_id: &str,
        id: MessageId,
        text: String,
        quote: Option<String>,
    ) -> Result<Sent, Unsent> {
        let mut body = Body::Markdown(text);
        loop {
            self.proactive(native_id).await;
            let qq = Message {
                body,
                quote: quote.clone(),
            };
            let error = match self.api.send(chat, &qq).await {
                Ok(sent) => return Ok(sent),
                Err(error) => error,
            };
            warn!(message = %id, %error, "QQ didn't take a message");
            // The text goes again, as plain text, unless it may be out.
            body = match (qq.body, Unsent::from(&error)) {
                (Body::Markdown(text), Unsent::Refused(_)) => Body::Text(text),
                (_, unsent) => return Err(unsent),
            };
        }
    }

    async fn attached(
        &self,
        chat: Chat<'_>,
        native_id: &str,
        id: MessageId,
        attached: Attached,
        caption: Option<String>,
        quote: Option<String>,
    ) -> Result<Sent, Unsent> {
        let key = Upload {
            chat: native_id.to_owned(),
            attached,
        };
        let file_info = self.upload(chat, &key).await.map_err(|error| {
            let sha256 = &key.attached.sha256;
            warn!(message = %id, %sha256, %error, "couldn't upload what a message attaches");
            Unsent::Refused(error)
        })?;
        self.proactive(native_id).await;
        let qq = Message {
            body: Body::Media { file_info, caption },
            quote,
        };
        self.api.send(chat, &qq).await.map_err(|error| {
            warn!(message = %id, %error, "QQ didn't take what a message attaches");
            // In case QQ forgot it early: the next one uploads it again.
            self.uploads
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .remove(&key);
            Unsent::from(&error)
        })
    }

    /// The `file_info` of the picture, voice message or file `key` names,
    /// uploaded unless it was lately.
    async fn upload(&self, chat: Chat<'_>, key: &Upload) -> Result<String, String> {
        let now = Instant::now();
        {
            let mut uploads = self
                .uploads
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            uploads.retain(|_, kept| kept.until.is_none_or(|until| now < until));
            if let Some(kept) = uploads.get(key) {
                return Ok(kept.file_info.clone());
            }
        }
        let Some(store) = &self.store else {
            return Err("no content store".to_owned());
        };
        let Attached { sha256, kind } = &key.attached;
        // Read as it is uploaded: a file can be hundreds of MiB.
        let path = store.path(sha256);
        let content = api::Content::Path(&path);
        let media = match kind {
            Kind::Picture => Media::Picture(content),
            Kind::Voice => Media::Voice(content),
            Kind::File(name) => Media::File { name, content },
        };
        let uploaded = self
            .api
            .upload(chat, media)
            .await
            .map_err(|error| error.to_string())?;
        let until = (uploaded.ttl > 0)
            .then(|| Instant::now() + Duration::from_secs(uploaded.ttl).saturating_sub(EARLY));
        let kept = Kept {
            file_info: uploaded.file_info.clone(),
            until,
        };
        let mut uploads = self
            .uploads
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        uploads.insert(key.clone(), kept);
        Ok(uploaded.file_info)
    }

    /// Waits until a proactive message to `chat` is within QQ's rates.
    async fn proactive(&self, chat: &str) {
        loop {
            let now = Instant::now();
            let wait = {
                let mut sent = self
                    .sent
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                let mut until = None;
                let rates = [
                    (Rated::Bot, BOT_RATE),
                    (Rated::Chat(chat.to_owned()), CHAT_RATE),
                ];
                for (rated, rate) in rates {
                    let times = sent.entry(rated).or_default();
                    while times.front().is_some_and(|at| now >= *at + MINUTE) {
                        times.pop_front();
                    }
                    if times.len() >= rate {
                        until = until.max(times.front().map(|at| *at + MINUTE));
                    }
                }
                if until.is_none() {
                    for rated in [Rated::Bot, Rated::Chat(chat.to_owned())] {
                        sent.entry(rated).or_default().push_back(now);
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

/// Why a row didn't go out, or may not have.
#[derive(Debug)]
enum Unsent {
    /// QQ said no, or it never reached QQ.
    Refused(String),
    /// QQ's answer was lost or garbled: it may have gone out.
    Unknown(String),
}

impl Unsent {
    /// Unknown when the request may have reached QQ and its answer didn't
    /// come back whole.
    fn from(error: &api::Error) -> Self {
        let text = error.to_string();
        match error {
            api::Error::Http(error) if !error.is_connect() && !error.is_builder() => {
                Self::Unknown(text)
            }
            api::Error::Decode { .. } => Self::Unknown(text),
            _ => Self::Refused(text),
        }
    }

    fn map(self, f: impl FnOnce(String) -> String) -> Self {
        match self {
            Self::Refused(text) => Self::Refused(f(text)),
            Self::Unknown(text) => Self::Unknown(f(text)),
        }
    }

    /// As whoever waits on it is told.
    fn told(self) -> Refused {
        Refused::Unsent(match self {
            Self::Refused(text) => text,
            Self::Unknown(text) => {
                format!("QQ never answered, so it isn't known whether it was sent: {text}")
            }
        })
    }
}

/// Why QQ didn't recall a message, for whoever asked.
fn refusal(error: &api::Error) -> String {
    match error {
        api::Error::Api { code: 40062003, .. } => {
            "QQ says there is no permission (40062003): someone else's message can be recalled only by a bot that is the group's admin, and the owner's and the admins' not at all"
                .to_owned()
        }
        api::Error::Api { code: 40064004, .. } => {
            "it was sent over 2 minutes ago, and QQ no longer lets it be recalled (40064004)".to_owned()
        }
        api::Error::Api { code, message, .. } => format!("QQ didn't recall it: {code} {message}"),
        error => format!("QQ never answered, so it isn't known whether it was recalled: {error}"),
    }
}

/// A row of Max's for QQ.
#[derive(Default)]
struct Lowered {
    /// As Markdown.
    text: String,
    /// The id to quote, if it quotes a row QQ knows.
    quote: Option<String>,
    /// The picture, voice message or file it sends, if any: one a message.
    attached: Option<Attached>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct Attached {
    sha256: Sha256,
    kind: Kind,
}

/// What an attachment goes out as.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
enum Kind {
    Picture,
    Voice,
    /// Under this name.
    File(String),
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
    let mut attached = None;
    for node in nodes {
        match node {
            Node::Text { text: piece } => push_markdown(&mut text, piece),
            Node::Mention {
                target: MentionTarget::Identity(identity),
                display,
            } => match platform::native_user_id(conn, *identity).await? {
                Some(openid) if kind == ConversationKind::Group => {
                    let _ = write!(text, "<qqbot-at-user id=\"{openid}\" />");
                }
                _ => {
                    let _ = write!(text, "@{display}");
                }
            },
            Node::Mention { display, .. } => {
                let _ = write!(text, "@{display}");
            }
            Node::Media {
                media: Some(MediaRef::Blob(sha256)),
                meta,
            } if attached.is_none() => {
                let kind = match meta.kind {
                    MediaKind::File => {
                        Kind::File(meta.name.clone().unwrap_or_else(|| "file".to_owned()))
                    }
                    MediaKind::Audio => Kind::Voice,
                    _ => Kind::Picture,
                };
                attached = Some(Attached {
                    sha256: sha256.clone(),
                    kind,
                });
            }
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
        attached,
    })
}

/// QQ renders `$$…$$` but not `\[…\]`.
fn push_markdown(out: &mut String, text: &str) {
    let mut from = 0;
    for (at, _) in text.match_indices('\\') {
        if matches!(text.as_bytes().get(at + 1), Some(b'[' | b']')) {
            out.push_str(&text[from..at]);
            out.push_str("$$");
            from = at + 2;
        }
    }
    out.push_str(&text[from..]);
}

#[cfg(test)]
mod tests;
