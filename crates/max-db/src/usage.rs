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
}

max_core::names!(Purpose, "purpose", {
    Turn => "turn",
    Intent => "intent",
    Caption => "caption",
});

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
        call.purpose.as_str(),
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
