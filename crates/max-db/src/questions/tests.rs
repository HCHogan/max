use sqlx::PgPool;

use super::*;
use crate::links;
use crate::testing::{at, group};

#[sqlx::test]
async fn a_question_waits_until_it_is_answered_once(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let here = group(&mut conn, "group:30001").await?.endpoint.conversation;
    let there = group(&mut conn, "group:30002").await?.endpoint.conversation;
    let peer = |conversation| Peer {
        conversation,
        title: None,
    };
    // A week is 10,080 minutes.
    let week = 10_080;

    let old = number(&mut conn).await?;
    keep(&mut conn, old, here, there, "上周的", at(1)).await?;
    let asked = number(&mut conn).await?;
    assert!(asked > old);
    keep(&mut conn, asked, here, there, "周五来吗", at(5)).await?;
    assert_eq!(count(&mut conn, here, there, at(6)).await?, 2);
    assert_eq!(count(&mut conn, there, here, at(6)).await?, 0);

    // Each side is shown it, with the other's name, and not the one
    // asked over a week ago.
    let now = at(week + 1);
    let waits = |peer| Waiting {
        number: asked,
        peer,
        question: "周五来吗".into(),
        asked_at: at(5),
    };
    let (to_answer, unanswered) = waiting(&mut conn, there, now).await?;
    assert_eq!((to_answer, unanswered), (vec![waits(peer(here))], vec![]));
    let (to_answer, unanswered) = waiting(&mut conn, here, now).await?;
    assert_eq!((to_answer, unanswered), (vec![], vec![waits(peer(there))]));

    // One that is too old isn't answered, nor is another conversation's.
    assert_eq!(take(&mut conn, old, there, now).await?, None);
    assert_eq!(take(&mut conn, asked, here, now).await?, None);
    let taken = Taken {
        asker: here,
        question: "周五来吗".into(),
    };
    assert_eq!(take(&mut conn, asked, there, now).await?, Some(taken));
    assert_eq!(take(&mut conn, asked, there, now).await?, None);

    // The next question drops the old one; `/unlink` and `/stop` drop
    // what waits.
    let next = number(&mut conn).await?;
    keep(&mut conn, next, here, there, "那周六呢", now).await?;
    assert_eq!(count(&mut conn, here, there, at(6)).await?, 1);
    links::unlink(&mut conn, there, here).await?;
    assert_eq!(count(&mut conn, here, there, now).await?, 0);
    let next = number(&mut conn).await?;
    keep(&mut conn, next, here, there, "周日", now).await?;
    let taken = Taken {
        asker: here,
        question: "周日".into(),
    };
    assert_eq!(take_all(&mut conn, there, now).await?, [taken]);
    assert_eq!(waiting(&mut conn, here, now).await?, (vec![], vec![]));
    Ok(())
}
