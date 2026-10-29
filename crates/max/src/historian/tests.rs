use max_core::intent::Reason as WakeReason;
use max_core::run::{Input, Wake};
use max_db::PgPool;
use max_db::platform::Settings;

use super::*;
use crate::conversation::ingest;
use crate::conversation::testing::{at, from_xiaoming, group, offset, text};
use crate::llm::testing::{Answer, Script, models};

fn budgets() -> Budgets {
    Budgets {
        tail_high: 100,
        tail_low: 50,
        summaries: 0,
        single: 0,
    }
}

#[test]
fn quiet_leaves_the_low_watermark_and_waits_for_enough() {
    // The newest rows up to 50 tokens stay; 25 is enough for a call.
    assert_eq!(stretch(&[10, 20, 30, 20], Reason::Quiet, &budgets()), 2);
    assert_eq!(stretch(&[20, 30, 20], Reason::Quiet, &budgets()), 0);
    assert_eq!(stretch(&[], Reason::Quiet, &budgets()), 0);
    // A newest row past the low watermark isn't kept back on its own.
    assert_eq!(stretch(&[30, 60], Reason::Quiet, &budgets()), 2);
}

#[test]
fn pressure_is_past_the_high_watermark_and_compact_takes_all() {
    assert_eq!(stretch(&[40, 30, 30], Reason::Pressure, &budgets()), 0);
    assert_eq!(stretch(&[40, 31, 30], Reason::Pressure, &budgets()), 2);
    assert_eq!(stretch(&[40, 30, 30], Reason::Compact, &budgets()), 3);
    assert_eq!(stretch(&[], Reason::Compact, &budgets()), 0);
}

#[test]
fn a_batch_is_capped_but_takes_at_least_a_row() {
    let big = u32::try_from(BATCH).unwrap();
    assert_eq!(stretch(&[big, 1, 1], Reason::Compact, &budgets()), 1);
    assert_eq!(stretch(&[big + 1, 1], Reason::Compact, &budgets()), 1);
    assert_eq!(
        stretch(&[big / 2, big / 2, 1], Reason::Compact, &budgets()),
        2
    );
}

/// 小明 says `count` long lines in a group whose turns use the small
/// model, so its watermarks are low: 1000 and 500 tokens.
async fn chatter(pool: &PgPool, count: u32) -> (Place, Vec<MessageId>) {
    let mut conn = pool.acquire().await.unwrap();
    let place = group(&mut conn).await;
    let small = Settings {
        model: Some("test/small".into()),
        ..Settings::default()
    };
    platform::save_settings(&mut conn, place.conversation, &small, at(0))
        .await
        .unwrap();
    let mut ids = Vec::new();
    for n in 0..count {
        let said = format!("第{n}句：{}", "今天群里在聊示波器探头的补偿，".repeat(6));
        let inbound = from_xiaoming(n, vec![text(&said)]);
        let committed = ingest::inbound(&mut conn, &place, &inbound, at(n), offset())
            .await
            .unwrap();
        ids.push(committed.message.id);
    }
    (place, ids)
}

fn historian(pool: &PgPool, script: &Arc<Script>) -> Historian {
    let models = Arc::new(models(script));
    Historian {
        pool: pool.clone(),
        chosen: models.historian().unwrap().unwrap(),
        models,
        offset: offset(),
        published: None,
    }
}

fn answer(compartments: &[(MessageId, MessageId)]) -> Answer {
    let parts: Vec<String> = compartments
        .iter()
        .map(|(first, last)| {
            format!(
                r#"{{"first": {first}, "last": {last}, "title": "示波器", "kind": "support", "importance": 40, "p1": "[mention#1] 问探头补偿。", "p2": "探头补偿。", "p3": "聊了探头补偿"}}"#
            )
        })
        .collect();
    Answer::says(&format!(r#"{{"compartments": [{}]}}"#, parts.join(", ")))
}

async fn runs(pool: &PgPool) -> Vec<(i64, i64, Option<String>)> {
    sqlx::query_as("select first_message_id, last_message_id, error from summary_runs order by id")
        .fetch_all(pool)
        .await
        .unwrap()
}

async fn active(pool: &PgPool, place: &Place) -> Vec<summaries::Summary> {
    let mut conn = pool.acquire().await.unwrap();
    summaries::active(&mut conn, place.conversation, None)
        .await
        .unwrap()
        .into_iter()
        .map(|(_, summary)| summary)
        .collect()
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_quiet_group_with_little_said_is_left_alone(pool: PgPool) {
    let script = Arc::new(Script::default());
    let (place, _) = chatter(&pool, 3).await;
    let captured = historian(&pool, &script)
        .capture(&place, Reason::Quiet)
        .await;
    assert_eq!(captured.unwrap(), Captured::Nothing);
    assert_eq!(script.calls(), 0);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_wrong_answer_is_shown_back_once(pool: PgPool) {
    let script = Arc::new(Script::default());
    let (place, ids) = chatter(&pool, 20).await;
    let (next, mut published) = tokio::sync::mpsc::unbounded_channel();
    let historian = Historian {
        published: Some(next),
        ..historian(&pool, &script)
    };
    script.push(Answer::says("算了"));
    script.push(Answer::says("还是算了"));
    assert!(historian.capture(&place, Reason::Quiet).await.is_err());
    let failed = runs(&pool).await;
    assert_eq!(failed.len(), 2);
    assert!(failed.iter().all(|(_, _, error)| error.is_some()));
    let (first, last) = (failed[0].0, failed[0].1);
    assert_eq!(first, ids[0].0);
    // The low watermark stays raw.
    let last_index = ids.iter().position(|id| id.0 == last).unwrap();
    assert!((2..19).contains(&last_index), "{last_index}");
    let second = script.requests.lock().unwrap()[1].items.clone();
    assert_eq!(second.len(), 4);
    assert!(
        matches!(&second[3].kind, ItemKind::User { text, .. } if text.contains("no object")),
        "{second:?}"
    );

    // Two compartments: the second waits for what comes after it.
    let middle = ids[last_index / 2];
    let after = ids[last_index / 2 + 1];
    script.push(answer(&[(ids[0], middle), (after, MessageId(last))]));
    let captured = historian.capture(&place, Reason::Quiet).await.unwrap();
    assert_eq!(captured, Captured::Published(1));
    // It goes on to the recall vector worker.
    assert!(matches!(published.try_recv(), Ok(Key::Summary(_))));
    assert!(published.try_recv().is_err());
    let published = active(&pool, &place).await;
    assert_eq!((published[0].first, published[0].last), (ids[0], middle));
    assert_eq!(published[0].started_at, at(0));
    assert_eq!(published[0].brief.as_deref(), Some("探头补偿。"));
    let text = match &script.requests.lock().unwrap()[2].items[1].kind {
        ItemKind::User { text, .. } => text.clone(),
        other => panic!("{other:?}"),
    };
    assert!(text.starts_with("[现在] "), "{text}");
    assert!(text.contains("[之前的摘要]\n（无）"), "{text}");
    assert!(text.contains("（就是 maxx）"), "{text}");
    let line = format!("[12:00 小明 #{}]: 第0句", ids[0]);
    assert!(text.contains(&line), "{text}");
    let mut conn = pool.acquire().await.unwrap();
    let calls: i64 =
        sqlx::query_scalar("select count(*) from llm_usage where purpose = 'historian'")
            .fetch_one(&mut *conn)
            .await
            .unwrap();
    assert_eq!(calls, 3);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn compact_takes_everything_before_a_running_turn(pool: PgPool) {
    let script = Arc::new(Script::default());
    let (place, ids) = chatter(&pool, 6).await;
    let mut conn = pool.acquire().await.unwrap();
    let wake = Input::Wake(Wake {
        ids: vec![ids[4]],
        reason: WakeReason::Direct,
        item: None,
    });
    turns::start(&mut conn, place.conversation, &[wake], ids[4], at(5))
        .await
        .unwrap();
    script.push(answer(&[(ids[0], ids[1]), (ids[2], ids[3])]));
    let historian = historian(&pool, &script);
    let captured = historian.capture(&place, Reason::Compact).await.unwrap();
    assert_eq!(captured, Captured::Published(2));
    let published = active(&pool, &place).await;
    assert_eq!(published[1].last, ids[3]);
    // What follows is the running turn's: nothing to summarize yet.
    let again = historian.capture(&place, Reason::Compact).await.unwrap();
    assert_eq!(again, Captured::Nothing);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn the_service_compacts_and_answers(pool: PgPool) {
    let script = Arc::new(Script::default());
    let (place, ids) = chatter(&pool, 4).await;
    script.push(answer(&[(ids[0], ids[3])]));
    let (notices, rx) = tokio::sync::mpsc::unbounded_channel();
    let stop = tokio_util::sync::CancellationToken::new();
    let service = run(historian(&pool, &script), rx, stop.clone());
    let (reply, answer) = tokio::sync::oneshot::channel();
    let place = Arc::new(place);
    notices
        .send(Notice::Compact(Compact { place, reply }))
        .unwrap();
    let asking = async move {
        let compacted = answer.await.unwrap();
        stop.cancel();
        compacted
    };
    let both = async { tokio::join!(service, asking) };
    let ((), compacted) = tokio::time::timeout(Duration::from_secs(5), both)
        .await
        .unwrap();
    assert_eq!(compacted, Ok(Captured::Published(1)));
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn what_came_before_a_clear_is_summarized_on_its_own(pool: PgPool) {
    let script = Arc::new(Script::default());
    let (place, ids) = chatter(&pool, 20).await;
    let mut conn = pool.acquire().await.unwrap();
    let cleared = Settings {
        model: Some("test/small".into()),
        cleared_upto: Some(ids[9]),
        ..Settings::default()
    };
    platform::save_settings(&mut conn, place.conversation, &cleared, at(30))
        .await
        .unwrap();
    drop(conn);
    let historian = historian(&pool, &script);

    // Before the mark fails, twice; what follows it is summarized anyway.
    script.push(Answer::says("算了"));
    script.push(Answer::says("还是算了"));
    script.push(answer(&[(ids[10], ids[19])]));
    let captured = historian.capture(&place, Reason::Compact).await.unwrap();
    assert_eq!(captured, Captured::Published(1));
    // The next capture fills in before the mark, and up to it only.
    script.push(answer(&[(ids[0], ids[4]), (ids[5], ids[9])]));
    let captured = historian.capture(&place, Reason::Compact).await.unwrap();
    assert_eq!(captured, Captured::Published(2));
    let spans: Vec<(MessageId, MessageId)> = active(&pool, &place)
        .await
        .iter()
        .map(|summary| (summary.first, summary.last))
        .collect();
    assert_eq!(
        spans,
        [(ids[0], ids[4]), (ids[5], ids[9]), (ids[10], ids[19])]
    );
    let runs: Vec<(i64, i64)> = runs(&pool)
        .await
        .into_iter()
        .map(|(first, last, _)| (first, last))
        .collect();
    let (before, after) = ((ids[0].0, ids[9].0), (ids[10].0, ids[19].0));
    assert_eq!(runs, [before, before, after, before]);
    // Nothing is left on either side.
    let captured = historian.capture(&place, Reason::Compact).await.unwrap();
    assert_eq!(captured, Captured::Nothing);
    assert_eq!(script.calls(), 4);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_summary_across_a_clear_covers_what_came_before(pool: PgPool) {
    let script = Arc::new(Script::default());
    let (place, ids) = chatter(&pool, 20).await;
    let mut conn = pool.acquire().await.unwrap();
    // Imported: summarized past where the clear came later.
    let across = summaries::Summary {
        first: ids[0],
        last: ids[12],
        started_at: at(0),
        ended_at: at(12),
        title: "示波器".into(),
        kind: "support".into(),
        importance: 40,
        full: "聊了探头补偿。".into(),
        brief: None,
        line: None,
    };
    summaries::insert(&mut conn, place.conversation, &across, "old", at(13))
        .await
        .unwrap();
    let cleared = Settings {
        model: Some("test/small".into()),
        cleared_upto: Some(ids[9]),
        ..Settings::default()
    };
    platform::save_settings(&mut conn, place.conversation, &cleared, at(30))
        .await
        .unwrap();
    drop(conn);
    let historian = historian(&pool, &script);

    // Nothing is asked of the model before the mark: only what follows
    // the summary is.
    script.push(answer(&[(ids[13], ids[19])]));
    let captured = historian.capture(&place, Reason::Compact).await.unwrap();
    assert_eq!(captured, Captured::Published(1));
    let spans: Vec<(MessageId, MessageId)> = active(&pool, &place)
        .await
        .iter()
        .map(|summary| (summary.first, summary.last))
        .collect();
    assert_eq!(spans, [(ids[0], ids[12]), (ids[13], ids[19])]);
    assert_eq!(script.calls(), 1);
}
