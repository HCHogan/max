//! WeChat's adapter, through wxdesk: the desktop client in a VM, which
//! wxdesk reads and drives and serves over TCP. See docs/design/wechat.md.

pub mod inbound;
pub mod link;
pub mod listen;
pub mod send;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Utc};
use color_eyre::eyre::Result;
use max_core::message::{Message, Platform};
use max_db::PgPool;
use max_db::platform::{ConversationKind, Speaker};
use serde::Deserialize;
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};
use tokio_util::sync::CancellationToken;

use max::adapter::{Adapter, Answer, Bot};
use max::conversation::{Outgoing, Place};
use max::inbound::Inbound;
use max::media::store::Store;
use max::service::Failure;

use link::Link;

const GROUP: &str = "group:";
const USER: &str = "user:";

/// `[platforms.wechat]`.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    /// Where wxdesk listens, such as `127.0.0.1:17710`.
    pub address: String,
    /// The file wxdesk's token is in.
    pub token_file: PathBuf,
    /// What Max is called on WeChat, as the client shows it.
    pub name: String,
}

/// WeChat's adapter.
pub struct Wechat {
    link: Arc<Link>,
    pool: PgPool,
    /// Where the pictures and files that come and go are, if anywhere.
    store: Option<Arc<Store>>,
    me: Bot,
}

impl std::fmt::Debug for Wechat {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Wechat")
            .field("me", &self.me)
            .finish_non_exhaustive()
    }
}

impl Wechat {
    /// The adapter `config` names. wxdesk is reached only as Max listens:
    /// its VM may be starting still.
    ///
    /// # Errors
    ///
    /// If the token can't be read.
    pub fn new(config: &Config, pool: PgPool, store: Option<Arc<Store>>) -> Result<Self> {
        let token = max::config::secret(&config.token_file)?;
        Ok(Self {
            link: Arc::new(Link::new(config.address.clone(), token)),
            pool,
            store,
            // A person on WeChat is known by their name: Max too.
            me: Bot {
                id: config.name.clone(),
                name: config.name.clone(),
            },
        })
    }
}

const NOTES: &str = "这个会话在微信上，Max 通过微信电脑版收发消息。微信的规矩：\n  \
    - 撤回（recall_message）和禁言（mute_member）在微信上都用不了。\n  \
    - 微信里认人只认显示的名字：一个人改了名字，在 Max 这里就成了另一个人。";

impl Adapter for Wechat {
    fn platform(&self) -> Platform {
        Platform::Wechat
    }

    fn me(&self) -> &Bot {
        &self.me
    }

    fn notes(&self) -> &str {
        NOTES
    }

    fn send(&self, outbound: UnboundedReceiver<Outgoing>, drain: Duration) -> Answer<'static, ()> {
        Box::pin(send::run(
            Arc::clone(&self.link),
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
        let link = Arc::clone(&self.link);
        let store = self.store.clone();
        let me = self.me.name.clone();
        Box::pin(async move { listen::listen(&link, store.as_deref(), &me, &table, stop).await })
    }

    fn title<'a>(&'a self, place: &'a Place) -> Answer<'a, Result<Option<String>>> {
        Box::pin(async move { Ok(group(&place.native_id).map(str::to_owned)) })
    }

    fn recallable(
        &self,
        _place: &Place,
        _message: &Message,
        _sent: DateTime<Utc>,
    ) -> Result<(), String> {
        Err("Max can't recall messages on WeChat".to_owned())
    }

    fn mute<'a>(
        &'a self,
        _place: &'a Place,
        _member: &'a Speaker,
        _until: Option<DateTime<Utc>>,
    ) -> Answer<'a, Result<(), Failure>> {
        Box::pin(async { Err(Failure::new("refused", "Max can't mute members on WeChat")) })
    }

    fn old_chat(&self, _old: &str) -> Option<(Platform, String)> {
        None
    }
}

/// A chat as its endpoint's native id has it: `group:<the group's name>`
/// or `user:<the friend's name>`, as the client's session list shows them.
#[must_use]
pub fn native_id(kind: ConversationKind, title: &str) -> String {
    match kind {
        ConversationKind::Group => format!("{GROUP}{title}"),
        ConversationKind::Direct => format!("{USER}{title}"),
    }
}

/// The chat's title in the client, which wxdesk knows it by.
#[must_use]
pub fn title(native_id: &str) -> Option<&str> {
    native_id
        .strip_prefix(GROUP)
        .or_else(|| native_id.strip_prefix(USER))
}

/// The group a native id names, if it names one.
#[must_use]
pub fn group(native_id: &str) -> Option<&str> {
    native_id.strip_prefix(GROUP)
}
