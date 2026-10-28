//! The historian's summaries. It is their only writer.

use chrono::{DateTime, Utc};
use max_core::ids::{ConversationId, MessageId, SummaryId};
use sqlx::PgConnection;

use crate::unknown;

/// A summary of the messages `first..=last`, at three levels.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Summary {
    pub first: MessageId,
    pub last: MessageId,
    pub started_at: DateTime<Utc>,
    pub ended_at: DateTime<Utc>,
    pub title: String,
    pub kind: String,
    /// 1 to 100: how slowly it decays.
    pub importance: u8,
    pub full: String,
    pub brief: Option<String>,
    pub line: Option<String>,
}

/// Adds an active summary. One that overlaps an active summary of the same
/// conversation is refused by the schema.
pub async fn insert(
    conn: &mut PgConnection,
    conversation: ConversationId,
    summary: &Summary,
    model: &str,
    at: DateTime<Utc>,
) -> sqlx::Result<SummaryId> {
    let id = sqlx::query_scalar!(
        r#"
        insert into summaries (
            conversation_id, first_message_id, last_message_id, started_at, ended_at,
            title, kind, importance, p1, p2, p3, model, created_at
        ) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
        returning id
        "#,
        conversation.0,
        summary.first.0,
        summary.last.0,
        summary.started_at,
        summary.ended_at,
        summary.title,
        summary.kind,
        i16::from(summary.importance),
        summary.full,
        summary.brief,
        summary.line,
        model,
        at
    )
    .fetch_one(conn)
    .await?;
    Ok(SummaryId(id))
}

/// The conversation's active summaries that end after `after` (the
/// !clear --all watermark), oldest first.
pub async fn active(
    conn: &mut PgConnection,
    conversation: ConversationId,
    after: Option<MessageId>,
) -> sqlx::Result<Vec<(SummaryId, Summary)>> {
    let rows = sqlx::query!(
        r#"
        select id, first_message_id, last_message_id, started_at, ended_at, title, kind,
               importance, p1, p2, p3
        from summaries
        where conversation_id = $1 and status = 'active' and last_message_id > $2
        order by first_message_id
        "#,
        conversation.0,
        after.map_or(0, |id| id.0)
    )
    .fetch_all(conn)
    .await?;
    rows.into_iter()
        .map(|row| {
            let importance = u8::try_from(row.importance)
                .map_err(|_| unknown("importance", &row.importance.to_string()))?;
            Ok((
                SummaryId(row.id),
                Summary {
                    first: MessageId(row.first_message_id),
                    last: MessageId(row.last_message_id),
                    started_at: row.started_at,
                    ended_at: row.ended_at,
                    title: row.title,
                    kind: row.kind,
                    importance,
                    full: row.p1,
                    brief: row.p2,
                    line: row.p3,
                },
            ))
        })
        .collect()
}

#[cfg(test)]
mod tests;
