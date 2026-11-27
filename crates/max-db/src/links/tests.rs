use sqlx::PgPool;

use super::*;
use crate::testing::{at, group};

#[sqlx::test]
async fn an_edge_runs_one_way(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let here = group(&mut conn, "group:30001").await?.endpoint.conversation;
    let there = group(&mut conn, "group:30002").await?.endpoint.conversation;

    assert!(link(&mut conn, here, there, at(0)).await?);
    assert!(linked(&mut conn, here, there).await?);
    assert!(!linked(&mut conn, there, here).await?);
    // Made once: a second `/link` changes nothing.
    assert!(!link(&mut conn, here, there, at(1)).await?);

    let peer = |conversation| Peer {
        conversation,
        title: None,
    };
    assert_eq!(enterable(&mut conn, here).await?, [peer(there)]);
    assert_eq!(enterers(&mut conn, there).await?, [peer(here)]);
    assert_eq!(enterable(&mut conn, there).await?, []);
    assert_eq!(enterers(&mut conn, here).await?, []);
    Ok(())
}
