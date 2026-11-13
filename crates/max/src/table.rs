//! The conversation table: finds the actor for each message's chat,
//! starting it the first time, and keeps groups nobody bound out. See
//! "Runtime structure" and step 1 of "Processing flow" in docs/rust-rewrite.md.
//!
//! A private chat gets a conversation the first time someone writes. A
//! group needs `/bind`: until then its messages are dropped, all but the
//! `@Max /bind <码>` that binds it.
//!
//! What the VM service has for a conversation, such as a `maxx wake` from
//! a program in its VM, goes to its actor too, started if it isn't
//! running; and so does what Max in another conversation asks its Max.

use std::collections::HashMap;
use std::pin::pin;
use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use color_eyre::eyre::Result;
use max_core::ids::ConversationId;
use max_core::message::Platform;
use max_core::run::Outcome;
use max_db::platform::{self, Account, ConversationKind, Endpoint};
use max_db::turns;
use max_db::{PgConnection, PgPool};
use sqlx::Connection;
use tokio::sync::mpsc::error::SendError;
use tokio::sync::mpsc::{self, UnboundedReceiver, UnboundedSender};
use tracing::{debug, error, info, warn};

use crate::command::{self, Command};
use crate::conversation::{Conversation, Event, Heard, Place, Shared, Signal};
use crate::inbound::Inbound;
use crate::mcp;
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
    /// The platform and chat of each conversation an actor was started for.
    chats: HashMap<ConversationId, (Platform, String)>,
    scope: Scope,
}

impl Table {
    pub fn new(shared: Arc<Shared>, me: HashMap<Platform, Me>) -> Self {
        Self {
            shared,
            me,
            actors: HashMap::new(),
            chats: HashMap::new(),
            scope: Scope::new(),
        }
    }

    /// Until every adapter has stopped sending, then until each actor has
    /// ended its core, or `grace` runs out.
    pub async fn run(
        mut self,
        mut inbound: UnboundedReceiver<Inbound>,
        mut signals: UnboundedReceiver<Signal>,
        grace: Duration,
    ) {
        loop {
            tokio::select! {
                inbound = inbound.recv() => {
                    let Some(inbound) = inbound else { break };
                    let chat = inbound.chat.native_id.clone();
                    if let Err(error) = self.route(inbound).await {
                        error!(chat, %error, "lost a message: couldn't find its conversation");
                    }
                }
                Some(signal) = signals.recv() => {
                    if let Err(error) = self.signal(signal).await {
                        error!(%error, "lost something for a conversation");
                    }
                }
            }
        }
        for actor in self.actors.values() {
            let _ = actor.send(Event::Stop);
        }
        // Nothing new starts from here. A call that comes from a VM is
        // answered as the guest answers once max is gone: Max is away,
        // and its caller makes it again when the next max is up.
        let mut stopped = pin!(self.scope.close(grace));
        loop {
            tokio::select! {
                () = &mut stopped => break,
                Some(signal) = signals.recv() => away(signal),
            }
        }
        signals.close();
        while let Ok(signal) = signals.try_recv() {
            away(signal);
        }
        info!("every conversation has stopped");
    }

    async fn route(&mut self, mut inbound: Inbound) -> Result<()> {
        let key = (inbound.platform, inbound.chat.native_id.clone());
        if let Some(actor) = self.actors.get(&key) {
            match actor.send(Event::Inbound(inbound)) {
                Ok(()) => return Ok(()),
                // It stopped on an error, and logged why: it starts again,
                // with this message.
                Err(SendError(event)) => {
                    let Event::Inbound(back) = event else {
                        unreachable!("an inbound was sent");
                    };
                    info!(chat = key.1, "starting a conversation that had stopped");
                    self.actors.remove(&key);
                    inbound = back;
                }
            }
        }
        let Some(me) = self.me.get(&inbound.platform).cloned() else {
            warn!(platform = ?inbound.platform, "a message from a platform Max isn't on");
            return Ok(());
        };
        let mut conn = self.shared.services.pool.acquire().await?;
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
        drop(conn);
        let mailbox = self.start(key, endpoint, me).await?;
        let _ = mailbox.send(event);
        Ok(())
    }

    /// The conversation's actor, started for `endpoint` on the platform and
    /// chat of `key`.
    async fn start(
        &mut self,
        key: (Platform, String),
        endpoint: Endpoint,
        me: Me,
    ) -> Result<UnboundedSender<Event>> {
        let mut conn = self.shared.services.pool.acquire().await?;
        let kind = platform::conversation_kind(&mut conn, endpoint.conversation).await?;
        drop(conn);
        let place = Arc::new(Place {
            conversation: endpoint.conversation,
            kind,
            endpoint: endpoint.id,
            platform: key.0,
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
        self.chats.insert(conversation, key.clone());
        self.actors.insert(key, mailbox.clone());
        Ok(mailbox)
    }

    /// To the conversation's actor, started if it isn't running.
    async fn signal(&mut self, signal: Signal) -> Result<()> {
        let (conversation, event) = match signal {
            Signal::Call {
                conversation,
                tool,
                args,
                reply,
            } => (conversation, Event::Call { tool, args, reply }),
            Signal::Heard {
                conversation,
                heard,
            } => (conversation, Event::Heard(heard)),
            Signal::Subscribe {
                conversation,
                reply,
            } => (conversation, Event::Subscribe(reply)),
        };
        if let Some(key) = self.chats.get(&conversation)
            && let Some(actor) = self.actors.get(key)
            && !actor.is_closed()
        {
            let _ = actor.send(event);
            return Ok(());
        }
        // Whoever waits for what it asks hears why nothing comes of it,
        // as it would from the conversation's actor.
        match self.started(conversation).await {
            Ok(Some(mailbox)) => {
                let _ = mailbox.send(event);
                Ok(())
            }
            Ok(None) => {
                warn!(%conversation, "something for a conversation Max isn't in");
                self.unanswered(event, "Max serves no chat of that conversation");
                Ok(())
            }
            Err(error) => {
                self.unanswered(event, "Max couldn't start on that conversation");
                Err(error)
            }
        }
    }

    /// Starts `conversation`'s actor for what came for it: its mailbox,
    /// or None if Max is in no chat of the conversation.
    async fn started(
        &mut self,
        conversation: ConversationId,
    ) -> Result<Option<UnboundedSender<Event>>> {
        let mut conn = self.shared.services.pool.acquire().await?;
        let mut found = None;
        for (&platform, me) in &self.me {
            let Some(chat) = platform::endpoint_on(&mut conn, conversation, platform).await? else {
                continue;
            };
            if let Some(endpoint) =
                platform::find_endpoint(&mut conn, platform, &chat, me.account.identity).await?
            {
                found = Some(((platform, chat), endpoint, me.clone()));
                break;
            }
        }
        drop(conn);
        let Some((key, endpoint, me)) = found else {
            return Ok(None);
        };
        info!(%conversation, "starting a conversation for what came for it");
        Ok(Some(self.start(key, endpoint, me).await?))
    }

    /// `event` reaches no actor: the question in it is answered with
    /// `why`, back through here to its asker, and the call in it fails
    /// with it. The rest waits for nothing.
    fn unanswered(&self, event: Event, why: &str) {
        match event {
            Event::Heard(Heard::Asked(question)) => {
                let _ = self
                    .shared
                    .signals
                    .send(question.answered(Err(why.to_owned())));
            }
            Event::Call { reply, .. } => {
                let _ = reply.send(Err(mcp::Failure::new("internal", why)));
            }
            _ => {}
        }
    }

    /// `/bind <码>` in a group nobody bound: attaches the group to the
    /// conversation the code was issued for, and makes the sender's account
    /// here the owner's who asked for the code. None for anything else.
    async fn bind(
        &self,
        conn: &mut PgConnection,
        me: &Me,
        inbound: &Inbound,
    ) -> Result<Option<Endpoint>> {
        let chat = &inbound.chat.native_id;
        let Some(Command::Bind(Some(code))) = command::given(inbound) else {
            return Ok(None);
        };
        let Some(pending) = self.shared.binds.redeem(&code, std::time::Instant::now()) else {
            info!(chat, "dropped a /bind with a code that isn't valid");
            return Ok(None);
        };
        let mut tx = conn.begin().await?;
        if let Some(old) = pending.conversation {
            // Two codes issued for one old group: the first one used wins.
            if let Some(bound) = platform::endpoint_on(&mut tx, old, inbound.platform).await? {
                info!(chat, bound, "dropped a /bind for history already bound");
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

/// What came for a conversation as Max stops: a call is told Max is away,
/// and the rest is dropped, as it is once max is gone.
fn away(signal: Signal) {
    if let Signal::Call { reply, .. } = signal {
        let _ = reply.send(Err(mcp::Failure::away()));
    }
}

/// Before any actor starts: the turns the last process left without an
/// outcome, which were running when it crashed, are lost.
pub async fn close_unfinished(pool: &PgPool) -> Result<()> {
    let mut conn = pool.acquire().await?;
    let now = Utc::now();
    for turn in turns::unfinished(&mut conn, None).await? {
        info!(%turn, "a turn was running when Max crashed");
        turns::close(&mut conn, turn, &Outcome::Lost, now).await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests;
