//! Committing rows to the timeline: what someone sent, and what Max says.
//! One transaction each, resolving accounts, quotes and mentions on the
//! way in; the actor moves its head only once a row is committed.

use std::collections::BTreeMap;

use chrono::{DateTime, FixedOffset, Utc};
use max_core::faces;
use max_core::ids::{IdentityId, MessageId, PrincipalId, TurnId};
use max_core::message::{
    Content, Draft, DraftNode, Emote, MentionTarget, Message, Node, Platform, Sender,
};
use max_core::render::{Mark, Render};
use max_db::ledger::{self, NewMessage};
use max_db::platform::{self, Account, ConversationKind};
use sqlx::{Connection, PgConnection};
use tracing::warn;

use super::Place;
use crate::inbound::{InNode, Inbound, Quote};

/// Why a row is addressed to Max.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Direct {
    MentionsMe,
    RepliesToMe,
    /// Anything in a private chat.
    Private,
}

impl Direct {
    pub fn mark(self) -> Mark {
        match self {
            Self::MentionsMe => Mark::MentionsYou,
            Self::RepliesToMe => Mark::RepliesToYou,
            Self::Private => Mark::None,
        }
    }
}

/// A row someone sent, as committed, with what the actor routes on.
#[derive(Clone, Debug, PartialEq)]
pub struct Committed {
    pub message: Message,
    pub sender: Account,
    pub command: bool,
    pub direct: Option<Direct>,
    /// What the sender wrote, without the @ of Max.
    pub text: String,
}

/// How far back a quote of Max's message is looked for by its text.
const QUOTE_SEARCH: i64 = 50;

pub async fn inbound(
    conn: &mut PgConnection,
    place: &Place,
    inbound: &Inbound,
    now: DateTime<Utc>,
    offset: FixedOffset,
) -> sqlx::Result<Committed> {
    let mut tx = conn.begin().await?;
    let person = &inbound.sender;
    let sender = platform::account(
        &mut tx,
        place.platform,
        &person.native_user_id,
        &person.name,
    )
    .await?;
    let mut people = BTreeMap::from([
        (sender.identity, sender.principal),
        (place.me.identity, place.me.principal),
    ]);
    let mut nodes = Vec::with_capacity(inbound.nodes.len());
    for node in &inbound.nodes {
        nodes.push(match node {
            InNode::Node(node) => node.clone(),
            InNode::Mention { user, display } => {
                let account = platform::account(&mut tx, place.platform, user, display).await?;
                people.insert(account.identity, account.principal);
                mention(account.identity, display)
            }
            InNode::MentionMe { display } => mention(place.me.identity, display),
        });
    }
    let reply_to = match &inbound.quote {
        Some(quote) => quoted(&mut tx, place, quote).await?,
        None => None,
    };
    let replies_to_me = match reply_to {
        Some(id) => ledger::row(&mut tx, place.conversation, id)
            .await?
            .is_some_and(|row| row.message.sender.identity == place.me.identity),
        None => false,
    };
    let direct = if place.kind == ConversationKind::Direct {
        Some(Direct::Private)
    } else if inbound.mentions_me() {
        Some(Direct::MentionsMe)
    } else if replies_to_me {
        Some(Direct::RepliesToMe)
    } else {
        None
    };
    let text = inbound.plain_text();
    let command = crate::command::parse(&text).is_some();
    let content = Content::Message { reply_to, nodes };
    let sender_snapshot = Sender {
        identity: sender.identity,
        name: person.name.clone(),
        role: person.role,
    };
    let rendered = Render {
        people: &people,
        offset,
    }
    .content(&content);
    let id = ledger::insert(
        &mut tx,
        &NewMessage {
            conversation: place.conversation,
            endpoint: place.endpoint,
            sender: &sender_snapshot,
            native_id: Some(&inbound.native_id),
            quote_id: inbound.quote_id.as_deref(),
            sent_at: inbound.at,
            received_at: now,
            command,
            content: &content,
            raw: &inbound.raw,
            text: &rendered,
            turn: None,
            segment: None,
        },
    )
    .await?;
    tx.commit().await?;
    Ok(Committed {
        message: Message {
            id,
            conversation: place.conversation,
            sender: sender_snapshot,
            at: inbound.at,
            content,
            turn: None,
            raw: inbound.raw.clone(),
        },
        sender,
        command,
        direct,
        text,
    })
}

fn mention(identity: IdentityId, display: &str) -> Node {
    Node::Mention {
        target: MentionTarget::Identity(identity),
        display: display.to_owned(),
    }
}

/// The row a quote points at: by its quote id, or for a message of Max's
/// whose id the platform changed, by its text among what Max said lately.
async fn quoted(
    conn: &mut PgConnection,
    place: &Place,
    quote: &Quote,
) -> sqlx::Result<Option<MessageId>> {
    if let Some(id) = &quote.quote_id
        && let Some(found) = ledger::by_quote_id(conn, place.endpoint, id).await?
    {
        return Ok(Some(found));
    }
    let Some(text) = &quote.text else {
        return Ok(None);
    };
    let probe: String = words(text).chars().take(16).collect();
    if probe.is_empty() {
        return Ok(None);
    }
    let said = ledger::said_by(conn, place.endpoint, place.me.identity, QUOTE_SEARCH).await?;
    Ok(said
        .into_iter()
        .find(|(_, said)| words(said).contains(&probe))
        .map(|(id, _)| id))
}

/// Text without what is in brackets or whitespace: what a platform's
/// rendering of a message and ours have in common.
fn words(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut depth = 0u32;
    for c in text.chars() {
        match c {
            '[' => depth += 1,
            ']' => depth = depth.saturating_sub(1),
            c if depth == 0 && !c.is_whitespace() => out.push(c),
            _ => {}
        }
    }
    out
}

/// What Max says: a segment of a turn's output, or a command's answer.
/// A quote of something that isn't a message on this timeline is dropped,
/// and the draft comes back as it will be sent.
pub async fn said(
    conn: &mut PgConnection,
    place: &Place,
    draft: Draft,
    turn: Option<TurnId>,
    segment: Option<i32>,
    now: DateTime<Utc>,
    offset: FixedOffset,
) -> sqlx::Result<(Message, Draft)> {
    let mut tx = conn.begin().await?;
    let mut draft = draft;
    if let Some(target) = draft.reply_to {
        let row = ledger::row(&mut tx, place.conversation, target).await?;
        let quotable =
            row.is_some_and(|row| matches!(row.message.content, Content::Message { .. }));
        if !quotable {
            warn!(conversation = %place.conversation, %target, "dropped a quote of no message here");
            draft.reply_to = None;
        }
    }
    let mut people = BTreeMap::new();
    let mut nodes = Vec::with_capacity(draft.nodes.len());
    for node in &draft.nodes {
        match node {
            DraftNode::Text { text } => nodes.push(Node::Text { text: text.clone() }),
            DraftNode::Mention { principal } => {
                nodes.push(mentioned(&mut tx, place, *principal, &mut people).await?);
            }
            DraftNode::Face { face } => nodes.push(Node::Emote(Emote {
                platform: Platform::Qq,
                id: face.0.to_string(),
                name: faces::name(*face).map(str::to_owned),
            })),
            // Media comes with the VM's tools.
            DraftNode::Media { .. } => {}
        }
    }
    let content = Content::Message {
        reply_to: draft.reply_to,
        nodes,
    };
    let sender = Sender {
        identity: place.me.identity,
        name: place.my_name.clone(),
        role: None,
    };
    let rendered = Render {
        people: &people,
        offset,
    }
    .content(&content);
    let raw = serde_json::Value::Null;
    let id = ledger::insert(
        &mut tx,
        &NewMessage {
            conversation: place.conversation,
            endpoint: place.endpoint,
            sender: &sender,
            native_id: None,
            quote_id: None,
            sent_at: now,
            received_at: now,
            command: false,
            content: &content,
            raw: &raw,
            text: &rendered,
            turn,
            segment,
        },
    )
    .await?;
    tx.commit().await?;
    let message = Message {
        id,
        conversation: place.conversation,
        sender,
        at: now,
        content,
        turn,
        raw,
    };
    Ok((message, draft))
}

/// A person Max mentions, by the account they last spoke from here; one
/// who never spoke here is named in text.
async fn mentioned(
    conn: &mut PgConnection,
    place: &Place,
    principal: PrincipalId,
    people: &mut BTreeMap<IdentityId, PrincipalId>,
) -> sqlx::Result<Node> {
    if let Some(speaker) = platform::speaker(conn, place.endpoint, principal).await? {
        people.insert(speaker.identity, principal);
        return Ok(mention(speaker.identity, &speaker.name));
    }
    let known = platform::roster(conn, place.endpoint, &[principal]).await?;
    let name = known.first().map_or("某人", |known| known.name.as_str());
    Ok(Node::Text {
        text: format!("@{name}"),
    })
}

#[cfg(test)]
mod tests;
