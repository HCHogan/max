//! What a picture or sticker shows, in words. The caption worker is the
//! only writer; a file gets one row, ever. See "媒体".

use std::collections::{BTreeMap, HashSet};

use chrono::{DateTime, Utc};
use max_core::ids::MessageId;
use max_core::message::{MediaKind, Node, media};
use sqlx::PgConnection;
use sqlx::types::Json;

/// Which prompt a caption was written with.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    Image,
    Sticker,
}

impl Kind {
    /// What a medium of this kind is captioned as; None for what isn't a
    /// picture.
    pub fn of(kind: MediaKind) -> Option<Self> {
        match kind {
            MediaKind::Image => Some(Self::Image),
            MediaKind::Sticker => Some(Self::Sticker),
            MediaKind::Video | MediaKind::Audio | MediaKind::File => None,
        }
    }

    fn word(self) -> &'static str {
        match self {
            Self::Image => "image",
            Self::Sticker => "sticker",
        }
    }
}

pub struct Caption<'a> {
    pub sha256: &'a str,
    pub kind: Kind,
    /// Empty when the model gave up.
    pub text: &'a str,
    /// A sticker not to send.
    pub skip: bool,
    pub model: Option<&'a str>,
    pub at: DateTime<Utc>,
}

/// Writes `caption`, unless the file has one: false then.
pub async fn write(conn: &mut PgConnection, caption: &Caption<'_>) -> sqlx::Result<bool> {
    let written = sqlx::query!(
        "insert into media_captions (sha256, kind, text, skip, model, created_at)
         values ($1, $2, $3, $4, $5, $6)
         on conflict (sha256) do nothing",
        caption.sha256,
        caption.kind.word(),
        caption.text,
        caption.skip,
        caption.model,
        caption.at
    )
    .execute(conn)
    .await?;
    Ok(written.rows_affected() == 1)
}

pub async fn exists(conn: &mut PgConnection, sha256: &str) -> sqlx::Result<bool> {
    let found = sqlx::query_scalar!(
        r#"select exists (select 1 from media_captions where sha256 = $1) as "exists!""#,
        sha256
    )
    .fetch_one(conn)
    .await?;
    Ok(found)
}

/// A picture without a caption, and the first message it came in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Uncaptioned {
    pub message: MessageId,
    pub ordinal: u16,
    pub sha256: String,
    /// A picture or a sticker, as that message has it.
    pub kind: MediaKind,
}

/// The pictures first seen since `since` that have no caption: what the
/// worker missed while it was down. One each, from the first message
/// that has it.
pub async fn uncaptioned(
    conn: &mut PgConnection,
    since: DateTime<Utc>,
) -> sqlx::Result<Vec<Uncaptioned>> {
    let rows = sqlx::query!(
        r#"
        select mm.message_id, mm.ordinal, mm.sha256, m.nodes as "nodes: Json<Vec<Node>>"
        from message_media mm
        join media md on md.sha256 = mm.sha256
        join messages m on m.id = mm.message_id
        where md.first_seen_at >= $1 and md.model_sha256 is not null
          and not exists (select 1 from media_captions c where c.sha256 = mm.sha256)
        order by mm.message_id, mm.ordinal
        "#,
        since
    )
    .fetch_all(conn)
    .await?;
    let mut seen = HashSet::new();
    Ok(rows
        .into_iter()
        .filter_map(|row| {
            let ordinal = u16::try_from(row.ordinal).ok()?;
            let (_, _, meta) = media(&row.nodes.0).find(|(n, _, _)| *n == ordinal)?;
            let kind = meta.kind;
            Kind::of(kind)?;
            seen.insert(row.sha256.clone()).then_some(Uncaptioned {
                message: MessageId(row.message_id),
                ordinal,
                sha256: row.sha256,
                kind,
            })
        })
        .collect())
}

/// The captions of the media of `messages`, by message and ordinal; the
/// empty ones of a model that gave up are left out.
pub async fn of_messages(
    conn: &mut PgConnection,
    messages: &[MessageId],
) -> sqlx::Result<BTreeMap<(MessageId, u16), String>> {
    let ids: Vec<i64> = messages.iter().map(|id| id.0).collect();
    let rows = sqlx::query!(
        "select mm.message_id, mm.ordinal, c.text
         from message_media mm join media_captions c on c.sha256 = mm.sha256
         where mm.message_id = any($1) and c.text <> ''",
        &ids
    )
    .fetch_all(conn)
    .await?;
    Ok(rows
        .into_iter()
        .filter_map(|row| {
            let ordinal = u16::try_from(row.ordinal).ok()?;
            Some(((MessageId(row.message_id), ordinal), row.text))
        })
        .collect())
}

#[cfg(test)]
mod tests;
