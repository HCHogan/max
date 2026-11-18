//! Vectors of what rows say, for `history`'s search by meaning:
//! one for each chat row that says something. The recall vector worker
//! writes them; `recall` reads them. As with the stickers', each keeps the
//! model that made it, and another model's don't count. See "Recall".

use chrono::{DateTime, Utc};
use max_core::ids::{ConversationId, MessageId};
use sqlx::{Connection, PgConnection};

/// Something of a row's, with the row and its conversation: its text to
/// embed, or the vector of it.
#[derive(Clone, Debug, PartialEq)]
pub struct Of<T> {
    pub message: MessageId,
    pub conversation: ConversationId,
    pub what: T,
}

impl<T> Of<T> {
    /// `what` of the same row.
    pub fn with<U>(&self, what: U) -> Of<U> {
        Of {
            message: self.message,
            conversation: self.conversation,
            what,
        }
    }
}

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
    let before = after.map_or(i64::MAX, |id| id.get());
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
    Ok(ids.into_iter().map(MessageId::new).collect())
}

/// What to embed of `ids`: the rows that should have a vector by `model`
/// and have none, their text without the handles.
pub async fn to_embed(
    conn: &mut PgConnection,
    model: &str,
    ids: &[MessageId],
) -> sqlx::Result<Vec<Of<String>>> {
    let rows: Vec<i64> = ids.iter().map(|id| id.get()).collect();
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
        texts.extend(found.into_iter().map(|row| Of {
            message: MessageId::new(row.id),
            conversation: ConversationId::new(row.conversation_id),
            what: row.text,
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
    for Of {
        message,
        conversation,
        what: vector,
    } in vectors
    {
        sqlx::query!(
            "insert into message_embeddings
                 (message_id, conversation_id, model, embedding, created_at)
             values ($1, $2, $3, $4::float4[]::halfvec, $5)
             on conflict (message_id) do update
             set model = excluded.model, embedding = excluded.embedding,
                 created_at = excluded.created_at",
            message.get(),
            conversation.get(),
            model,
            vector.as_slice() as &[f32],
            at
        )
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await
}
