//! QQ's adapter, through the official bot: its gateway in, its REST API
//! out. See docs/design/qq.md.

pub mod groups;
pub mod inbound;
pub mod listen;
pub mod send;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, TimeDelta, Utc};
use color_eyre::eyre::Result;
use max_core::message::{Message, Platform, Role};
use max_db::PgPool;
use max_db::platform::Speaker;
use qqbot::Chat;
use serde::Deserialize;
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};
use tokio_util::sync::CancellationToken;

use max::adapter::{Adapter, Answer, Bot};
use max::conversation::{Outgoing, Place};
use max::inbound::Inbound;
use max::media::store::Store;
use max::service::Failure;

const GROUP: &str = "group:";
const C2C: &str = "c2c:";

/// How long QQ lets any message be recalled.
const RECALL: TimeDelta = TimeDelta::minutes(2);

/// `[platforms.qq]`.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    /// The file the bot's AppID is in.
    pub app_id_file: PathBuf,
    /// The file the bot's secret is in.
    pub app_secret_file: PathBuf,
}

/// QQ's adapter.
pub struct Qq {
    client: Arc<qqbot::Client>,
    pool: PgPool,
    /// Where the pictures, voice messages and files Max sends are, if
    /// anywhere.
    store: Option<Arc<Store>>,
    me: Bot,
    notes: String,
}

impl std::fmt::Debug for Qq {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Qq")
            .field("me", &self.me)
            .finish_non_exhaustive()
    }
}

impl Qq {
    /// The bot `config` names, which QQ is asked who it is.
    ///
    /// # Errors
    ///
    /// If the secrets can't be read, QQ doesn't take them, or QQ can't be
    /// reached.
    pub async fn connect(config: &Config, pool: PgPool, store: Option<Arc<Store>>) -> Result<Self> {
        let credentials = qqbot::Credentials {
            app_id: max::config::secret(&config.app_id_file)?,
            secret: max::config::secret(&config.app_secret_file)?,
        };
        let client = Arc::new(qqbot::Client::new(credentials)?);
        let bot = client.me().await?;
        let notes = format!(
            "这个会话在 QQ 上。QQ 的规矩：\n  \
            - 撤回（recall_message）：只能撤回 {} 分钟内的消息；别人的，要你是群管理员才能撤，群主和管理员的撤不了。\n  \
            - 禁言（mute_member）：要你是群管理员才能禁言，群主和管理员禁不了；一次最多 {} 天。",
            RECALL.num_minutes(),
            groups::LONGEST.num_days(),
        );
        Ok(Self {
            client,
            pool,
            store,
            me: Bot {
                id: bot.id,
                name: bot.username,
            },
            notes,
        })
    }
}

impl Adapter for Qq {
    fn platform(&self) -> Platform {
        Platform::Qq
    }

    fn me(&self) -> &Bot {
        &self.me
    }

    fn notes(&self) -> &str {
        &self.notes
    }

    fn send(&self, outbound: UnboundedReceiver<Outgoing>, drain: Duration) -> Answer<'static, ()> {
        let api = Arc::clone(&self.client) as Arc<dyn send::Api>;
        Box::pin(send::run(
            api,
            self.pool.clone(),
            self.store.clone(),
            outbound,
            drain,
        ))
    }

    fn listen(
        &self,
        table: UnboundedSender<Inbound>,
        stop: CancellationToken,
    ) -> Answer<'static, Result<()>> {
        let (client, pool) = (Arc::clone(&self.client), self.pool.clone());
        Box::pin(async move { listen::listen(&client, &pool, &table, stop).await })
    }

    fn title<'a>(&'a self, place: &'a Place) -> Answer<'a, Result<Option<String>>> {
        Box::pin(async move {
            let Some(group) = group(&place.native_id) else {
                return Ok(None);
            };
            Ok(Some(self.client.info(group).await?.group_name))
        })
    }

    fn recallable(
        &self,
        place: &Place,
        message: &Message,
        sent: DateTime<Utc>,
    ) -> Result<(), String> {
        let sender = &message.sender;
        if sender.identity != place.me.identity
            && matches!(sender.role, Some(Role::Owner | Role::Admin))
        {
            return Err("QQ doesn't let a bot recall the owner's or an admin's message".to_owned());
        }
        if Utc::now() - sent > RECALL {
            return Err(format!(
                "it was sent over {} minutes ago, and QQ no longer lets it be recalled",
                RECALL.num_minutes()
            ));
        }
        Ok(())
    }

    fn mute<'a>(
        &'a self,
        place: &'a Place,
        member: &'a Speaker,
        until: Option<DateTime<Utc>>,
    ) -> Answer<'a, Result<(), Failure>> {
        Box::pin(groups::mute(&self.client, place, member, until))
    }

    /// A group of the QQ before this one, by its number.
    fn old_chat(&self, old: &str) -> Option<(Platform, String)> {
        Some((Platform::QqLegacy, native_id(Chat::Group(old))))
    }
}

/// A chat as its endpoint's native id has it: `group:<group_openid>` or
/// `c2c:<user_openid>`. A group of the QQ before this one is named the
/// same way, by its number.
#[must_use]
pub fn native_id(chat: Chat<'_>) -> String {
    match chat {
        Chat::Group(group) => format!("{GROUP}{group}"),
        Chat::User(user) => format!("{C2C}{user}"),
    }
}

/// The chat a native id names, if it is one of QQ's.
pub fn chat(native_id: &str) -> Option<Chat<'_>> {
    match native_id.strip_prefix(GROUP) {
        Some(group) => Some(Chat::Group(group)),
        None => native_id.strip_prefix(C2C).map(Chat::User),
    }
}

/// The group a native id names, if it names one.
#[must_use]
pub fn group(native_id: &str) -> Option<&str> {
    match chat(native_id)? {
        Chat::Group(group) => Some(group),
        Chat::User(_) => None,
    }
}
