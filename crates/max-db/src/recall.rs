//! Recall: where in a conversation the terms of a `context_search` are. A
//! term is found as a substring of lowercased text: a row's rendered text
//! or its pictures' captions, a summary's title and levels. These find the
//! candidates; ranking them is the caller's. See "召回".

use chrono::{DateTime, Utc};
use max_core::ids::{ConversationId, MessageId, SummaryId};
use sqlx::{Connection, PgConnection};

/// What to look for, and where.
#[derive(Clone, Debug)]
pub struct Query<'a> {
    pub conversation: ConversationId,
    /// A LIKE pattern per term, for lowercased text: `%term%`, with `%`,
    /// `_` and `\` in the term escaped.
    pub patterns: &'a [String],
    /// Only what comes after this row: /clear --all's mark.
    pub after: Option<MessageId>,
    /// Rows sent from `from` and before `until`; summaries that overlap.
    pub from: Option<DateTime<Utc>>,
    pub until: Option<DateTime<Utc>>,
    /// The most candidates.
    pub limit: i64,
}

/// A candidate, with which of the patterns it has, by index.
pub type Found<T> = (T, Vec<usize>);

/// Chat rows with any of the terms in their text or in a picture's
/// caption: the most terms first, then the newest. Commands, events and
/// rows taken back are left out; so are sticker captions, which say what a
/// sticker is for rather than what was said.
pub async fn messages(
    conn: &mut PgConnection,
    query: &Query<'_>,
) -> sqlx::Result<Vec<Found<MessageId>>> {
    let mut tx = conn.begin().await?;
    // Planned with the terms in hand: one of two characters has no
    // trigrams, and the index would be read whole for it. A generic plan,
    // which a prepared statement settles on after a few runs, can't tell.
    sqlx::query!("set local plan_cache_mode = force_custom_plan")
        .execute(&mut *tx)
        .await?;
    // Materialized, so that each row and caption is lowercased once, and
    // each row's terms worked out once, not again for the sort.
    let rows = sqlx::query!(
        r#"
        with hits as materialized (
            select id from messages where conversation_id = $1 and lower(text) like any($2)
            union
            select mm.message_id from media_captions c
            join message_media mm on mm.sha256 = c.sha256
            join messages m on m.id = mm.message_id
            where c.kind = 'image' and lower(c.text) like any($2) and m.conversation_id = $1
        ), bodies as materialized (
            select m.id, concat_ws(E'\n', lower(m.text), (
                select string_agg(lower(c.text), E'\n')
                from message_media mm join media_captions c on c.sha256 = mm.sha256
                where mm.message_id = m.id and c.kind = 'image'
            )) as body
            from messages m
            where m.id in (select id from hits)
              and m.conversation_id = $1 and m.kind = 'chat' and m.id > $3
              and ($4::timestamptz is null or m.sent_at >= $4)
              and ($5::timestamptz is null or m.sent_at < $5)
              and not exists (
                  select from messages u where u.target_id = m.id and u.event = 'unsend'
              )
        ), found as materialized (
            select id, array(
                select t.n::int from unnest($2::text[]) with ordinality as t(pattern, n)
                where body like t.pattern
            ) as terms
            from bodies
        )
        select id as "id!", terms as "terms!" from found
        order by cardinality(terms) desc, id desc
        limit $6
        "#,
        query.conversation.0,
        query.patterns,
        query.after.map_or(0, |id| id.0),
        query.from,
        query.until,
        query.limit
    )
    .fetch_all(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(rows
        .into_iter()
        .map(|row| (MessageId(row.id), indexes(&row.terms)))
        .collect())
}

/// Active summaries with any of the terms in their title or levels: the
/// most terms first, then the newest.
pub async fn summaries(
    conn: &mut PgConnection,
    query: &Query<'_>,
) -> sqlx::Result<Vec<Found<SummaryId>>> {
    // Each summary is lowercased once: the whole of it, from the title down.
    let rows = sqlx::query!(
        r#"
        with bodies as materialized (
            select id, last_message_id, lower(concat_ws(E'\n', title, p1, p2, p3)) as body
            from summaries
            where conversation_id = $1 and status = 'active' and last_message_id > $3
              and ($4::timestamptz is null or ended_at >= $4)
              and ($5::timestamptz is null or started_at < $5)
        ), found as materialized (
            select b.id, b.last_message_id, array(
                select t.n::int from unnest($2::text[]) with ordinality as t(pattern, n)
                where b.body like t.pattern
            ) as terms
            from bodies b
            where b.body like any($2)
        )
        select id as "id!", terms as "terms!" from found
        order by cardinality(terms) desc, last_message_id desc
        limit $6
        "#,
        query.conversation.0,
        query.patterns,
        query.after.map_or(0, |id| id.0),
        query.from,
        query.until,
        query.limit
    )
    .fetch_all(conn)
    .await?;
    Ok(rows
        .into_iter()
        .map(|row| (SummaryId(row.id), indexes(&row.terms)))
        .collect())
}

/// SQL's ordinals, from 1, as indexes.
fn indexes(ordinals: &[i32]) -> Vec<usize> {
    ordinals
        .iter()
        .filter_map(|&n| usize::try_from(n - 1).ok())
        .collect()
}

#[cfg(test)]
mod tests;
