//! The content store's index: what was downloaded, and for which message.
//! The download worker is the only writer of both tables; see "媒体".

use chrono::{DateTime, Utc};
use max_core::ids::MessageId;
use max_core::message::{MediaRef, Node, media};
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
    /// The ordinals and addresses not downloaded yet.
    pub remote: Vec<(u16, String)>,
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
    .execute(&mut *tx)
    .await?;
    sqlx::query!(
        "insert into message_media (message_id, ordinal, sha256) values ($1, $2, $3)
         on conflict do nothing",
        message.0,
        i16::try_from(ordinal).unwrap_or(i16::MAX),
        blob.sha256
    )
    .execute(&mut *tx)
    .await?;
    tx.commit().await
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
                .filter_map(|(n, media, _)| match media {
                    Some(MediaRef::Remote(url)) => Some((n, url.clone())),
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
