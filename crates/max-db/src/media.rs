//! The content store's index: what was downloaded, and for which message.
//! The download worker records what comes in; a picture Max sends again
//! is linked to its new row when that is committed. See "媒体".

use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use max_core::ids::{ConversationId, MessageId};
use max_core::message::{MediaKind, MediaRef, Node, media};
use sqlx::types::Json;
use sqlx::{Connection, PgConnection};

/// Downloaded bytes, as the content store holds them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Blob {
    /// Lowercase hex.
    pub sha256: String,
    pub mime: Option<String>,
    pub size: u64,
    pub width: Option<u32>,
    pub height: Option<u32>,
    /// What the model is sent of a picture: these bytes, or a smaller
    /// copy. None for what isn't a picture.
    pub model_sha256: Option<String>,
}

/// A message with media still to download.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pending {
    pub message: MessageId,
    /// The ordinals, kinds and addresses not downloaded yet.
    pub remote: Vec<(u16, MediaKind, String)>,
}

/// Records that the `ordinal`-th media of `message` is `blob`. The media
/// row is the first sighting's; a second message with the same bytes only
/// adds its link.
pub async fn record(
    conn: &mut PgConnection,
    message: MessageId,
    ordinal: u16,
    blob: &Blob,
    at: DateTime<Utc>,
) -> sqlx::Result<()> {
    let mut tx = conn.begin().await?;
    remember(&mut tx, blob, at).await?;
    link(&mut tx, message, ordinal, &blob.sha256).await?;
    tx.commit().await
}

/// Records a file the store has, unless it is known: a message links to
/// it later.
pub async fn remember(conn: &mut PgConnection, blob: &Blob, at: DateTime<Utc>) -> sqlx::Result<()> {
    sqlx::query!(
        "insert into media (sha256, mime, size, width, height, model_sha256, first_seen_at)
         values ($1, $2, $3, $4, $5, $6, $7)
         on conflict (sha256) do nothing",
        blob.sha256,
        blob.mime,
        i64::try_from(blob.size).unwrap_or(i64::MAX),
        blob.width
            .map(|width| i32::try_from(width).unwrap_or(i32::MAX)),
        blob.height
            .map(|height| i32::try_from(height).unwrap_or(i32::MAX)),
        blob.model_sha256,
        at
    )
    .execute(conn)
    .await?;
    Ok(())
}

/// Records that the `ordinal`-th media of `message` is a file the store
/// has.
pub async fn link(
    conn: &mut PgConnection,
    message: MessageId,
    ordinal: u16,
    sha256: &str,
) -> sqlx::Result<()> {
    sqlx::query!(
        "insert into message_media (message_id, ordinal, sha256) values ($1, $2, $3)
         on conflict do nothing",
        message.0,
        i16::try_from(ordinal).unwrap_or(i16::MAX),
        sha256
    )
    .execute(conn)
    .await?;
    Ok(())
}

/// A row's medium that the store has, to send again.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Stored {
    /// The row's.
    pub conversation: ConversationId,
    /// As the row's node has it.
    pub kind: MediaKind,
    pub sha256: String,
    pub mime: Option<String>,
    pub size: u64,
}

/// The `ordinal`-th medium of `message`, in any conversation, if it was
/// downloaded.
pub async fn stored(
    conn: &mut PgConnection,
    message: MessageId,
    ordinal: u16,
) -> sqlx::Result<Option<Stored>> {
    let row = sqlx::query!(
        r#"
        select m.conversation_id, m.nodes as "nodes: Json<Vec<Node>>", md.sha256, md.mime, md.size
        from messages m
        join message_media mm on mm.message_id = m.id
        join media md on md.sha256 = mm.sha256
        where m.id = $1 and mm.ordinal = $2
        "#,
        message.0,
        i16::try_from(ordinal).unwrap_or(i16::MAX)
    )
    .fetch_optional(conn)
    .await?;
    Ok(row.and_then(|row| {
        let (_, _, meta) = media(&row.nodes.0).find(|(n, _, _)| *n == ordinal)?;
        Some(Stored {
            conversation: ConversationId(row.conversation_id),
            kind: meta.kind,
            sha256: row.sha256,
            mime: row.mime,
            size: u64::try_from(row.size).unwrap_or_default(),
        })
    }))
}

/// A message's downloaded media, by ordinal.
pub async fn downloaded(
    conn: &mut PgConnection,
    message: MessageId,
) -> sqlx::Result<Vec<(u16, String)>> {
    let rows = sqlx::query!(
        "select ordinal, sha256 from message_media where message_id = $1 order by ordinal",
        message.0
    )
    .fetch_all(conn)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| (u16::try_from(row.ordinal).unwrap_or_default(), row.sha256))
        .collect())
}

/// For each of `messages` there is: when it came in, and the version made
/// for the model of each picture of it downloaded so far, by ordinal.
pub async fn for_model(
    conn: &mut PgConnection,
    messages: &[MessageId],
) -> sqlx::Result<BTreeMap<MessageId, (DateTime<Utc>, BTreeMap<u16, String>)>> {
    let ids: Vec<i64> = messages.iter().map(|id| id.0).collect();
    let rows = sqlx::query!(
        r#"
        select m.id as "id!", m.received_at as "received_at!", mm.ordinal as "ordinal?",
               md.model_sha256 as "model_sha256?"
        from messages m
        left join message_media mm on mm.message_id = m.id
        left join media md on md.sha256 = mm.sha256
        where m.id = any($1)
        "#,
        &ids
    )
    .fetch_all(conn)
    .await?;
    let mut found = BTreeMap::new();
    for row in rows {
        let (_, pictures) = found
            .entry(MessageId(row.id))
            .or_insert_with(|| (row.received_at, BTreeMap::new()));
        if let (Some(ordinal), Some(sha256)) = (row.ordinal, row.model_sha256) {
            pictures.insert(u16::try_from(ordinal).unwrap_or_default(), sha256);
        }
    }
    Ok(found)
}

/// Messages received since `since` whose remote media aren't all
/// downloaded: what the worker missed while it was down.
pub async fn pending(conn: &mut PgConnection, since: DateTime<Utc>) -> sqlx::Result<Vec<Pending>> {
    let rows = sqlx::query!(
        r#"
        select m.id, m.nodes as "nodes: Json<Vec<Node>>",
               array(select ordinal from message_media where message_id = m.id) as "done!"
        from messages m
        where m.received_at >= $1
          and jsonb_path_exists(m.nodes, '$[*] ? (@.type == "media" && exists(@.media.remote))')
        order by m.id
        "#,
        since
    )
    .fetch_all(conn)
    .await?;
    Ok(rows
        .into_iter()
        .filter_map(|row| {
            let remote: Vec<_> = media(&row.nodes.0)
                .filter(|(n, _, _)| !row.done.contains(&i16::try_from(*n).unwrap_or(i16::MAX)))
                .filter_map(|(n, media, meta)| match media {
                    Some(MediaRef::Remote(url)) => Some((n, meta.kind, url.clone())),
                    _ => None,
                })
                .collect();
            (!remote.is_empty()).then_some(Pending {
                message: MessageId(row.id),
                remote,
            })
        })
        .collect())
}

#[cfg(test)]
mod tests;
