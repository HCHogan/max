use max_core::intent::Reason;
use max_core::item::{Item, ItemKind, ModelTag, Protocol};
use max_core::run::{Context, Run, RunSpec, Wake};
use sqlx::PgPool;

use super::*;
use crate::platform::Endpoint;
use crate::testing::{self, at};

/// A group with one message in it, for turns to start from.
async fn group(conn: &mut PgConnection, native_id: &str) -> sqlx::Result<(Endpoint, MessageId)> {
    let group = testing::group(conn, native_id).await?;
    let max = testing::sender(group.max, "Max", None);
    let message = testing::commit(conn, &group, &max, &testing::said("早"), 0).await?;
    Ok((group.endpoint, message))
}

fn record() -> RunRecord {
    let spec = RunSpec {
        model: ModelTag {
            protocol: Protocol::Chat,
            model: "qwen".into(),
        },
        window: 128_000,
        max_output: None,
    };
    let base = Context {
        items: vec![Item::new(
            ItemKind::System {
                text: "人设".into(),
            },
            10,
        )],
        roster: Default::default(),
    };
    let mut run = Run::new(spec, base, Vec::new());
    run.next_step();
    run.snapshot()
}

#[sqlx::test]
async fn ordinals_count_per_conversation(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let (a, from_a) = group(&mut conn, "group:30001").await?;
    let (b, from_b) = group(&mut conn, "group:30002").await?;
    let ordinal = |started: Started| started.ordinal;
    let first = start(&mut conn, a.conversation, &[], from_a, at(1)).await?;
    let second = start(&mut conn, a.conversation, &[], from_a, at(2)).await?;
    let elsewhere = start(&mut conn, b.conversation, &[], from_b, at(3)).await?;
    assert_eq!(
        [ordinal(first), ordinal(second), ordinal(elsewhere)],
        [1, 2, 1]
    );
    Ok(())
}

#[sqlx::test]
async fn a_turn_without_an_outcome_is_unfinished(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let (group, from) = group(&mut conn, "group:30001").await?;
    let conversation = group.conversation;
    let running = start(&mut conn, conversation, &[], from, at(1)).await?.turn;
    let finished = start(&mut conn, conversation, &[], from, at(2)).await?.turn;
    finish(&mut conn, finished, &record(), &Outcome::Silent, at(3)).await?;
    assert_eq!(unfinished(&mut conn).await?, [running]);
    assert_eq!(outcome(&mut conn, finished).await?, Some(Outcome::Silent));
    assert_eq!(outcome(&mut conn, running).await?, None);
    Ok(())
}

#[sqlx::test]
async fn a_running_turn_unsettles_the_conversation_from_its_trigger(
    pool: PgPool,
) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let (group, from) = group(&mut conn, "group:30001").await?;
    let conversation = group.conversation;
    assert_eq!(running_since(&mut conn, conversation).await?, None);
    let wake = |ids: &[MessageId]| {
        vec![Input::Wake(Wake {
            ids: ids.to_vec(),
            reason: Reason::Direct,
            item: None,
        })]
    };
    let later = MessageId(from.0 + 5);
    let running = start(&mut conn, conversation, &wake(&[later, from]), from, at(1)).await?;
    assert_eq!(running_since(&mut conn, conversation).await?, Some(from));
    finish(&mut conn, running.turn, &record(), &Outcome::Silent, at(2)).await?;
    assert_eq!(running_since(&mut conn, conversation).await?, None);
    Ok(())
}

#[sqlx::test]
async fn outcomes_read_back_as_written(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let (group, from) = group(&mut conn, "group:30001").await?;
    let failed = |reason| Outcome::Failed { reason };
    let outcomes = [
        Outcome::Answered,
        Outcome::Silent,
        Outcome::Interrupted,
        failed(FailReason::Model {
            error: "429".into(),
        }),
        failed(FailReason::ContextExhausted),
        Outcome::Lost,
    ];
    for (minute, written) in (1..).zip(&outcomes) {
        let turn = start(&mut conn, group.conversation, &[], from, at(minute))
            .await?
            .turn;
        close(&mut conn, turn, written, at(minute)).await?;
        assert_eq!(outcome(&mut conn, turn).await?.as_ref(), Some(written));
    }
    Ok(())
}

#[sqlx::test]
async fn finishing_twice_leaves_no_second_snapshot(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let (group, from) = group(&mut conn, "group:30001").await?;
    let turn = start(&mut conn, group.conversation, &[], from, at(1))
        .await?
        .turn;
    close(&mut conn, turn, &Outcome::Lost, at(2)).await?;
    let again = finish(&mut conn, turn, &record(), &Outcome::Silent, at(3)).await;
    assert!(again.is_err());
    let snapshots = sqlx::query_scalar!(
        r#"select count(*) as "n!" from turn_snapshots where turn_id = $1"#,
        turn.0
    )
    .fetch_one(&mut *conn)
    .await?;
    assert_eq!(snapshots, 0);
    Ok(())
}
