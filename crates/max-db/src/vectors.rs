//! Vectors of what rows say, for `history`'s search by meaning:
//! one for each chat row that says something. The recall vector worker
//! writes them; `recall` reads them. As with the stickers', each keeps the
//! model that made it, and another model's don't count. See "召回".

use chrono::{DateTime, Utc};
use max_core::ids::{ConversationId, MessageId};
use sqlx::{Connection, PgConnection};

/// A text to embed, or a vector of it: the row's, and its conversation.
pub type Of<T> = (MessageId, ConversationId, T);

/// Up to `limit` chat rows, newest first from before `after`, that should
/// have a vector by `model` and have none: those whose text, without the
/// handles, is at least four characters. Shorter rows say too little to
/// be found by; the words in them are found as written.
pub async fn unembedded(
    conn: &mut PgConnection,
    model: &str,
    after: Option<MessageId>,
    limit: i64,
) -> sqlx::Result<Vec<MessageId>> {
    let before = after.map_or(i64::MAX, |id| id.0);
    let ids = sqlx::query_scalar!(
        "select m.id from messages m
         where m.id < $2 and m.kind = 'chat' and char_length(recall_text(m.text)) >= 4
           and not exists (select 1 from message_embeddings e
                           where e.message_id = m.id and e.model = $1)
         order by m.id desc
         limit $3",
        model,
        before,
        limit
    )
    .fetch_all(&mut *conn)
    .await?;
    Ok(ids.into_iter().map(MessageId).collect())
}

/// What to embed of `ids`: the rows that should have a vector by `model`
/// and have none, their text without the handles.
pub async fn to_embed(
    conn: &mut PgConnection,
    model: &str,
    ids: &[MessageId],
) -> sqlx::Result<Vec<Of<String>>> {
    let rows: Vec<i64> = ids.iter().map(|id| id.0).collect();
    let mut texts = Vec::new();
    if !rows.is_empty() {
        let found = sqlx::query!(
            r#"
            select m.id, m.conversation_id, recall_text(m.text) as "text!"
            from messages m
            where m.id = any($2) and m.kind = 'chat' and char_length(recall_text(m.text)) >= 4
              and not exists (select 1 from message_embeddings e
                              where e.message_id = m.id and e.model = $1)
            order by m.id desc
            "#,
            model,
            &rows
        )
        .fetch_all(&mut *conn)
        .await?;
        texts.extend(found.into_iter().map(|row| {
            let id = MessageId(row.id);
            (id, ConversationId(row.conversation_id), row.text)
        }));
    }
    Ok(texts)
}

/// Writes the vectors, together, over any by another model.
pub async fn write(
    conn: &mut PgConnection,
    model: &str,
    vectors: &[Of<Vec<f32>>],
    at: DateTime<Utc>,
) -> sqlx::Result<()> {
    let mut tx = conn.begin().await?;
    for (id, conversation, vector) in vectors {
        sqlx::query!(
            "insert into message_embeddings
                 (message_id, conversation_id, model, embedding, created_at)
             values ($1, $2, $3, $4::float4[]::halfvec, $5)
             on conflict (message_id) do update
             set model = excluded.model, embedding = excluded.embedding,
                 created_at = excluded.created_at",
            id.0,
            conversation.0,
            model,
            vector.as_slice() as &[f32],
            at
        )
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await
}

#[cfg(test)]
mod tests;
