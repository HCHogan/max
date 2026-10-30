//! What each model call cost.

use chrono::{DateTime, Utc};
use max_core::ids::{ConversationId, TurnId};
use max_core::item::Usage;
use sqlx::PgConnection;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Purpose {
    Turn,
    Intent,
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
    pub at: DateTime<Utc>,
}

pub async fn record(conn: &mut PgConnection, call: &Call<'_>) -> sqlx::Result<()> {
    let purpose = match call.purpose {
        Purpose::Turn => "turn",
        Purpose::Intent => "intent",
        Purpose::Caption => "caption",
        Purpose::Job => "job",
        Purpose::Dreamer => "dreamer",
    };
    let usage = call.usage;
    sqlx::query!(
        r#"
        insert into llm_usage (
            conversation_id, turn_id, purpose, provider, model, effort,
            input, cached, output, reasoning, cost_micros, at
        ) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
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
        call.at
    )
    .execute(conn)
    .await?;
    Ok(())
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
            at: at(0),
        };
        record(&mut conn, &call).await?;
        let row = sqlx::query!("select purpose, input, cached, cost_micros from llm_usage")
            .fetch_one(&mut *conn)
            .await?;
        assert_eq!(
            (row.purpose.as_str(), row.input, row.cached, row.cost_micros),
            ("intent", 3_000_000_000, 2_000, Some(12))
        );
        Ok(())
    }
}
