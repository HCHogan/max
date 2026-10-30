//! What each model call cost.

use std::time::Duration;

use chrono::{DateTime, Utc};
use max_core::ids::{ConversationId, TurnId};
use max_core::item::{Timing, Usage};
use sqlx::PgConnection;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Purpose {
    Turn,
    Intent,
    Historian,
    Caption,
    /// A background agent's.
    Job,
    /// Tidying a memory file.
    Dreamer,
}

#[derive(Clone, Debug)]
pub struct Call<'a> {
    pub conversation: Option<ConversationId>,
    pub turn: Option<TurnId>,
    pub purpose: Purpose,
    pub provider: &'a str,
    pub model: &'a str,
    pub effort: Option<&'a str>,
    pub usage: Usage,
    /// Millionths of a US dollar, when the price is known.
    pub cost_micros: Option<i64>,
    /// When max measured it.
    pub timing: Option<Timing>,
    pub at: DateTime<Utc>,
}

pub async fn record(conn: &mut PgConnection, call: &Call<'_>) -> sqlx::Result<()> {
    let purpose = match call.purpose {
        Purpose::Turn => "turn",
        Purpose::Intent => "intent",
        Purpose::Historian => "historian",
        Purpose::Caption => "caption",
        Purpose::Job => "job",
        Purpose::Dreamer => "dreamer",
    };
    let usage = call.usage;
    let timing = call.timing;
    sqlx::query!(
        r#"
        insert into llm_usage (
            conversation_id, turn_id, purpose, provider, model, effort,
            input, cached, output, reasoning, cost_micros,
            first_ms, took_ms, quiet_ms, at
        ) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
        "#,
        call.conversation.map(|conversation| conversation.0),
        call.turn.map(|turn| turn.0),
        purpose,
        call.provider,
        call.model,
        call.effort,
        i64::from(usage.input),
        i64::from(usage.cached),
        i64::from(usage.output),
        i64::from(usage.reasoning),
        call.cost_micros,
        timing.and_then(|timing| timing.first).map(ms),
        timing.map(|timing| ms(timing.took)),
        timing.map(|timing| ms(timing.quiet)),
        call.at
    )
    .execute(conn)
    .await?;
    Ok(())
}

fn ms(duration: Duration) -> i32 {
    i32::try_from(duration.as_millis()).unwrap_or(i32::MAX)
}

#[cfg(test)]
mod tests {
    use sqlx::PgPool;

    use super::*;
    use crate::testing::{at, group};

    #[sqlx::test]
    async fn a_call_is_recorded(pool: PgPool) -> sqlx::Result<()> {
        let mut conn = pool.acquire().await?;
        let conversation = group(&mut conn, "group:30001").await?.endpoint.conversation;
        let call = Call {
            conversation: Some(conversation),
            turn: None,
            purpose: Purpose::Intent,
            provider: "cliproxy",
            model: "qwen",
            effort: None,
            usage: Usage {
                input: 3_000_000_000,
                cached: 2_000,
                output: 30,
                reasoning: 0,
            },
            cost_micros: Some(12),
            timing: Some(Timing {
                first: None,
                took: Duration::from_millis(2_500),
                quiet: Duration::from_secs(2),
            }),
            at: at(0),
        };
        record(&mut conn, &call).await?;
        let row = sqlx::query!(
            "select purpose, input, cached, cost_micros, first_ms, took_ms, quiet_ms from llm_usage"
        )
        .fetch_one(&mut *conn)
        .await?;
        assert_eq!(
            (row.purpose.as_str(), row.input, row.cached, row.cost_micros),
            ("intent", 3_000_000_000, 2_000, Some(12))
        );
        assert_eq!(
            (row.first_ms, row.took_ms, row.quiet_ms),
            (None, Some(2_500), Some(2_000))
        );
        Ok(())
    }
}
