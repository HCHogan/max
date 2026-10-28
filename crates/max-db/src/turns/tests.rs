use max_core::item::{Item, ItemKind, ModelTag, Protocol};
use max_core::run::{Context, Run, RunSpec};
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
        max_tools: Vec::new(),
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
async fn a_turns_state_is_the_records_it_has(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let (group, from) = group(&mut conn, "group:30001").await?;
    let conversation = group.conversation;
    let running = start(&mut conn, conversation, &[], from, at(1)).await?.turn;
    let suspended = start(&mut conn, conversation, &[], from, at(2)).await?.turn;
    let resumed = start(&mut conn, conversation, &[], from, at(3)).await?.turn;
    let finished = start(&mut conn, conversation, &[], from, at(4)).await?.turn;
    let run = record();
    snapshot(&mut conn, suspended, 1, &run, from, at(5)).await?;
    // Suspended, resumed, then crashed: the second attempt has no snapshot.
    snapshot(&mut conn, resumed, 1, &run, from, at(5)).await?;
    resume(&mut conn, resumed, 2, at(6)).await?;
    finish(&mut conn, finished, 1, &run, from, &Outcome::Silent, at(7)).await?;

    let found = unfinished(&mut conn).await?;
    let states: Vec<(TurnId, i32, &State)> = found
        .iter()
        .map(|turn| (turn.turn, turn.attempt, &turn.state))
        .collect();
    let snapshot = State::Suspended {
        run: Box::new(run),
        upto: from,
        taken_at: at(5),
    };
    assert_eq!(
        states,
        [
            (running, 1, &State::Running),
            (suspended, 1, &snapshot),
            (resumed, 2, &State::Running),
        ]
    );
    assert!(
        found
            .iter()
            .all(|turn| turn.from == from && turn.conversation == conversation)
    );
    assert_eq!(outcome(&mut conn, finished).await?, Some(Outcome::Silent));
    assert_eq!(outcome(&mut conn, running).await?, None);
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
        failed(FailReason::InputTooLarge),
        Outcome::Expired,
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
    let again = finish(&mut conn, turn, 1, &record(), from, &Outcome::Silent, at(3)).await;
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
