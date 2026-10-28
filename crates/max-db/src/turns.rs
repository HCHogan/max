//! Turn records: started, then a snapshot and an outcome as it ends.
//! Append only; a turn without an outcome is running.

use chrono::{DateTime, Utc};
use max_core::ids::{ConversationId, MessageId, TurnId};
use max_core::run::{FailReason, Input, Outcome, RunRecord};
use sqlx::types::Json;
use sqlx::{Connection, PgConnection};

use crate::unknown;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Started {
    pub turn: TurnId,
    /// t#N, counted per conversation.
    pub ordinal: i32,
}

/// A trigger starts a core: the turn's first record.
pub async fn start(
    conn: &mut PgConnection,
    conversation: ConversationId,
    trigger: &[Input],
    from: MessageId,
    at: DateTime<Utc>,
) -> sqlx::Result<Started> {
    let row = sqlx::query!(
        r#"
        insert into turns (conversation_id, ordinal, trigger, from_id, started_at)
        select $1, coalesce(max(ordinal), 0) + 1, $2, $3, $4
        from turns where conversation_id = $1
        returning id, ordinal
        "#,
        conversation.0,
        Json(trigger) as _,
        from.0,
        at
    )
    .fetch_one(conn)
    .await?;
    Ok(Started {
        turn: TurnId(row.id),
        ordinal: row.ordinal,
    })
}

/// A turn ends: its snapshot and its outcome, together.
pub async fn finish(
    conn: &mut PgConnection,
    turn: TurnId,
    run: &RunRecord,
    outcome: &Outcome,
    at: DateTime<Utc>,
) -> sqlx::Result<()> {
    let mut tx = conn.begin().await?;
    sqlx::query!(
        "insert into turn_snapshots (turn_id, run, taken_at) values ($1, $2, $3)",
        turn.0,
        Json(run) as _,
        at
    )
    .execute(&mut *tx)
    .await?;
    close(&mut tx, turn, outcome, at).await?;
    tx.commit().await
}

/// An outcome without a snapshot, for the start of the process: a turn
/// that was running in a crash.
pub async fn close(
    conn: &mut PgConnection,
    turn: TurnId,
    outcome: &Outcome,
    at: DateTime<Utc>,
) -> sqlx::Result<()> {
    let (outcome, failure, error) = match outcome {
        Outcome::Answered => ("answered", None, None),
        Outcome::Silent => ("silent", None, None),
        Outcome::Interrupted => ("interrupted", None, None),
        Outcome::Failed { reason } => match reason {
            FailReason::Model { error } => ("failed", Some("model"), Some(error.as_str())),
            FailReason::ContextExhausted => ("failed", Some("context_exhausted"), None),
        },
        Outcome::Lost => ("lost", None, None),
    };
    sqlx::query!(
        "insert into turn_outcomes (turn_id, outcome, failure, error, finished_at)
         values ($1, $2, $3, $4, $5)",
        turn.0,
        outcome,
        failure,
        error,
        at
    )
    .execute(conn)
    .await?;
    Ok(())
}

pub async fn outcome(conn: &mut PgConnection, turn: TurnId) -> sqlx::Result<Option<Outcome>> {
    let Some(row) = sqlx::query!(
        "select outcome, failure, error from turn_outcomes where turn_id = $1",
        turn.0
    )
    .fetch_optional(conn)
    .await?
    else {
        return Ok(None);
    };
    let failed = |reason| Outcome::Failed { reason };
    Ok(Some(match (row.outcome.as_str(), row.failure.as_deref()) {
        ("answered", None) => Outcome::Answered,
        ("silent", None) => Outcome::Silent,
        ("interrupted", None) => Outcome::Interrupted,
        ("failed", Some("model")) => failed(FailReason::Model {
            error: row.error.unwrap_or_default(),
        }),
        ("failed", Some("context_exhausted")) => failed(FailReason::ContextExhausted),
        ("lost", None) => Outcome::Lost,
        (outcome, _) => return Err(unknown("outcome", outcome)),
    }))
}

/// Turns without an outcome, found when the process starts: a clean stop
/// ends every turn, so these were running in a crash.
pub async fn unfinished(conn: &mut PgConnection) -> sqlx::Result<Vec<TurnId>> {
    let ids = sqlx::query_scalar!(
        "select id from turns t
         where not exists (select from turn_outcomes o where o.turn_id = t.id)
         order by id"
    )
    .fetch_all(conn)
    .await?;
    Ok(ids.into_iter().map(TurnId).collect())
}

#[cfg(test)]
mod tests;
