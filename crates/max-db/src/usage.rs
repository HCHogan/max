//! What each model call cost.

use std::time::Duration;

use chrono::{DateTime, Utc};
use max_core::ids::{ConversationId, TurnId};
use max_core::item::{Timing, Usage};
use sqlx::PgConnection;

/// What a model call was for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Purpose {
    /// A turn's.
    Turn,
    /// The classifier's.
    Intent,
    /// A caption's.
    Caption,
}

max_core::names!(Purpose, "purpose", {
    Turn => "turn",
    Intent => "intent",
    Caption => "caption",
});

/// A model call to record.
#[derive(Clone, Debug)]
pub struct Call<'a> {
    /// The conversation it was for, if for one.
    pub conversation: Option<ConversationId>,
    /// The turn it was part of, if of one.
    pub turn: Option<TurnId>,
    /// What it was for.
    pub purpose: Purpose,
    /// The provider called.
    pub provider: &'a str,
    /// The model, as the provider names it.
    pub model: &'a str,
    /// The effort asked for, if any.
    pub effort: Option<&'a str>,
    /// What the provider says it used.
    pub usage: Usage,
    /// Millionths of a US dollar, when the price is known.
    pub cost_micros: Option<i64>,
    /// When max measured it.
    pub timing: Option<Timing>,
    /// When it ended.
    pub at: DateTime<Utc>,
}

/// Records a model call.
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
        call.conversation.map(|conversation| conversation.get()),
        call.turn.map(|turn| turn.get()),
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
    /// The provider.
    pub provider: String,
    /// The model.
    pub model: String,
    /// The input's tokens.
    pub input: i64,
    /// Of the input, how much hit the cache.
    pub cached: i64,
    /// The output's tokens.
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
        conversation.get(),
        since
    )
    .fetch_all(conn)
    .await
}
