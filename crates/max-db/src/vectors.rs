//! Vectors of what rows and summaries say, for `context_search`'s search
//! by meaning: one for each chat row that says something, one for each
//! active summary. The recall vector worker writes them; `recall` reads
//! them. As with the stickers', each keeps the model that made it, and
//! another model's don't count. See "召回".

use chrono::{DateTime, Utc};
use max_core::ids::{ConversationId, MessageId, SummaryId};
use sqlx::{Connection, PgConnection};

/// What a vector is of.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Key {
    Message(MessageId),
    Summary(SummaryId),
}

/// A text to embed, or a vector of it, and its conversation.
pub type Of<T> = (Key, ConversationId, T);

/// Up to `limit` of what should have a vector by `model` and has none,
/// in this order, from after `after`: active summaries, then chat rows
/// whose text, without the handles, is at least four characters, each
/// newest first. Shorter rows say too little to be found by; the words in
/// them are found as written.
pub async fn unembedded(
    conn: &mut PgConnection,
    model: &str,
    after: Option<Key>,
    limit: i64,
) -> sqlx::Result<Vec<Key>> {
    let mut keys = Vec::new();
    if !matches!(after, Some(Key::Message(_))) {
        let before = match after {
            Some(Key::Summary(id)) => id.0,
            _ => i64::MAX,
        };
        let ids = sqlx::query_scalar!(
            "select s.id from summaries s
             where s.id < $2 and s.status = 'active'
               and not exists (select 1 from summary_embeddings e
                               where e.summary_id = s.id and e.model = $1)
             order by s.id desc
             limit $3",
            model,
            before,
            limit
        )
        .fetch_all(&mut *conn)
        .await?;
        keys.extend(ids.into_iter().map(|id| Key::Summary(SummaryId(id))));
    }
    let room = limit - i64::try_from(keys.len()).unwrap_or(limit);
    if room > 0 {
        let before = match after {
            Some(Key::Message(id)) => id.0,
            _ => i64::MAX,
        };
        let ids = sqlx::query_scalar!(
            "select m.id from messages m
             where m.id < $2 and m.kind = 'chat' and char_length(recall_text(m.text)) >= 4
               and not exists (select 1 from message_embeddings e
                               where e.message_id = m.id and e.model = $1)
             order by m.id desc
             limit $3",
            model,
            before,
            room
        )
        .fetch_all(&mut *conn)
        .await?;
        keys.extend(ids.into_iter().map(|id| Key::Message(MessageId(id))));
    }
    Ok(keys)
}

/// What to embed of `keys`: those that should have a vector by `model`
/// and have none. A row's text without the handles; a summary's title and
/// full level.
pub async fn to_embed(
    conn: &mut PgConnection,
    model: &str,
    keys: &[Key],
) -> sqlx::Result<Vec<Of<String>>> {
    let (mut rows, mut summaries) = (Vec::new(), Vec::new());
    for key in keys {
        match key {
            Key::Message(id) => rows.push(id.0),
            Key::Summary(id) => summaries.push(id.0),
        }
    }
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
            let key = Key::Message(MessageId(row.id));
            (key, ConversationId(row.conversation_id), row.text)
        }));
    }
    if !summaries.is_empty() {
        let found = sqlx::query!(
            r#"
            select s.id, s.conversation_id, concat_ws(E'\n', nullif(s.title, ''), s.p1) as "text!"
            from summaries s
            where s.id = any($2) and s.status = 'active'
              and not exists (select 1 from summary_embeddings e
                              where e.summary_id = s.id and e.model = $1)
            order by s.id desc
            "#,
            model,
            &summaries
        )
        .fetch_all(&mut *conn)
        .await?;
        texts.extend(found.into_iter().map(|row| {
            let key = Key::Summary(SummaryId(row.id));
            (key, ConversationId(row.conversation_id), row.text)
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
    for (key, conversation, vector) in vectors {
        let vector = vector.as_slice();
        match key {
            Key::Message(id) => {
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
                    vector as &[f32],
                    at
                )
                .execute(&mut *tx)
                .await?
            }
            Key::Summary(id) => {
                sqlx::query!(
                    "insert into summary_embeddings
                         (summary_id, conversation_id, model, embedding, created_at)
                     values ($1, $2, $3, $4::float4[]::halfvec, $5)
                     on conflict (summary_id) do update
                     set model = excluded.model, embedding = excluded.embedding,
                         created_at = excluded.created_at",
                    id.0,
                    conversation.0,
                    model,
                    vector as &[f32],
                    at
                )
                .execute(&mut *tx)
                .await?
            }
        };
    }
    tx.commit().await
}

#[cfg(test)]
mod tests;
