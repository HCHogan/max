//! QQ's sender: the only writer of `deliveries` for QQ. What a
//! conversation says goes out in the order it was committed, one chat at a
//! time and chats side by side; see "出站" under "QQ 官方机器人".
//!
//! Every message goes out proactively, never as a passive reply: a group
//! Max is in allows that (机器人主动发言). It keeps within QQ's rates: it
//! waits, it isn't dropped. It goes as Markdown, and once more as plain
//! text if that fails.

use std::collections::{HashMap, VecDeque};
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::Utc;
use max_core::message::{Content, MentionTarget, Node, Platform};
use max_db::ledger::{self, Sent as Delivered};
use max_db::platform::{self, ConversationKind};
use max_db::{PgConnection, PgPool};
use qqbot::message::{Body, Outgoing as Message, Sent};
use qqbot::{Chat, api};
use tokio::sync::mpsc::{self, UnboundedReceiver};
use tokio::time::{Instant, sleep_until};
use tracing::{info, warn};

use crate::conversation::Outgoing;
use crate::scope::Scope;

/// Sends a message. QQ's client in service; a recorder in tests.
pub trait Api: Send + Sync + 'static {
    fn send<'a>(
        &'a self,
        chat: Chat<'a>,
        message: &'a Message,
    ) -> Pin<Box<dyn Future<Output = Result<Sent, api::Error>> + Send + 'a>>;
}

impl Api for qqbot::Client {
    fn send<'a>(
        &'a self,
        chat: Chat<'a>,
        message: &'a Message,
    ) -> Pin<Box<dyn Future<Output = Result<Sent, api::Error>> + Send + 'a>> {
        Box::pin(qqbot::Client::send(self, chat, message))
    }
}

const MINUTE: Duration = Duration::from_secs(60);
/// Proactive messages a minute, for the whole bot and for one chat.
const BOT_RATE: usize = 60;
const CHAT_RATE: usize = 20;

struct Shared {
    api: Arc<dyn Api>,
    pool: PgPool,
    /// When proactive messages went out, per chat and (None) for the bot.
    sent: Mutex<HashMap<Option<String>, VecDeque<Instant>>>,
}

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
    mut outbound: UnboundedReceiver<Outgoing>,
    drain: Duration,
) {
    let shared = Arc::new(Shared {
        api,
        pool,
        sent: Mutex::default(),
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
        let (text, quote) = lower(&mut conn, place.kind, &message.content).await?;
        drop(conn);
        let Some(chat) = chat(&place.native_id) else {
            warn!(endpoint = place.native_id, "not a QQ chat");
            return Ok(());
        };
        let mut result = Err("nothing to send".to_owned());
        if !text.trim().is_empty() {
            for body in [Body::Markdown(text.clone()), Body::Text(text.clone())] {
                self.proactive(&place.native_id).await;
                let qq = Message {
                    body,
                    reply: None,
                    quote: quote.clone(),
                };
                match self.api.send(chat, &qq).await {
                    Ok(sent) => {
                        result = Ok(sent);
                        break;
                    }
                    Err(error) => {
                        warn!(message = %message.id, %error, "QQ refused a message");
                        result = Err(error.to_string());
                    }
                }
            }
        }
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

/// A row of Max's as QQ Markdown, and the id to quote, if it quotes a row
/// QQ knows. Max writes text and mentions; media comes later.
async fn lower(
    conn: &mut PgConnection,
    kind: ConversationKind,
    content: &Content,
) -> sqlx::Result<(String, Option<String>)> {
    let Content::Message { reply_to, nodes } = content else {
        return Ok((String::new(), None));
    };
    let quote = match reply_to {
        Some(target) => ledger::quote_id(conn, *target).await?,
        None => None,
    };
    let mut text = String::new();
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
            Node::Emote(_)
            | Node::Media { .. }
            | Node::Card(_)
            | Node::Forward(_)
            | Node::Unsupported(_) => {}
        }
    }
    Ok((text, quote))
}

/// QQ renders `$$…$$` but not `\[…\]`.
fn markdown(text: &str) -> String {
    text.replace("\\[", "$$").replace("\\]", "$$")
}

#[cfg(test)]
mod tests;
