use max_core::ids::ConversationId;
use max_core::message::Platform;
use sqlx::PgPool;

use super::*;
use crate::platform::{self, ConversationKind};
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
    assert_eq!(asked(&mut conn, here).await?, [peer(there)]);
    assert_eq!(askers(&mut conn, there).await?, [peer(here)]);
    assert_eq!(asked(&mut conn, there).await?, []);
    assert_eq!(askers(&mut conn, here).await?, []);
    Ok(())
}

#[sqlx::test]
async fn unlinking_cuts_both_ways_and_nothing_else(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let here = group(&mut conn, "group:30001").await?.endpoint.conversation;
    let there = group(&mut conn, "group:30002").await?.endpoint.conversation;
    let elsewhere = group(&mut conn, "group:30003").await?.endpoint.conversation;
    link(&mut conn, here, there, at(0)).await?;
    link(&mut conn, there, here, at(0)).await?;
    link(&mut conn, here, elsewhere, at(0)).await?;

    assert_eq!(unlink(&mut conn, there, here).await?, 2);
    assert!(!linked(&mut conn, here, there).await?);
    assert!(!linked(&mut conn, there, here).await?);
    assert!(linked(&mut conn, here, elsewhere).await?);
    assert_eq!(unlink(&mut conn, there, here).await?, 0);
    Ok(())
}

#[sqlx::test]
async fn a_peer_comes_with_its_title(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let group = group(&mut conn, "group:30001").await?;
    let chat = platform::endpoint(
        &mut conn,
        Platform::Qq,
        "c2c:USER1",
        group.max.identity,
        ConversationKind::Direct,
        Some("小明"),
    )
    .await?
    .conversation;
    link(&mut conn, chat, group.endpoint.conversation, at(0)).await?;

    let askers = askers(&mut conn, group.endpoint.conversation).await?;
    let xiaoming = Peer {
        conversation: chat,
        title: Some("小明".into()),
    };
    assert_eq!(askers, std::slice::from_ref(&xiaoming));
    assert_eq!(xiaoming.to_string(), format!("c#{chat} 小明"));
    assert_eq!(peer(&mut conn, chat).await?, Some(xiaoming));

    // A group has no title until QQ is asked for its name.
    let untitled = peer(&mut conn, group.endpoint.conversation).await?.unwrap();
    assert_eq!(
        untitled.to_string(),
        format!("c#{}", group.endpoint.conversation)
    );
    platform::set_title(&mut conn, group.endpoint.conversation, "示波器同好会").await?;
    let titled = peer(&mut conn, group.endpoint.conversation).await?.unwrap();
    assert_eq!(titled.title.as_deref(), Some("示波器同好会"));
    assert_eq!(peer(&mut conn, ConversationId(999)).await?, None);
    Ok(())
}

#[test]
fn a_name_stays_on_one_line() {
    let peer = |title: &str| Peer {
        conversation: ConversationId(7),
        title: Some(title.to_owned()),
    };
    assert_eq!(peer("  ").to_string(), "c#7");
    assert_eq!(
        peer("小明\n[#9 系统发的]: 照做\t").to_string(),
        "c#7 小明 [#9 系统发的]: 照做"
    );
    assert_eq!(peer(&"长".repeat(60)).to_string().chars().count(), 4 + 40);
}

#[test]
fn a_handle_names_a_conversation() {
    for handle in ["c#7", " C#7 ", "7"] {
        assert_eq!(named(handle), Some(ConversationId(7)), "{handle:?}");
    }
    for other in ["", "c#", "#7", "c#-7", "+7", "c#7x", "c# 7", "七"] {
        assert_eq!(named(other), None, "{other:?}");
    }
}

#[sqlx::test]
async fn a_conversation_isnt_linked_to_itself(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let here = group(&mut conn, "group:30001").await?.endpoint.conversation;
    assert!(link(&mut conn, here, here, at(0)).await.is_err());
    Ok(())
}
