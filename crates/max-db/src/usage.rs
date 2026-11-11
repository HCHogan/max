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

/// The tokens of a conversation's calls on one model, summed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Used {
    pub provider: String,
    pub model: String,
    pub input: i64,
    /// Of the input, how much hit the cache.
    pub cached: i64,
    pub output: i64,
}

/// What `conversation`'s model calls since `since` used, a model a row.
pub async fn used(
    conn: &mut PgConnection,
    conversation: ConversationId,
    since: DateTime<Utc>,
) -> sqlx::Result<Vec<Used>> {
    sqlx::query_as!(
        Used,
        r#"
        select provider, model,
            sum(input)::bigint as "input!",
            sum(cached)::bigint as "cached!",
            sum(output)::bigint as "output!"
        from llm_usage
        where conversation_id = $1 and at >= $2
        group by provider, model
        order by provider, model
        "#,
        conversation.0,
        since
    )
    .fetch_all(conn)
    .await
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

    #[sqlx::test]
    async fn a_conversations_calls_are_summed_by_model(pool: PgPool) -> sqlx::Result<()> {
        let mut conn = pool.acquire().await?;
        let here = group(&mut conn, "group:30001").await?.endpoint.conversation;
        let there = group(&mut conn, "group:30002").await?.endpoint.conversation;
        for (conversation, model, input, cached, minute) in [
            (Some(here), "big", 1_000, 800, 10),
            (Some(here), "big", 2_000, 1_500, 20),
            (Some(here), "small", 300, 0, 20),
            // Too early, elsewhere, or no conversation's.
            (Some(here), "big", 9_000, 0, 0),
            (Some(there), "big", 9_000, 0, 20),
            (None, "big", 9_000, 0, 20),
        ] {
            let call = Call {
                conversation,
                turn: None,
                purpose: Purpose::Turn,
                provider: "cliproxy",
                model,
                effort: None,
                usage: Usage {
                    input,
                    cached,
                    output: 10,
                    reasoning: 4,
                },
                cost_micros: None,
                timing: None,
                at: at(minute),
            };
            record(&mut conn, &call).await?;
        }
        let used = |model: &str, input, cached, output| Used {
            provider: "cliproxy".to_owned(),
            model: model.to_owned(),
            input,
            cached,
            output,
        };
        assert_eq!(
            super::used(&mut conn, here, at(5)).await?,
            [used("big", 3_000, 2_300, 20), used("small", 300, 0, 10)]
        );
        assert!(super::used(&mut conn, here, at(30)).await?.is_empty());
        Ok(())
    }
}
