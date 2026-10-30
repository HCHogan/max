//! Recall: where in a conversation the terms of a `history` search are. A
//! term is found as a substring of lowercased text: a row's rendered text
//! or the captions of its pictures and stickers. The rows' vectors find
//! more, near the query's by meaning. These find the candidates; ranking
//! them is the caller's.
//! See "召回".

use max_core::ids::{ConversationId, MessageId};
use sqlx::{Connection, PgConnection};

/// What to look for, and where.
#[derive(Clone, Debug)]
pub struct Query<'a> {
    pub conversation: ConversationId,
    /// A LIKE pattern per term, for lowercased text: `%term%`, with `%`,
    /// `_` and `\` in the term escaped.
    pub patterns: &'a [String],
    /// Rows from `from` and before `until`, by id: a stretch of the
    /// timeline, as `history` works out from days, moments or rows.
    pub from: Option<MessageId>,
    pub until: Option<MessageId>,
    /// Rows whose sender's name, lowercased, is like this; with no
    /// patterns, all of them.
    pub sender: Option<&'a str>,
    /// The most candidates.
    pub limit: i64,
}

/// A candidate, with which of the patterns it has, by index.
pub type Found<T> = (T, Vec<usize>);

/// Chat rows with any of the terms in their text or in a caption of their
/// pictures or stickers, or with no terms all the sender's: the most terms
/// first, then the newest. Commands,
/// events and rows taken back are left out. What /clear --all hid from
/// the context is not.
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
            where lower(c.text) like any($2) and m.conversation_id = $1
            union
            select id from messages
            where conversation_id = $1 and cardinality($2::text[]) = 0
              and lower(sender_name) like $6
              and ($3::bigint is null or id >= $3) and ($4::bigint is null or id < $4)
        ), bodies as materialized (
            select m.id, concat_ws(E'\n', lower(m.text), (
                select string_agg(lower(c.text), E'\n')
                from message_media mm join media_captions c on c.sha256 = mm.sha256
                where mm.message_id = m.id
            )) as body
            from messages m
            where m.id in (select id from hits)
              and m.conversation_id = $1 and m.kind = 'chat'
              and ($3::bigint is null or m.id >= $3)
              and ($4::bigint is null or m.id < $4)
              and ($6::text is null or lower(m.sender_name) like $6)
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
        limit $5
        "#,
        query.conversation.0,
        query.patterns,
        query.from.map(|id| id.0),
        query.until.map(|id| id.0),
        query.limit,
        query.sender
    )
    .fetch_all(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(rows
        .into_iter()
        .map(|row| (MessageId(row.id), indexes(&row.terms)))
        .collect())
}

/// A candidate by meaning, with the cosine similarity of its vector to the
/// query's: 1 the same, 0 nothing in common.
pub type Near<T> = (T, f32);

/// The chat rows whose vectors by `model` are nearest `vector`, under the
/// filters of [`messages`] but the patterns: up to `query.limit`, about
/// the nearest first. The HNSW index alone would stop at 40 candidates,
/// before the filters; it is told to go on until there are enough. In a
/// small conversation the planner goes through its rows instead, so the
/// plan is made with the conversation in hand.
pub async fn near_messages(
    conn: &mut PgConnection,
    query: &Query<'_>,
    model: &str,
    vector: &[f32],
) -> sqlx::Result<Vec<Near<MessageId>>> {
    let mut tx = conn.begin().await?;
    sqlx::query!("set local plan_cache_mode = force_custom_plan")
        .execute(&mut *tx)
        .await?;
    sqlx::query!("set local hnsw.iterative_scan = relaxed_order")
        .execute(&mut *tx)
        .await?;
    let rows = sqlx::query!(
        r#"
        select e.message_id as "id!",
               (1 - (e.embedding <=> $3::float4[]::halfvec))::float4 as "similarity!"
        from message_embeddings e join messages m on m.id = e.message_id
        where e.conversation_id = $1 and e.model = $2 and m.kind = 'chat'
          and ($4::bigint is null or m.id >= $4)
          and ($5::bigint is null or m.id < $5)
          and ($7::text is null or lower(m.sender_name) like $7)
          and not exists (select from messages u where u.target_id = m.id and u.event = 'unsend')
        order by e.embedding <=> $3::float4[]::halfvec
        limit $6
        "#,
        query.conversation.0,
        model,
        vector as &[f32],
        query.from.map(|id| id.0),
        query.until.map(|id| id.0),
        query.limit,
        query.sender
    )
    .fetch_all(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(rows
        .into_iter()
        .map(|row| (MessageId(row.id), row.similarity))
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
