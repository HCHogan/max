//! Turn records: started, resumed, snapshot, finished. Append only; a
//! turn's state is which of them it has.

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

/// A suspended turn runs again after a restart, as attempt 2, 3 and so on.
pub async fn resume(
    conn: &mut PgConnection,
    turn: TurnId,
    attempt: i32,
    at: DateTime<Utc>,
) -> sqlx::Result<()> {
    sqlx::query!(
        "insert into turn_resumes (turn_id, attempt, resumed_at) values ($1, $2, $3)",
        turn.0,
        attempt,
        at
    )
    .execute(conn)
    .await?;
    Ok(())
}

/// The core as an attempt stops: a suspend writes only this.
pub async fn snapshot(
    conn: &mut PgConnection,
    turn: TurnId,
    attempt: i32,
    run: &RunRecord,
    upto: MessageId,
    at: DateTime<Utc>,
) -> sqlx::Result<()> {
    sqlx::query!(
        "insert into turn_snapshots (turn_id, attempt, run, upto_id, taken_at)
         values ($1, $2, $3, $4, $5)",
        turn.0,
        attempt,
        Json(run) as _,
        upto.0,
        at
    )
    .execute(conn)
    .await?;
    Ok(())
}

/// A turn ends: its last snapshot and its outcome, together.
pub async fn finish(
    conn: &mut PgConnection,
    turn: TurnId,
    attempt: i32,
    run: &RunRecord,
    upto: MessageId,
    outcome: &Outcome,
    at: DateTime<Utc>,
) -> sqlx::Result<()> {
    let mut tx = conn.begin().await?;
    snapshot(&mut tx, turn, attempt, run, upto, at).await?;
    close(&mut tx, turn, outcome, at).await?;
    tx.commit().await
}

/// An outcome without a snapshot, for the start of the process: a
/// suspended turn that expired, or one that was running in a crash.
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
            FailReason::InputTooLarge => ("failed", Some("input_too_large"), None),
        },
        Outcome::Expired => ("expired", None, None),
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
        ("failed", Some("input_too_large")) => failed(FailReason::InputTooLarge),
        ("expired", None) => Outcome::Expired,
        ("lost", None) => Outcome::Lost,
        (outcome, _) => return Err(unknown("outcome", outcome)),
    }))
}

/// A turn without an outcome, found when the process starts.
#[derive(Clone, Debug, PartialEq)]
pub struct Unfinished {
    pub turn: TurnId,
    pub conversation: ConversationId,
    pub from: MessageId,
    /// The latest attempt: 1 for the start, more after resumes.
    pub attempt: i32,
    pub state: State,
}

#[derive(Clone, Debug, PartialEq)]
pub enum State {
    /// The latest attempt left a snapshot: suspended by a clean restart.
    Suspended {
        run: Box<RunRecord>,
        upto: MessageId,
        taken_at: DateTime<Utc>,
    },
    /// No snapshot: it was running when the process crashed.
    Running,
}

pub async fn unfinished(conn: &mut PgConnection) -> sqlx::Result<Vec<Unfinished>> {
    let rows = sqlx::query!(
        r#"
        select t.id, t.conversation_id, t.from_id, a.attempt as "attempt!",
               s.run as "run?: Json<RunRecord>", s.upto_id as "upto_id?",
               s.taken_at as "taken_at?"
        from turns t
        cross join lateral (
            select coalesce(max(attempt), 1) as attempt from turn_resumes where turn_id = t.id
        ) a
        left join turn_snapshots s on s.turn_id = t.id and s.attempt = a.attempt
        where not exists (select from turn_outcomes o where o.turn_id = t.id)
        order by t.id
        "#
    )
    .fetch_all(conn)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| Unfinished {
            turn: TurnId(row.id),
            conversation: ConversationId(row.conversation_id),
            from: MessageId(row.from_id),
            attempt: row.attempt,
            state: match (row.run, row.upto_id, row.taken_at) {
                (Some(Json(run)), Some(upto), Some(taken_at)) => State::Suspended {
                    run: Box::new(run),
                    upto: MessageId(upto),
                    taken_at,
                },
                _ => State::Running,
            },
        })
        .collect())
}

#[cfg(test)]
mod tests;
