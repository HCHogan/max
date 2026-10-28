use sqlx::PgPool;

use super::*;
use crate::testing::{at, commit, group, said, sender};

fn summary(first: MessageId, last: MessageId) -> Summary {
    Summary {
        first,
        last,
        started_at: at(0),
        ended_at: at(5),
        title: "国庆去哪".into(),
        kind: "plan".into(),
        importance: 60,
        full: "小明想去重庆……".into(),
        brief: Some("定了重庆。".into()),
        line: None,
    }
}

#[sqlx::test]
async fn active_summaries_never_overlap(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let group = group(&mut conn, "group:30001").await?;
    let xiaoming = sender(group.xiaoming, "小明", None);
    let mut ids = Vec::new();
    for minute in 0..6 {
        ids.push(commit(&mut conn, &group, &xiaoming, &said("聊"), minute).await?);
    }
    let conversation = group.endpoint.conversation;
    let later = insert(
        &mut conn,
        conversation,
        &summary(ids[3], ids[5]),
        "m",
        at(9),
    )
    .await?;
    let earlier = insert(
        &mut conn,
        conversation,
        &summary(ids[0], ids[2]),
        "m",
        at(9),
    )
    .await?;
    let overlapping = insert(
        &mut conn,
        conversation,
        &summary(ids[2], ids[3]),
        "m",
        at(9),
    )
    .await;
    assert!(overlapping.is_err());

    let all = active(&mut conn, conversation, None).await?;
    let order: Vec<SummaryId> = all.iter().map(|(id, _)| *id).collect();
    assert_eq!(order, [earlier, later]);
    assert_eq!(all[0].1, summary(ids[0], ids[2]));
    // !clear --all after the earlier one leaves only the later.
    let cleared = active(&mut conn, conversation, Some(ids[2])).await?;
    assert_eq!(cleared.len(), 1);
    Ok(())
}

#[sqlx::test]
async fn a_run_publishes_all_of_its_summaries_or_none(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let group = group(&mut conn, "group:30001").await?;
    let xiaoming = sender(group.xiaoming, "小明", None);
    let mut ids = Vec::new();
    for minute in 0..6 {
        ids.push(commit(&mut conn, &group, &xiaoming, &said("聊"), minute).await?);
    }
    let conversation = group.endpoint.conversation;
    let run = |first, last, output, error| Run {
        conversation,
        first,
        last,
        reason: Reason::Quiet,
        model: "m",
        output,
        error,
        started_at: at(9),
        finished_at: at(10),
    };
    failed(&mut conn, &run(ids[0], ids[5], None, Some("timed out"))).await?;
    let both = [summary(ids[0], ids[2]), summary(ids[3], ids[5])];
    let published = publish(&mut conn, &run(ids[0], ids[5], Some("{}"), None), &both).await?;
    assert_eq!(published.len(), 2);
    // Overlapping what is published: the run isn't recorded either.
    let again = publish(
        &mut conn,
        &run(ids[2], ids[3], Some("{}"), None),
        &[summary(ids[2], ids[3])],
    )
    .await;
    assert!(again.is_err());
    let runs: i64 = sqlx::query_scalar("select count(*) from summary_runs")
        .fetch_one(&mut *conn)
        .await?;
    assert_eq!(runs, 2);
    assert_eq!(active(&mut conn, conversation, None).await?.len(), 2);
    Ok(())
}
