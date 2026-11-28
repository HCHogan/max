//! A turn's tool calls as text, which `history` searches with `tools:
//! true` and reads by `t#N.n`: what each was given and what it returned,
//! as the model saw it. Written with the turn's outcome, from its run, by
//! the database's `tool_calls_of` (see [`crate::turns::finish`]). See
//! "Recall".

use chrono::{DateTime, Utc};
use max_core::ids::{ConversationId, MessageId};
use sqlx::{Connection, PgConnection};

use crate::recall::{Found, Query};

/// A tool call of a turn.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Call {
    /// Its turn, as t#N.
    pub turn: i32,
    /// Its place among the turn's calls, from 1.
    pub n: i32,
    pub name: String,
    /// What it was given: a line `key: value` for each argument.
    pub arguments: String,
    /// The text it returned.
    pub output: String,
    /// When its turn started.
    pub started: DateTime<Utc>,
}

/// Calls of the conversation's turns with any of the terms in their
/// arguments or output, those with the most terms first, then the newest.
/// A turn is in `from` and `until` by where its context ends. The calls
/// are Max's: `sender` doesn't apply.
pub async fn matching(
    conn: &mut PgConnection,
    query: &Query<'_>,
) -> sqlx::Result<Vec<Found<Call>>> {
    let mut tx = conn.begin().await?;
    // As in recall::messages: planned with the terms in hand.
    sqlx::query!("set local plan_cache_mode = force_custom_plan")
        .execute(&mut *tx)
        .await?;
    let rows = sqlx::query!(
        r#"
        with hits as materialized (
            select c.turn_id, c.n, c.name, c.arguments, c.output, t.ordinal, t.started_at,
                   lower(c.arguments || E'\n' || c.output) as body
            from tool_calls c join turns t on t.id = c.turn_id
            where lower(c.arguments || E'\n' || c.output) like any($2)
              and t.conversation_id = $1
              and ($3::bigint is null or t.from_id >= $3)
              and ($4::bigint is null or t.from_id < $4)
        ), found as materialized (
            select *, array(
                select x.n::int from unnest($2::text[]) with ordinality as x(pattern, n)
                where body like x.pattern
            ) as terms
            from hits
        )
        select ordinal as "turn!", n as "n!", name as "name!", arguments as "arguments!",
               output as "output!", started_at as "started!", terms as "terms!"
        from found
        order by cardinality(terms) desc, turn_id desc, n desc
        limit $5
        "#,
        query.conversation.get(),
        query.patterns,
        query.from.map(MessageId::get),
        query.until.map(MessageId::get),
        query.limit
    )
    .fetch_all(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(rows
        .into_iter()
        .map(|row| {
            let call = Call {
                turn: row.turn,
                n: row.n,
                name: row.name,
                arguments: row.arguments,
                output: row.output,
                started: row.started,
            };
            (call, crate::recall::indexes(&row.terms))
        })
        .collect())
}

/// The conversation's latest calls, the newest first, `limit` at most. A
/// turn is in `from` and `until` by where its context ends, as for
/// [`matching`].
pub async fn latest(
    conn: &mut PgConnection,
    conversation: ConversationId,
    from: Option<MessageId>,
    until: Option<MessageId>,
    limit: i64,
) -> sqlx::Result<Vec<Call>> {
    let rows = sqlx::query!(
        "select t.ordinal, c.n, c.name, c.arguments, c.output, t.started_at
         from turns t join tool_calls c on c.turn_id = t.id
         where t.conversation_id = $1
           and ($2::bigint is null or t.from_id >= $2)
           and ($3::bigint is null or t.from_id < $3)
         order by t.ordinal desc, c.n desc
         limit $4",
        conversation.get(),
        from.map(MessageId::get),
        until.map(MessageId::get),
        limit
    )
    .fetch_all(conn)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| Call {
            turn: row.ordinal,
            n: row.n,
            name: row.name,
            arguments: row.arguments,
            output: row.output,
            started: row.started_at,
        })
        .collect())
}

/// The `n`-th call of the conversation's turn t#`turn`.
pub async fn call(
    conn: &mut PgConnection,
    conversation: ConversationId,
    turn: i32,
    n: i32,
) -> sqlx::Result<Option<Call>> {
    let row = sqlx::query!(
        "select c.name, c.arguments, c.output, t.started_at
         from tool_calls c join turns t on t.id = c.turn_id
         where t.conversation_id = $1 and t.ordinal = $2 and c.n = $3",
        conversation.get(),
        turn,
        n
    )
    .fetch_optional(conn)
    .await?;
    Ok(row.map(|row| Call {
        turn,
        n,
        name: row.name,
        arguments: row.arguments,
        output: row.output,
        started: row.started_at,
    }))
}

#[cfg(test)]
mod tests;
