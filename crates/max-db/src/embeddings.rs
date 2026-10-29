//! Vectors of what captions say, for the sticker library: the embedding
//! worker writes one per sticker caption, and `find_stickers` looks for
//! the nearest. Each vector keeps the model that made it, and only one
//! model's are compared. See "发图".

use chrono::{DateTime, Utc};
use max_core::ids::MessageId;
use sqlx::PgConnection;

/// How long a vector is: the column's, bge-m3's.
pub const DIMENSIONS: usize = 1024;

/// The sticker captions with no vector by `model`, newest first: what the
/// worker missed, or all of them after a change of model.
pub async fn unembedded(conn: &mut PgConnection, model: &str) -> sqlx::Result<Vec<String>> {
    sqlx::query_scalar!(
        "select c.sha256 from media_captions c
         where c.kind = 'sticker' and not c.skip and c.text <> ''
           and not exists (select 1 from caption_embeddings e
                           where e.sha256 = c.sha256 and e.model = $1)
         order by c.created_at desc",
        model
    )
    .fetch_all(conn)
    .await
}

/// The caption to embed for the file `sha256`: a sticker's that isn't
/// skipped or empty, and has no vector by `model` yet.
pub async fn to_embed(
    conn: &mut PgConnection,
    sha256: &str,
    model: &str,
) -> sqlx::Result<Option<String>> {
    sqlx::query_scalar!(
        "select c.text from media_captions c
         where c.sha256 = $1 and c.kind = 'sticker' and not c.skip and c.text <> ''
           and not exists (select 1 from caption_embeddings e
                           where e.sha256 = c.sha256 and e.model = $2)",
        sha256,
        model
    )
    .fetch_optional(conn)
    .await
}

/// Writes the vector of the caption of `sha256`, over one by another
/// model.
pub async fn write(
    conn: &mut PgConnection,
    sha256: &str,
    model: &str,
    vector: &[f32],
    at: DateTime<Utc>,
) -> sqlx::Result<()> {
    sqlx::query!(
        "insert into caption_embeddings (sha256, model, embedding, created_at)
         values ($1, $2, $3::float4[]::vector, $4)
         on conflict (sha256) do update
         set model = excluded.model, embedding = excluded.embedding,
             created_at = excluded.created_at",
        sha256,
        model,
        vector as &[f32],
        at
    )
    .execute(conn)
    .await?;
    Ok(())
}

/// A sticker in the library: the last row that has it as a sticker, which
/// of the row's media it is, and its caption.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Sticker {
    pub message: MessageId,
    pub ordinal: u16,
    pub caption: String,
}

/// The `limit` stickers whose captions are nearest `query` by cosine
/// distance, nearest first, one per file: those `model` embedded, not
/// skipped, and some row in any conversation has as a sticker.
pub async fn nearest(
    conn: &mut PgConnection,
    model: &str,
    query: &[f32],
    limit: u8,
) -> sqlx::Result<Vec<Sticker>> {
    let rows = sqlx::query!(
        r#"
        select last.message_id as "message_id!", last.ordinal as "ordinal!", near.text as "text!"
        from (
            select c.sha256, c.text, e.embedding <=> $2::float4[]::vector as distance
            from caption_embeddings e join media_captions c on c.sha256 = e.sha256
            where e.model = $1 and c.kind = 'sticker' and not c.skip and c.text <> ''
        ) near
        cross join lateral (
            select mm.message_id, mm.ordinal
            from message_media mm join messages m on m.id = mm.message_id
            where mm.sha256 = near.sha256
              and (jsonb_path_query_array(m.nodes, '$[*] ? (@.type == "media").meta.kind')
                   ->> mm.ordinal::int) = 'sticker'
            order by mm.message_id desc
            limit 1
        ) last
        order by near.distance
        limit $3
        "#,
        model,
        query as &[f32],
        i64::from(limit)
    )
    .fetch_all(conn)
    .await?;
    Ok(rows
        .into_iter()
        .filter_map(|row| {
            Some(Sticker {
                message: MessageId(row.message_id),
                ordinal: u16::try_from(row.ordinal).ok()?,
                caption: row.text,
            })
        })
        .collect())
}

#[cfg(test)]
mod tests;
