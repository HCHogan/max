//! The ledger: timeline rows.

use chrono::{DateTime, Utc};
use max_core::ids::{ConversationId, EndpointId, IdentityId, MessageId, TurnId};
use max_core::message::{Content, Message, Node, Role, Sender};
use sqlx::PgConnection;
use sqlx::types::Json;

use crate::platform::role;
use crate::unknown;

fn role_name(role: Role) -> &'static str {
    match role {
        Role::Owner => "owner",
        Role::Admin => "admin",
        Role::Member => "member",
    }
}

/// A row to commit.
#[derive(Clone, Debug)]
pub struct NewMessage<'a> {
    pub conversation: ConversationId,
    pub endpoint: EndpointId,
    pub sender: &'a Sender,
    /// The platform's id for an inbound row; None for what Max says.
    pub native_id: Option<&'a str>,
    pub sent_at: DateTime<Utc>,
    pub received_at: DateTime<Utc>,
    /// A command, which the actor runs; only for `Content::Message`.
    pub command: bool,
    pub content: &'a Content,
    pub raw: &'a serde_json::Value,
    /// The rendered text, for search.
    pub text: &'a str,
    pub turn: Option<TurnId>,
    /// Where in its turn's output a segment Max said came.
    pub segment: Option<i32>,
}

/// A stored row, with what the reader needs besides the message.
#[derive(Clone, Debug, PartialEq)]
pub struct Row {
    pub message: Message,
    pub endpoint: EndpointId,
    pub command: bool,
}

/// The columns a `Content` spreads over.
struct Columns {
    kind: &'static str,
    event: Option<&'static str>,
    reply_to: Option<i64>,
    target: Option<i64>,
    target_identity: Option<i64>,
    nodes: Vec<Node>,
}

fn columns(content: &Content, command: bool) -> Columns {
    let event = |event, target: Option<MessageId>, nodes| Columns {
        kind: "event",
        event: Some(event),
        reply_to: None,
        target: target.map(|id| id.0),
        target_identity: None,
        nodes,
    };
    match content {
        Content::Message { reply_to, nodes } => Columns {
            kind: if command { "command" } else { "chat" },
            event: None,
            reply_to: reply_to.map(|id| id.0),
            target: None,
            target_identity: None,
            nodes: nodes.clone(),
        },
        Content::Edit { target, nodes } => event("edit", Some(*target), nodes.clone()),
        Content::Unsend { target } => event("unsend", Some(*target), Vec::new()),
        Content::React {
            target,
            emote,
            added,
        } => event(
            if *added { "react" } else { "unreact" },
            Some(*target),
            vec![Node::Emote(emote.clone())],
        ),
        Content::Poke { target } => Columns {
            target_identity: Some(target.0),
            ..event("poke", None, Vec::new())
        },
    }
}

fn content(
    event: Option<&str>,
    reply_to: Option<i64>,
    target: Option<i64>,
    target_identity: Option<i64>,
    nodes: Vec<Node>,
) -> sqlx::Result<Content> {
    let target = || {
        target
            .map(MessageId)
            .ok_or_else(|| unknown("event target", "none"))
    };
    Ok(match event {
        None => Content::Message {
            reply_to: reply_to.map(MessageId),
            nodes,
        },
        Some("edit") => Content::Edit {
            target: target()?,
            nodes,
        },
        Some("unsend") => Content::Unsend { target: target()? },
        Some(event @ ("react" | "unreact")) => {
            let Some(Node::Emote(emote)) = nodes.into_iter().next() else {
                return Err(unknown("reaction", "without an emote"));
            };
            Content::React {
                target: target()?,
                emote,
                added: event == "react",
            }
        }
        Some("poke") => Content::Poke {
            target: target_identity
                .map(IdentityId)
                .ok_or_else(|| unknown("poke target", "none"))?,
        },
        Some(other) => return Err(unknown("event", other)),
    })
}

pub async fn insert(conn: &mut PgConnection, new: &NewMessage<'_>) -> sqlx::Result<MessageId> {
    let columns = columns(new.content, new.command);
    let id = sqlx::query_scalar!(
        r#"
        insert into messages (
            conversation_id, endpoint_id, sender_identity_id, sender_name, sender_role,
            native_id, sent_at, received_at, kind, event, reply_to_id, target_id,
            target_identity_id, nodes, raw, text, turn_id, segment
        ) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18)
        returning id
        "#,
        new.conversation.0,
        new.endpoint.0,
        new.sender.identity.0,
        new.sender.name,
        new.sender.role.map(role_name),
        new.native_id,
        new.sent_at,
        new.received_at,
        columns.kind,
        columns.event,
        columns.reply_to,
        columns.target,
        columns.target_identity,
        Json(&columns.nodes) as _,
        new.raw,
        new.text,
        new.turn.map(|turn| turn.0),
        new.segment
    )
    .fetch_one(conn)
    .await?;
    Ok(MessageId(id))
}

/// The last row of the conversation's timeline.
pub async fn head(
    conn: &mut PgConnection,
    conversation: ConversationId,
) -> sqlx::Result<Option<MessageId>> {
    let id = sqlx::query_scalar!(
        "select max(id) from messages where conversation_id = $1",
        conversation.0
    )
    .fetch_one(conn)
    .await?;
    Ok(id.map(MessageId))
}

struct Raw {
    id: i64,
    conversation_id: i64,
    endpoint_id: i64,
    sender_identity_id: i64,
    sender_name: String,
    sender_role: Option<String>,
    sent_at: DateTime<Utc>,
    kind: String,
    event: Option<String>,
    reply_to_id: Option<i64>,
    target_id: Option<i64>,
    target_identity_id: Option<i64>,
    nodes: Json<Vec<Node>>,
    raw: serde_json::Value,
    turn_id: Option<i64>,
}

impl Raw {
    fn row(self) -> sqlx::Result<Row> {
        Ok(Row {
            message: Message {
                id: MessageId(self.id),
                conversation: ConversationId(self.conversation_id),
                sender: Sender {
                    identity: IdentityId(self.sender_identity_id),
                    name: self.sender_name,
                    role: role(self.sender_role)?,
                },
                at: self.sent_at,
                content: content(
                    self.event.as_deref(),
                    self.reply_to_id,
                    self.target_id,
                    self.target_identity_id,
                    self.nodes.0,
                )?,
                turn: self.turn_id.map(TurnId),
                raw: self.raw,
            },
            endpoint: EndpointId(self.endpoint_id),
            command: self.kind == "command",
        })
    }
}

/// Rows after `after` up to `upto`, in timeline order.
pub async fn rows(
    conn: &mut PgConnection,
    conversation: ConversationId,
    after: Option<MessageId>,
    upto: MessageId,
) -> sqlx::Result<Vec<Row>> {
    sqlx::query_as!(
        Raw,
        r#"
        select m.id, m.conversation_id, m.endpoint_id, m.sender_identity_id, m.sender_name,
               m.sender_role, m.sent_at, m.kind, m.event, m.reply_to_id, m.target_id,
               m.target_identity_id, m.nodes as "nodes: Json<Vec<Node>>", m.raw, m.turn_id
        from messages m
        where m.conversation_id = $1 and m.id > $2 and m.id <= $3
        order by m.id
        "#,
        conversation.0,
        after.map_or(0, |id| id.0),
        upto.0
    )
    .fetch_all(conn)
    .await?
    .into_iter()
    .map(Raw::row)
    .collect()
}

/// One row, if it is on this conversation's timeline.
pub async fn row(
    conn: &mut PgConnection,
    conversation: ConversationId,
    id: MessageId,
) -> sqlx::Result<Option<Row>> {
    let previous = MessageId(id.0 - 1);
    Ok(rows(conn, conversation, Some(previous), id).await?.pop())
}

/// The row a platform id names in this endpoint.
pub async fn by_native_id(
    conn: &mut PgConnection,
    endpoint: EndpointId,
    native_id: &str,
) -> sqlx::Result<Option<MessageId>> {
    let id = sqlx::query_scalar!(
        r#"
        select id from messages where endpoint_id = $1 and native_id = $2
        "#,
        endpoint.0,
        native_id
    )
    .fetch_optional(conn)
    .await?;
    Ok(id.map(MessageId))
}

#[cfg(test)]
mod tests;
