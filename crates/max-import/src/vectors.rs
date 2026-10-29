//! The old vectors, all bge-m3's: the sticker library's, for the sticker
//! captions imported, and recall's, of rows and summaries. A sticker's
//! only where the old vector was made from the very text maxx has, as the
//! old table's hash of it says, since the embedding worker would make the
//! same again. A row's or a summary's by id: the old text it was made from
//! was rendered otherwise, but says the same. The rest the workers embed.
//! What has a vector keeps it, so this can run again, and while maxx
//! serves. See "导入".

use chrono::{DateTime, Utc};
use color_eyre::eyre::Result;
use max_db::PgConnection;
use max_db::embeddings::DIMENSIONS;
use tracing::info;

/// Old vectors of rows read and written at a time: as text, each is some
/// 12 KB.
const CHUNK: usize = 2000;

/// An old vector to write: the file or the id, the model, the vector as
/// pgvector's text, and when it was made.
type Vector<K> = (K, String, String, DateTime<Utc>);

pub async fn import(old: &mut PgConnection, new: &mut PgConnection) -> Result<()> {
    stickers(old, new).await?;
    // The chat rows and the active summaries the recall worker would embed.
    let rows: Vec<i64> = sqlx::query_scalar(
        "select m.id from messages m
         where m.kind = 'chat' and char_length(recall_text(m.text)) >= 4
           and not exists (select 1 from message_embeddings e where e.message_id = m.id)
         order by m.id",
    )
    .fetch_all(&mut *new)
    .await?;
    let read = "select canonical_message_id, embedding_model, embedding::text, embedding_updated_at
                from messages
                where canonical_message_id = any($1) and embedding_dimensions = $2";
    let write = "insert into message_embeddings
                     (message_id, conversation_id, model, embedding, created_at)
                 select v.id, m.conversation_id, v.model, v.embedding::halfvec, v.at
                 from unnest($1::bigint[], $2::text[], $3::text[], $4::timestamptz[])
                      as v (id, model, embedding, at)
                 join messages m on m.id = v.id
                 on conflict (message_id) do nothing";
    let (found, written) = copy(old, new, &rows, read, write).await?;
    info!(without = rows.len(), old = found, written, "row vectors");

    let summaries: Vec<i64> = sqlx::query_scalar(
        "select s.id from summaries s
         where s.status = 'active'
           and not exists (select 1 from summary_embeddings e where e.summary_id = s.id)
         order by s.id",
    )
    .fetch_all(&mut *new)
    .await?;
    let read = "select id, embedding_model, embedding::text, embedding_updated_at
                from conversation_compartments
                where id = any($1) and embedding_dimensions = $2";
    let write = "insert into summary_embeddings
                     (summary_id, conversation_id, model, embedding, created_at)
                 select v.id, s.conversation_id, v.model, v.embedding::halfvec, v.at
                 from unnest($1::bigint[], $2::text[], $3::text[], $4::timestamptz[])
                      as v (id, model, embedding, at)
                 join summaries s on s.id = v.id
                 on conflict (summary_id) do nothing";
    let (found, written) = copy(old, new, &summaries, read, write).await?;
    info!(
        without = summaries.len(),
        old = found,
        written,
        "summary vectors"
    );
    Ok(())
}

/// Copies the old vectors of `ids`, a chunk at a time, each chunk on its
/// own: `read` takes the ids and the length, and gives what `write` takes
/// as four arrays. How many were found, and how many written.
async fn copy(
    old: &mut PgConnection,
    new: &mut PgConnection,
    ids: &[i64],
    read: &'static str,
    write: &'static str,
) -> Result<(usize, u64)> {
    let (mut found, mut written) = (0, 0);
    for chunk in ids.chunks(CHUNK) {
        let vectors: Vec<Vector<i64>> = sqlx::query_as(read)
            .bind(chunk)
            .bind(i32::try_from(DIMENSIONS)?)
            .fetch_all(&mut *old)
            .await?;
        found += vectors.len();
        let done = sqlx::query(write)
            .bind(vectors.iter().map(|v| v.0).collect::<Vec<_>>())
            .bind(vectors.iter().map(|v| v.1.as_str()).collect::<Vec<_>>())
            .bind(vectors.iter().map(|v| v.2.as_str()).collect::<Vec<_>>())
            .bind(vectors.iter().map(|v| v.3).collect::<Vec<_>>())
            .execute(&mut *new)
            .await?;
        written += done.rows_affected();
    }
    Ok((found, written))
}

/// The sticker captions' vectors, where the text matches.
async fn stickers(old: &mut PgConnection, new: &mut PgConnection) -> Result<()> {
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
    let vectors: Vec<Vector<String>> = sqlx::query_as(
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
