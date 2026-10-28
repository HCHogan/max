//! The conversation table: finds the actor for each message's chat,
//! starting it the first time, and keeps groups nobody bound out. See
//! "运行时结构" and step 1 of "运行流程" in docs/rust-rewrite.md.
//!
//! A private chat gets a conversation the first time someone writes. A
//! group needs `!bind`: until then its messages are dropped, all but the
//! `!bind <码>` that binds it.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use color_eyre::eyre::Result;
use max_core::message::Platform;
use max_core::run::Outcome;
use max_db::platform::{self, Account, ConversationKind, Endpoint};
use max_db::turns;
use max_db::{PgConnection, PgPool};
use sqlx::Connection;
use tokio::sync::mpsc::{self, UnboundedReceiver, UnboundedSender};
use tracing::{debug, error, info, warn};

use crate::command::{self, Command};
use crate::conversation::{Conversation, Event, Place, Shared};
use crate::inbound::Inbound;
use crate::scope::Scope;

/// Max's account on a platform.
#[derive(Clone, Debug)]
pub struct Me {
    pub account: Account,
    pub name: String,
}

pub struct Table {
    shared: Arc<Shared>,
    me: HashMap<Platform, Me>,
    /// Mailboxes by platform and chat.
    actors: HashMap<(Platform, String), UnboundedSender<Event>>,
    scope: Scope,
}

impl Table {
    pub fn new(shared: Arc<Shared>, me: HashMap<Platform, Me>) -> Self {
        Self {
            shared,
            me,
            actors: HashMap::new(),
            scope: Scope::new(),
        }
    }

    /// Until every adapter has stopped sending, then until each actor has
    /// ended its core, or `grace` runs out.
    pub async fn run(mut self, mut inbound: UnboundedReceiver<Inbound>, grace: Duration) {
        while let Some(inbound) = inbound.recv().await {
            let chat = inbound.chat.native_id.clone();
            if let Err(error) = self.route(inbound).await {
                error!(chat, %error, "lost a message: couldn't find its conversation");
            }
        }
        for actor in self.actors.values() {
            let _ = actor.send(Event::Stop);
        }
        self.scope.close(grace).await;
        info!("every conversation has stopped");
    }

    async fn route(&mut self, inbound: Inbound) -> Result<()> {
        let key = (inbound.platform, inbound.chat.native_id.clone());
        if let Some(actor) = self.actors.get(&key) {
            if actor.send(Event::Inbound(inbound)).is_err() {
                // It logged why; the next message starts it again.
                warn!(chat = key.1, "lost a message: its conversation had stopped");
                self.actors.remove(&key);
            }
            return Ok(());
        }
        let Some(me) = self.me.get(&inbound.platform).cloned() else {
            warn!(platform = ?inbound.platform, "a message from a platform Max isn't on");
            return Ok(());
        };
        let mut conn = self.shared.pool.acquire().await?;
        let (platform, chat) = (inbound.platform, &inbound.chat.native_id);
        let found = platform::find_endpoint(&mut conn, platform, chat, me.account.identity).await?;
        let (endpoint, event) = match (found, inbound.chat.kind) {
            (Some(endpoint), _) => (endpoint, Event::Inbound(inbound)),
            (None, ConversationKind::Direct) => {
                let endpoint = platform::endpoint(
                    &mut conn,
                    platform,
                    chat,
                    me.account.identity,
                    ConversationKind::Direct,
                    Some(&inbound.sender.name),
                )
                .await?;
                (endpoint, Event::Inbound(inbound))
            }
            (None, ConversationKind::Group) => match self.bind(&mut conn, &me, &inbound).await? {
                Some(endpoint) => (endpoint, Event::Bound(inbound)),
                None => {
                    debug!(chat, "dropped a message from a group nobody bound");
                    return Ok(());
                }
            },
        };
        let kind = platform::conversation_kind(&mut conn, endpoint.conversation).await?;
        drop(conn);
        let place = Arc::new(Place {
            conversation: endpoint.conversation,
            kind,
            endpoint: endpoint.id,
            platform,
            native_id: key.1.clone(),
            me: me.account,
            my_name: me.name,
        });
        let (mailbox, rx) = mpsc::unbounded_channel();
        let actor = Conversation::new(Arc::clone(&self.shared), place, mailbox.clone()).await?;
        let conversation = endpoint.conversation;
        self.scope.spawn(move |_| async move {
            if let Err(error) = actor.run(rx).await {
                error!(%conversation, %error, "a conversation stopped on an error");
            }
        });
        let _ = mailbox.send(event);
        self.actors.insert(key, mailbox);
        Ok(())
    }

    /// `!bind <码>` in a group nobody bound: attaches the group to the
    /// conversation the code was issued for, and makes the sender's account
    /// here the owner's who asked for the code. None for anything else.
    async fn bind(
        &self,
        conn: &mut PgConnection,
        me: &Me,
        inbound: &Inbound,
    ) -> Result<Option<Endpoint>> {
        let chat = &inbound.chat.native_id;
        let Some(Command::Bind(Some(code))) = command::parse(&inbound.plain_text()) else {
            return Ok(None);
        };
        let Some(pending) = self.shared.binds.redeem(&code, std::time::Instant::now()) else {
            info!(chat, "dropped a !bind with a code that isn't valid");
            return Ok(None);
        };
        let mut tx = conn.begin().await?;
        if let Some(old) = pending.conversation {
            // Two codes issued for one old group: the first one used wins.
            if let Some(bound) = platform::endpoint_on(&mut tx, old, inbound.platform).await? {
                info!(chat, bound, "dropped a !bind for history already bound");
                return Ok(None);
            }
        }
        let endpoint = platform::attach(
            &mut tx,
            pending.conversation,
            inbound.platform,
            chat,
            me.account.identity,
            ConversationKind::Group,
        )
        .await?;
        let sender = &inbound.sender;
        let account = platform::account(
            &mut tx,
            inbound.platform,
            &sender.native_user_id,
            &sender.name,
        )
        .await?;
        platform::merge(&mut tx, account.principal, pending.owner).await?;
        tx.commit().await?;
        info!(chat, conversation = %endpoint.conversation, "bound a group");
        Ok(Some(endpoint))
    }
}

/// Before any actor starts: the turns the last process left without an
/// outcome, which were running when it crashed, are lost.
pub async fn close_unfinished(pool: &PgPool) -> Result<()> {
    let mut conn = pool.acquire().await?;
    let now = Utc::now();
    for turn in turns::unfinished(&mut conn).await? {
        info!(%turn, "a turn was running when Max crashed");
        turns::close(&mut conn, turn, &Outcome::Lost, now).await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests;
