//! The ledger: timeline rows and what became of what Max sent.

use chrono::{DateTime, Utc};
use max_core::ids::{ConversationId, EndpointId, IdentityId, MessageId, TurnId};
use max_core::message::{Content, Message, Node, Platform, Role, Sender};
use sqlx::PgConnection;
use sqlx::types::Json;

use crate::captions;
use crate::platform::{platform_name, role};
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
    /// The id the platform quotes it by, where that differs: QQ's msg_idx.
    pub quote_id: Option<&'a str>,
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
    /// For what Max sent to the row's endpoint: what became of it, once
    /// known.
    pub delivery: Option<Delivery>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Delivery {
    Sent,
    Failed,
    /// Max crashed before hearing back.
    Unknown,
}

/// The columns a `Content` spreads over.
struct Columns {
    kind: &'static str,
    event: Option<&'static str>,
    reply_to: Option<i64>,
    target: Option<i64>,
    nodes: Vec<Node>,
}

fn columns(content: &Content, command: bool) -> Columns {
    let event = |event, target: Option<MessageId>, nodes| Columns {
        kind: "event",
        event: Some(event),
        reply_to: None,
        target: target.map(|id| id.0),
        nodes,
    };
    match content {
        Content::Message { reply_to, nodes } => Columns {
            kind: if command { "command" } else { "chat" },
            event: None,
            reply_to: reply_to.map(|id| id.0),
            target: None,
            nodes: nodes.clone(),
        },
        Content::Edit { target, nodes } => event("edit", Some(*target), nodes.clone()),
        Content::Unsend { target } => event("unsend", Some(*target), Vec::new()),
    }
}

fn content(
    event: Option<&str>,
    reply_to: Option<i64>,
    target: Option<i64>,
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
        Some(other) => return Err(unknown("event", other)),
    })
}

pub async fn insert(conn: &mut PgConnection, new: &NewMessage<'_>) -> sqlx::Result<MessageId> {
    let columns = columns(new.content, new.command);
    let id = sqlx::query_scalar!(
        r#"
        insert into messages (
            conversation_id, endpoint_id, sender_identity_id, sender_name, sender_role,
            native_id, quote_id, sent_at, received_at, kind, event, reply_to_id, target_id,
            nodes, raw, text, turn_id, segment
        ) values (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18
        )
        returning id
        "#,
        new.conversation.0,
        new.endpoint.0,
        new.sender.identity.0,
        new.sender.name,
        new.sender.role.map(role_name),
        new.native_id,
        new.quote_id,
        new.sent_at,
        new.received_at,
        columns.kind,
        columns.event,
        columns.reply_to,
        columns.target,
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
    nodes: Json<Vec<Node>>,
    raw: serde_json::Value,
    turn_id: Option<i64>,
    delivery: Option<String>,
}

impl Raw {
    fn row(self) -> sqlx::Result<Row> {
        let delivery = match self.delivery.as_deref() {
            None => None,
            Some("sent") => Some(Delivery::Sent),
            Some("failed") => Some(Delivery::Failed),
            Some("unknown") => Some(Delivery::Unknown),
            Some(other) => return Err(unknown("delivery status", other)),
        };
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
                    self.nodes.0,
                )?,
                turn: self.turn_id.map(TurnId),
                raw: self.raw,
            },
            endpoint: EndpointId(self.endpoint_id),
            command: self.kind == "command",
            delivery,
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
    let mut rows = sqlx::query_as!(
        Raw,
        r#"
        select m.id, m.conversation_id, m.endpoint_id, m.sender_identity_id, m.sender_name,
               m.sender_role, m.sent_at, m.kind, m.event, m.reply_to_id, m.target_id,
               m.nodes as "nodes: Json<Vec<Node>>", m.raw, m.turn_id, d.status as "delivery?"
        from messages m
        left join deliveries d on d.message_id = m.id and d.endpoint_id = m.endpoint_id
        where m.conversation_id = $1 and m.id > $2 and m.id <= $3
        order by m.id
        "#,
        conversation.0,
        after.map_or(0, |id| id.0),
        upto.0
    )
    .fetch_all(&mut *conn)
    .await?
    .into_iter()
    .map(Raw::row)
    .collect::<sqlx::Result<Vec<Row>>>()?;
    captioned(conn, &mut rows).await?;
    Ok(rows)
}

/// Up to `limit` rows before `before`, in timeline order: the context the
/// classifier reads.
pub async fn recent(
    conn: &mut PgConnection,
    conversation: ConversationId,
    before: MessageId,
    limit: i64,
) -> sqlx::Result<Vec<Row>> {
    let mut rows = sqlx::query_as!(
        Raw,
        r#"
        select m.id, m.conversation_id, m.endpoint_id, m.sender_identity_id, m.sender_name,
               m.sender_role, m.sent_at, m.kind, m.event, m.reply_to_id, m.target_id,
               m.nodes as "nodes: Json<Vec<Node>>", m.raw, m.turn_id, d.status as "delivery?"
        from messages m
        left join deliveries d on d.message_id = m.id and d.endpoint_id = m.endpoint_id
        where m.conversation_id = $1 and m.id < $2
        order by m.id desc
        limit $3
        "#,
        conversation.0,
        before.0,
        limit
    )
    .fetch_all(&mut *conn)
    .await?
    .into_iter()
    .map(Raw::row)
    .collect::<sqlx::Result<Vec<Row>>>()?;
    rows.reverse();
    captioned(conn, &mut rows).await?;
    Ok(rows)
}

/// Gives the media that came without a description what the caption
/// worker wrote of them, so a row shows it wherever it's read.
async fn captioned(conn: &mut PgConnection, rows: &mut [Row]) -> sqlx::Result<()> {
    let ids: Vec<MessageId> = rows.iter().map(|row| row.message.id).collect();
    let captions = captions::of_messages(conn, &ids).await?;
    if captions.is_empty() {
        return Ok(());
    }
    for row in rows {
        let nodes = match &mut row.message.content {
            Content::Message { nodes, .. } | Content::Edit { nodes, .. } => nodes,
            Content::Unsend { .. } => continue,
        };
        let metas = nodes.iter_mut().filter_map(|node| match node {
            Node::Media { meta, .. } => Some(meta),
            _ => None,
        });
        for (ordinal, meta) in (0..).zip(metas) {
            if meta.description.is_none()
                && let Some(caption) = captions.get(&(row.message.id, ordinal))
            {
                meta.description = Some(caption.clone());
            }
        }
    }
    Ok(())
}

/// What an account said lately in an endpoint, newest first, by id and
/// rendered text: where a quote of Max's message is looked for when its
/// quote id is unknown.
pub async fn said_by(
    conn: &mut PgConnection,
    endpoint: EndpointId,
    identity: IdentityId,
    limit: i64,
) -> sqlx::Result<Vec<(MessageId, String)>> {
    let rows = sqlx::query!(
        "select id, text from messages
         where endpoint_id = $1 and sender_identity_id = $2 and kind <> 'event'
         order by id desc limit $3",
        endpoint.0,
        identity.0,
        limit
    )
    .fetch_all(conn)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| (MessageId(row.id), row.text))
        .collect())
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

/// The row a platform id names in this endpoint: someone's message, or
/// one Max sent.
pub async fn by_native_id(
    conn: &mut PgConnection,
    endpoint: EndpointId,
    native_id: &str,
) -> sqlx::Result<Option<MessageId>> {
    let id = sqlx::query_scalar!(
        r#"
        select id as "id!" from messages where endpoint_id = $1 and native_id = $2
        union all
        select message_id from deliveries where endpoint_id = $1 and native_id = $2
        limit 1
        "#,
        endpoint.0,
        native_id
    )
    .fetch_optional(conn)
    .await?;
    Ok(id.map(MessageId))
}

/// The row a quote id names in this endpoint: someone's message by its
/// own, or one Max sent by the one the platform gave back.
pub async fn by_quote_id(
    conn: &mut PgConnection,
    endpoint: EndpointId,
    quote_id: &str,
) -> sqlx::Result<Option<MessageId>> {
    let id = sqlx::query_scalar!(
        r#"
        select id as "id!" from messages where endpoint_id = $1 and quote_id = $2
        union all
        select message_id from deliveries where endpoint_id = $1 and quote_id = $2
        limit 1
        "#,
        endpoint.0,
        quote_id
    )
    .fetch_optional(conn)
    .await?;
    Ok(id.map(MessageId))
}

/// How to quote a row in its endpoint, if the platform gave a way.
pub async fn quote_id(conn: &mut PgConnection, message: MessageId) -> sqlx::Result<Option<String>> {
    let id = sqlx::query_scalar!(
        r#"
        select coalesce(m.quote_id, d.quote_id)
        from messages m
        left join deliveries d on d.message_id = m.id and d.endpoint_id = m.endpoint_id
        where m.id = $1
        "#,
        message.0
    )
    .fetch_optional(conn)
    .await?;
    Ok(id.flatten())
}

/// What the platform said when Max sent a row.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Sent<'a> {
    Delivered {
        native_id: &'a str,
        /// For quoting it, where the platform has a separate id.
        quote_id: Option<&'a str>,
    },
    Failed {
        error: &'a str,
    },
}

pub async fn record_delivery(
    conn: &mut PgConnection,
    message: MessageId,
    endpoint: EndpointId,
    sent: &Sent<'_>,
    at: DateTime<Utc>,
) -> sqlx::Result<()> {
    let (status, native_id, quote_id, error) = match sent {
        Sent::Delivered {
            native_id,
            quote_id,
        } => ("sent", Some(*native_id), *quote_id, None),
        Sent::Failed { error } => ("failed", None, None, Some(*error)),
    };
    sqlx::query!(
        "insert into deliveries (message_id, endpoint_id, status, native_id, quote_id, error, at)
         values ($1, $2, $3, $4, $5, $6, $7)",
        message.0,
        endpoint.0,
        status,
        native_id,
        quote_id,
        error,
        at
    )
    .execute(conn)
    .await?;
    Ok(())
}

/// At a sender's start: what Max committed on the platform's endpoints
/// and never heard back about is marked unknown, not sent again.
pub async fn mark_unknown(
    conn: &mut PgConnection,
    platform: Platform,
    at: DateTime<Utc>,
) -> sqlx::Result<u64> {
    let done = sqlx::query!(
        r#"
        insert into deliveries (message_id, endpoint_id, status, at)
        select m.id, m.endpoint_id, 'unknown', $2
        from messages m join endpoints e on e.id = m.endpoint_id
        where e.platform = $1 and m.sender_identity_id = e.self_identity_id
          and m.native_id is null
          and not exists (
              select from deliveries d where d.message_id = m.id and d.endpoint_id = m.endpoint_id
          )
        "#,
        platform_name(platform),
        at
    )
    .execute(conn)
    .await?;
    Ok(done.rows_affected())
}

#[cfg(test)]
mod tests;
