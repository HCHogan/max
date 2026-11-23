//! What Max needs of a chat platform. A platform's adapter implements
//! [`Adapter`] and `max-cli` starts it; nothing else in max tells one
//! platform from another. See docs/design/platforms.md.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Utc};
use color_eyre::eyre::Result;
use max_core::message::{Message, Platform};
use max_db::platform::Speaker;
use max_db::{PgPool, ledger};
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};
use tokio_util::sync::CancellationToken;

use crate::conversation::{Outgoing, Place};
use crate::inbound::Inbound;
use crate::service::Failure;

/// A platform's answer, some time later.
pub type Answer<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// The platforms Max is on.
pub type Adapters = HashMap<Platform, Arc<dyn Adapter>>;

/// Max's account on a platform, as the platform has it.
#[derive(Clone, Debug)]
pub struct Bot {
    /// Its id there.
    pub id: String,
    /// What it is called there.
    pub name: String,
}

/// A chat platform, as Max uses it.
pub trait Adapter: Send + Sync + 'static {
    /// The platform, as rows record it.
    fn platform(&self) -> Platform;

    /// Max's account there.
    fn me(&self) -> &Bot;

    /// What the model is told of the platform in the system prompt of a
    /// conversation on it, such as what its rules let the tools do; empty
    /// for nothing.
    fn notes(&self) -> &str;

    /// Says what conversations say, each conversation's in the order it
    /// was committed, and records how each went, as the only writer of
    /// the platform's deliveries. Until every sender of `outbound` is
    /// gone, then until what was queued is said or `drain` runs out.
    fn send(&self, outbound: UnboundedReceiver<Outgoing>, drain: Duration) -> Answer<'static, ()>;

    /// Hands what is said on the platform to the conversation table, until
    /// `stop`. It fails when the platform shuts Max out for good.
    fn listen(
        &self,
        table: UnboundedSender<Inbound>,
        stop: CancellationToken,
    ) -> Answer<'static, Result<()>>;

    /// What the chat is called on the platform, if it has a name there.
    fn title<'a>(&'a self, place: &'a Place) -> Answer<'a, Result<Option<String>>>;

    /// Whether the platform lets `message` in `place`, which went out or
    /// came in at `sent`, be recalled now; why not if it doesn't. Max's
    /// own rules are checked already: it is a message of this chat, not
    /// recalled before, and someone else's only in a group.
    ///
    /// # Errors
    ///
    /// Why it can't be recalled, in the platform's terms.
    fn recallable(
        &self,
        place: &Place,
        message: &Message,
        sent: DateTime<Utc>,
    ) -> Result<(), String>;

    /// Mutes `member` of the group `place` until `until`, or lifts their
    /// mute; muting someone muted moves the end. It isn't Max, and has
    /// spoken in the group.
    fn mute<'a>(
        &'a self,
        place: &'a Place,
        member: &'a Speaker,
        until: Option<DateTime<Utc>>,
    ) -> Answer<'a, Result<(), Failure>>;

    /// The chat of the platform as it was, whose history `/bind <old>`
    /// goes on with: its platform and native id. None where there was no
    /// such platform.
    fn old_chat(&self, old: &str) -> Option<(Platform, String)>;
}

/// Before anything is said on `platform`: what the last run committed and
/// never heard back about may or may not have gone out. It isn't said
/// again. How many there were.
///
/// # Errors
///
/// If the query fails.
pub async fn recover(pool: &PgPool, platform: Platform) -> sqlx::Result<u64> {
    let mut conn = pool.acquire().await?;
    ledger::mark_unknown(&mut conn, platform, Utc::now()).await
}
