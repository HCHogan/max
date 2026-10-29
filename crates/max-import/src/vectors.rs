//! The sticker library's old vectors, for the sticker captions imported:
//! bge-m3's, which the embedding worker would make the same again. Only
//! where the old vector was made from the very text maxx has, as the old
//! table's hash of it says; the rest the worker embeds. A file with a
//! vector keeps it, so this can run again, and while maxx serves. See
//! "导入".

use chrono::{DateTime, Utc};
use color_eyre::eyre::Result;
use max_db::PgConnection;
use max_db::embeddings::DIMENSIONS;
use tracing::info;

/// An old vector to write: the file, the model, the vector as pgvector's
/// text, and when it was made.
type Vector = (String, String, String, DateTime<Utc>);

pub async fn import(old: &mut PgConnection, new: &mut PgConnection) -> Result<()> {
    // The captions the worker would embed, with the hash the old table
    // keeps of the text it embedded.
    let wanted: Vec<(String, String)> = sqlx::query_as(
        "select c.sha256, encode(sha256(convert_to(c.text, 'UTF8')), 'hex')
         from media_captions c
         where c.kind = 'sticker' and not c.skip and c.text <> ''
           and not exists (select 1 from caption_embeddings e where e.sha256 = c.sha256)",
    )
    .fetch_all(&mut *new)
    .await?;
    let (files, hashes): (Vec<String>, Vec<String>) = wanted.into_iter().unzip();
    let vectors: Vec<Vector> = sqlx::query_as(
        "select s.sha256, s.embedding_model, s.embedding::text, s.embedding_updated_at
         from stickers s
         join unnest($1::text[], $2::text[]) as w (sha256, hash)
           on w.sha256 = s.sha256 and w.hash = s.embedding_content_hash
         where s.embedding_dimensions = $3",
    )
    .bind(&files)
    .bind(&hashes)
    .bind(i32::try_from(DIMENSIONS)?)
    .fetch_all(&mut *old)
    .await?;
    let written = sqlx::query(
        "insert into caption_embeddings (sha256, model, embedding, created_at)
         select sha256, model, embedding::vector, at
         from unnest($1::text[], $2::text[], $3::text[], $4::timestamptz[])
              as v (sha256, model, embedding, at)
         on conflict (sha256) do nothing",
    )
    .bind(vectors.iter().map(|v| v.0.as_str()).collect::<Vec<_>>())
    .bind(vectors.iter().map(|v| v.1.as_str()).collect::<Vec<_>>())
    .bind(vectors.iter().map(|v| v.2.as_str()).collect::<Vec<_>>())
    .bind(vectors.iter().map(|v| v.3).collect::<Vec<_>>())
    .execute(&mut *new)
    .await?;
    info!(
        without = files.len(),
        old = vectors.len(),
        written = written.rows_affected(),
        "sticker vectors"
    );
    Ok(())
}
