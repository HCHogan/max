//! Messages: what people and Max said on QQ, and recalls, under their old
//! ids. Left behind: reactions, Max's debug rows and `[silence]` records,
//! Max's messages seen again as inbound, and recalls of what didn't come
//! along. Forwarded messages fold into their container; see `nodes`.

use std::collections::{BTreeSet, HashMap, HashSet};

use chrono::{DateTime, FixedOffset, Utc};
use color_eyre::eyre::{Result, eyre};
use max_core::ids::MessageId;
use max_core::message::{Content, Node};
use max_core::render::Render;
use max_db::PgConnection;
use serde_json::Value;
use tracing::info;

use crate::nodes::{Child, Converter};
use crate::people::People;
use crate::places::Places;

/// Rows read and written at a time.
const BATCH: usize = 2000;

pub struct Messages {
    /// Where each old media node went: (old row, index in its old nodes) →
    /// (row, ordinal). A forwarded message's go to its container.
    pub media: HashMap<(i64, i32), (i64, u16)>,
}

pub async fn import(
    old: &mut PgConnection,
    new: &mut PgConnection,
    people: &People,
    places: &Places,
) -> Result<Messages> {
    let kept: HashSet<i64> = sqlx::query_scalar(
        "select m.canonical_message_id from messages m
         where m.source_platform = 'qq' and m.event_kind = 'message'
           and m.kind in ('chat', 'command')
           and m.message_origin in ('inbound', 'legacy', 'outbound')
           and not m.is_synthetic
           and not exists (
               select 1 from message_relations r
               where r.canonical_message_id = m.canonical_message_id and r.relation_kind = 'contained_in'
           )
           and not (m.message_origin = 'inbound' and m.author_principal_id = $1 and exists (
               select 1 from messages o
               where o.conversation_id = m.conversation_id and o.message_origin = 'outbound'
                 and o.rendered_text = m.rendered_text
                 and abs(extract(epoch from o.occurred_at - m.occurred_at)) < 600
           ))",
    )
    .bind(people.max.0)
    .fetch_all(&mut *old)
    .await?
    .into_iter()
    .collect();
    let recalls: Vec<(i64, i64)> = sqlx::query_as(
        "select m.canonical_message_id, r.target_canonical_message_id
         from messages m join message_relations r using (canonical_message_id)
         where m.source_platform = 'qq' and m.event_kind = 'redaction' and m.kind = 'system'
           and r.relation_kind = 'redacts' and r.target_canonical_message_id is not null",
    )
    .fetch_all(&mut *old)
    .await?;
    let recalls: HashMap<i64, i64> = recalls
        .into_iter()
        .filter(|(_, target)| kept.contains(target))
        .collect();
    let children = children(old).await?;

    let converter = Converter {
        children: &children,
        identities: &people.principal,
    };
    let render = Render {
        people: &people.principal,
        offset: FixedOffset::east_opt(8 * 3600).ok_or_else(|| eyre!("UTC+8"))?,
    };
    let converting = Converting {
        people,
        places,
        kept: &kept,
        converter: &converter,
    };
    let ids: BTreeSet<i64> = kept.iter().chain(recalls.keys()).copied().collect();
    let ids: Vec<i64> = ids.into_iter().collect();
    let mut messages = Messages {
        media: HashMap::new(),
    };
    // A reply to a later row, set once that row is in.
    let mut later = Vec::new();
    for batch in ids.chunks(BATCH) {
        let old_rows: Vec<Old> = sqlx::query_as(
            "select m.canonical_message_id, m.conversation_id, m.origin_endpoint_id,
                    m.author_principal_id, m.message_origin, m.kind, m.sender_card,
                    m.sender_nickname, m.source_native_event_id, m.occurred_at, m.received_at,
                    m.reply_to_canonical_message_id, m.canonical_content->'nodes', m.segments,
                    e.raw_payload
             from messages m
             left join lateral (
                 select raw_payload from platform_events pe
                 where pe.canonical_message_id = m.canonical_message_id and pe.raw_payload is not null
                 order by pe.event_kind = 'message' desc, pe.platform_event_id
                 limit 1
             ) e on true
             where m.canonical_message_id = any($1)
             order by m.canonical_message_id",
        )
        .bind(batch)
        .fetch_all(&mut *old)
        .await?;
        let mut rows = Rows::default();
        for row in old_rows {
            let id = row.0;
            let new = converting.row(row, recalls.get(&id).copied())?;
            if let Some(reply_to) = new.reply_to.filter(|reply_to| *reply_to >= id) {
                later.push((id, reply_to));
            }
            for (old, ordinal) in &new.media {
                messages.media.insert(*old, (id, *ordinal));
            }
            let text = render.content(&new.content);
            rows.push(new, text)?;
        }
        rows.insert(new).await?;
    }
    sqlx::query(
        "update messages m set reply_to_id = t.reply_to
         from unnest($1::bigint[], $2::bigint[]) as t (id, reply_to)
         where m.id = t.id",
    )
    .bind(later.iter().map(|(id, _)| *id).collect::<Vec<_>>())
    .bind(
        later
            .iter()
            .map(|(_, reply_to)| *reply_to)
            .collect::<Vec<_>>(),
    )
    .execute(&mut *new)
    .await?;
    info!(
        messages = kept.len(),
        recalls = recalls.len(),
        media = messages.media.len(),
        folded = children.values().map(Vec::len).sum::<usize>(),
        "messages"
    );
    Ok(messages)
}

/// Each container's forwarded messages, in order.
async fn children(old: &mut PgConnection) -> Result<HashMap<i64, Vec<Child>>> {
    let rows: Vec<(i64, i64, String, Option<Value>)> = sqlx::query_as(
        "select r.target_canonical_message_id, m.canonical_message_id,
                coalesce(nullif(btrim(m.sender_card), ''), nullif(btrim(m.sender_nickname), ''), '某人'),
                m.canonical_content->'nodes'
         from message_relations r join messages m using (canonical_message_id)
         where r.relation_kind = 'contained_in' and r.target_canonical_message_id is not null
         order by r.target_canonical_message_id, r.relation_position, m.canonical_message_id",
    )
    .fetch_all(old)
    .await?;
    let mut children: HashMap<i64, Vec<Child>> = HashMap::new();
    for (container, id, name, nodes) in rows {
        children.entry(container).or_default().push(Child {
            id,
            name,
            nodes: nodes_of(id, nodes)?,
        });
    }
    Ok(children)
}

fn nodes_of(id: i64, nodes: Option<Value>) -> Result<Vec<Value>> {
    match nodes {
        Some(Value::Array(nodes)) => Ok(nodes),
        other => Err(eyre!("message {id} has nodes {other:?}")),
    }
}

type Old = (
    i64,
    i64,
    i64,
    i64,
    String,
    String,
    Option<String>,
    Option<String>,
    String,
    DateTime<Utc>,
    DateTime<Utc>,
    Option<i64>,
    Option<Value>,
    Value,
    Option<Value>,
);

struct Converting<'a> {
    people: &'a People,
    places: &'a Places,
    kept: &'a HashSet<i64>,
    converter: &'a Converter<'a>,
}

/// A row as maxx stores it, but for the rendered text.
struct New {
    id: i64,
    conversation: i64,
    endpoint: i64,
    sender: i64,
    name: String,
    role: Option<String>,
    native_id: Option<String>,
    sent_at: DateTime<Utc>,
    received_at: DateTime<Utc>,
    command: bool,
    reply_to: Option<i64>,
    content: Content,
    raw: Value,
    media: Vec<((i64, i32), u16)>,
}

impl Converting<'_> {
    fn row(&self, old: Old, recalls: Option<i64>) -> Result<New> {
        let (id, conversation, endpoint, author, origin, kind, card, nickname, native_id) = (
            old.0, old.1, old.2, old.3, old.4, old.5, old.6, old.7, old.8,
        );
        let (sent_at, received_at, reply_to, nodes, segments, event) =
            (old.9, old.10, old.11, old.12, old.13, old.14);
        let is_max = author == self.people.max.0;
        let nonblank = |name: Option<String>| name.filter(|name| !name.trim().is_empty());
        let own = match origin.as_str() {
            "legacy" => nonblank(card).or(nonblank(nickname)),
            _ => nonblank(nickname),
        };
        let name = own
            .or_else(|| self.people.name.get(&author).cloned())
            .unwrap_or_else(|| "某人".to_owned());
        let role = event
            .as_ref()
            .and_then(|event| event["sender"]["role"].as_str())
            .filter(|role| ["owner", "admin", "member"].contains(role))
            .filter(|_| origin == "inbound" && self.places.groups.contains(&conversation))
            .map(str::to_owned);
        let (content, media) = match recalls {
            Some(target) => (
                Content::Unsend {
                    target: MessageId(target),
                },
                Vec::new(),
            ),
            None => {
                let converted = self.converter.convert(id, &nodes_of(id, nodes)?)?;
                let reply_to = reply_to.filter(|reply_to| self.kept.contains(reply_to));
                let content = Content::Message {
                    reply_to: reply_to.map(MessageId),
                    nodes: converted.nodes,
                };
                (content, converted.media)
            }
        };
        let raw = match (event, recalls) {
            (Some(event), _) => event,
            (None, Some(_)) => Value::Object(Default::default()),
            (None, None) => segments,
        };
        Ok(New {
            id,
            conversation,
            endpoint: *self
                .places
                .endpoint
                .get(&endpoint)
                .ok_or_else(|| eyre!("message {id} is from endpoint {endpoint}"))?,
            sender: *self
                .people
                .identity
                .get(&author)
                .ok_or_else(|| eyre!("message {id} is by principal {author}"))?,
            name,
            role,
            // Max's platform ids belong in deliveries, which stay behind.
            native_id: (!is_max).then_some(native_id),
            sent_at,
            received_at,
            command: !is_max && kind == "command",
            reply_to: match &content {
                Content::Message { reply_to, .. } => reply_to.map(|id| id.0),
                _ => None,
            },
            content,
            raw,
            media,
        })
    }
}

/// A batch of rows, as the columns `insert` binds.
#[derive(Default)]
struct Rows {
    id: Vec<i64>,
    conversation: Vec<i64>,
    endpoint: Vec<i64>,
    sender: Vec<i64>,
    name: Vec<String>,
    role: Vec<Option<String>>,
    native_id: Vec<Option<String>>,
    sent_at: Vec<DateTime<Utc>>,
    received_at: Vec<DateTime<Utc>>,
    kind: Vec<&'static str>,
    event: Vec<Option<&'static str>>,
    reply_to: Vec<Option<i64>>,
    target: Vec<Option<i64>>,
    nodes: Vec<Value>,
    raw: Vec<Value>,
    text: Vec<String>,
}

impl Rows {
    fn push(&mut self, new: New, text: String) -> Result<()> {
        let (kind, event, target, nodes): (_, _, _, &[Node]) = match &new.content {
            Content::Message { nodes, .. } => {
                let kind = if new.command { "command" } else { "chat" };
                (kind, None, None, nodes)
            }
            Content::Unsend { target } => ("event", Some("unsend"), Some(target.0), &[]),
            Content::Edit { .. } => unreachable!("the old rows have no edits"),
        };
        self.id.push(new.id);
        self.conversation.push(new.conversation);
        self.endpoint.push(new.endpoint);
        self.sender.push(new.sender);
        self.name.push(new.name);
        self.role.push(new.role);
        self.native_id.push(new.native_id);
        self.sent_at.push(new.sent_at);
        self.received_at.push(new.received_at);
        self.kind.push(kind);
        self.event.push(event);
        // Set later when the row it replies to isn't in yet.
        self.reply_to
            .push(new.reply_to.filter(|reply_to| *reply_to < new.id));
        self.target.push(target);
        self.nodes.push(serde_json::to_value(nodes)?);
        self.raw.push(new.raw);
        self.text.push(text);
        Ok(())
    }

    async fn insert(self, new: &mut PgConnection) -> Result<()> {
        sqlx::query(
            "insert into messages (id, conversation_id, endpoint_id, sender_identity_id,
                 sender_name, sender_role, native_id, sent_at, received_at, kind, event,
                 reply_to_id, target_id, nodes, raw, text)
             select * from unnest($1::bigint[], $2::bigint[], $3::bigint[], $4::bigint[],
                 $5::text[], $6::text[], $7::text[], $8::timestamptz[], $9::timestamptz[],
                 $10::text[], $11::text[], $12::bigint[], $13::bigint[], $14::jsonb[],
                 $15::jsonb[], $16::text[])",
        )
        .bind(self.id)
        .bind(self.conversation)
        .bind(self.endpoint)
        .bind(self.sender)
        .bind(self.name)
        .bind(self.role)
        .bind(self.native_id)
        .bind(self.sent_at)
        .bind(self.received_at)
        .bind(self.kind)
        .bind(self.event)
        .bind(self.reply_to)
        .bind(self.target)
        .bind(self.nodes)
        .bind(self.raw)
        .bind(self.text)
        .execute(new)
        .await?;
        Ok(())
    }
}
