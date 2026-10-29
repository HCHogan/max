//! Summaries and conversation settings. The old ones hang off the group
//! number, `legacy_group_id`, not the conversation.

use chrono::{DateTime, Utc};
use color_eyre::eyre::Result;
use max_db::PgConnection;
use tracing::info;

type Old = (
    i64,
    i64,
    i64,
    i64,
    Option<String>,
    Option<String>,
    Option<String>,
    String,
    String,
    f64,
    String,
    DateTime<Utc>,
);

/// The active summaries, over the rows that came along. One that covers
/// only rows that stayed behind is left out.
pub async fn import(old: &mut PgConnection, new: &mut PgConnection) -> Result<()> {
    // A summary covers a span of ingest_seq; within a conversation that
    // runs in the order of ids, so the span is the ids between its first
    // and its last old row.
    let summaries: Vec<Old> = sqlx::query_as(
        "select k.id, c.conversation_id, span.first, span.last, k.summary_p1, k.summary_p2,
                k.summary_p3, k.summary, k.episode_kind, k.importance, k.historian_profile,
                coalesce(k.activated_at, k.created_at)
         from conversation_compartments k
         join conversations c on c.legacy_group_id = k.conversation_id
         cross join lateral (
             select min(m.canonical_message_id) as first, max(m.canonical_message_id) as last
             from messages m
             where m.conversation_id = c.conversation_id
               and m.ingest_seq between k.start_ingest_seq and k.end_ingest_seq
         ) span
         where k.state = 'active' and span.first is not null
         order by k.id",
    )
    .fetch_all(&mut *old)
    .await?;
    let tier = |text: &Option<String>| text.as_deref().map(mentions);
    let inserted = sqlx::query(
        "insert into summaries (id, conversation_id, first_message_id, last_message_id,
             started_at, ended_at, title, kind, importance, p1, p2, p3, model, created_at)
         select t.id, t.conversation, kept.first, kept.last, kept.started, kept.ended, '',
                t.kind, t.importance, t.p1, t.p2, t.p3, t.model, t.created_at
         from unnest($1::bigint[], $2::bigint[], $3::bigint[], $4::bigint[], $5::text[],
                     $6::smallint[], $7::text[], $8::text[], $9::text[], $10::text[],
                     $11::timestamptz[])
             as t (id, conversation, first, last, kind, importance, p1, p2, p3, model, created_at)
         cross join lateral (
             select min(m.id) as first, max(m.id) as last,
                    min(m.sent_at) as started, max(m.sent_at) as ended
             from messages m
             where m.conversation_id = t.conversation and m.id between t.first and t.last
         ) kept
         where kept.first is not null",
    )
    .bind(summaries.iter().map(|k| k.0).collect::<Vec<_>>())
    .bind(summaries.iter().map(|k| k.1).collect::<Vec<_>>())
    .bind(summaries.iter().map(|k| k.2).collect::<Vec<_>>())
    .bind(summaries.iter().map(|k| k.3).collect::<Vec<_>>())
    .bind(summaries.iter().map(|k| k.8.clone()).collect::<Vec<_>>())
    .bind(
        summaries
            .iter()
            .map(|k| importance(k.9))
            .collect::<Vec<_>>(),
    )
    // The summaries from before the tiers have only the one text.
    .bind(
        summaries
            .iter()
            .map(|k| tier(&k.4).unwrap_or_else(|| mentions(&k.7)))
            .collect::<Vec<_>>(),
    )
    .bind(summaries.iter().map(|k| tier(&k.5)).collect::<Vec<_>>())
    .bind(summaries.iter().map(|k| tier(&k.6)).collect::<Vec<_>>())
    .bind(summaries.iter().map(|k| k.10.clone()).collect::<Vec<_>>())
    .bind(summaries.iter().map(|k| k.11).collect::<Vec<_>>())
    .execute(&mut *new)
    .await?;
    info!(summaries = inserted.rows_affected(), "summaries");
    Ok(())
}

/// 0..1 as 1..100.
fn importance(old: f64) -> i16 {
    // A whole number in 0..=99 by then, so the cast is exact.
    let importance = (old * 99.0).round().clamp(0.0, 99.0) as i16;
    importance + 1
}

/// `[@#N]`, from before the rename, as `[mention#N]`.
fn mentions(text: &str) -> String {
    text.replace("[@#", "[mention#")
}

type Setting = (
    i64,
    Option<String>,
    Option<bool>,
    Option<DateTime<Utc>>,
    DateTime<Utc>,
);

/// What `/persona`, `/proactive` and `/clear --all` set. The old model
/// choices stay behind: maxx doesn't have those models, and a model it
/// doesn't have fails every turn.
pub async fn settings(old: &mut PgConnection, new: &mut PgConnection) -> Result<()> {
    let settings: Vec<Setting> = sqlx::query_as(
        "select c.conversation_id, s.persona, s.proactive_override, s.cleared_at, s.updated_at
             from sessions s join conversations c on c.legacy_group_id = s.group_id
             where s.persona is not null or s.proactive_override is not null
                or s.cleared_at is not null",
    )
    .fetch_all(&mut *old)
    .await?;
    let inserted = sqlx::query(
        "insert into conversation_settings (conversation_id, persona, proactive, cleared_upto,
             updated_at)
         select t.conversation, t.persona, coalesce(t.proactive, true),
                (select max(m.id) from messages m
                 where m.conversation_id = t.conversation and m.sent_at <= t.cleared_at),
                t.updated_at
         from unnest($1::bigint[], $2::text[], $3::boolean[], $4::timestamptz[],
                     $5::timestamptz[])
             as t (conversation, persona, proactive, cleared_at, updated_at)
         where exists (select 1 from conversations c where c.id = t.conversation)",
    )
    .bind(settings.iter().map(|s| s.0).collect::<Vec<_>>())
    .bind(settings.iter().map(|s| s.1.clone()).collect::<Vec<_>>())
    .bind(settings.iter().map(|s| s.2).collect::<Vec<_>>())
    .bind(settings.iter().map(|s| s.3).collect::<Vec<_>>())
    .bind(settings.iter().map(|s| s.4).collect::<Vec<_>>())
    .execute(&mut *new)
    .await?;
    info!(settings = inserted.rows_affected(), "settings");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn importance_and_mentions() {
        assert_eq!([0.0, 0.5, 1.0, 1.2].map(importance), [1, 51, 100, 100]);
        assert_eq!(
            mentions("[@#3] 和 [mention#4]"),
            "[mention#3] 和 [mention#4]"
        );
    }
}
