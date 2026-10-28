use max_core::ids::PrincipalId;
use max_core::message::{Emote, Role};
use serde_json::json;
use sqlx::PgPool;

use super::*;
use crate::platform::{self, ConversationKind, Known};
use crate::testing::{at, commit, group, said, sender};

fn text(text: &str) -> Vec<Node> {
    vec![Node::Text { text: text.into() }]
}

#[sqlx::test]
async fn every_kind_of_row_reads_back_as_written(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let group = group(&mut conn, "group:30001").await?;
    let xiaoming = sender(group.xiaoming, "小明", Some(Role::Admin));
    let first = commit(&mut conn, &group, &xiaoming, &said("在吗"), 0).await?;
    let contents = [
        Content::Message {
            reply_to: Some(first),
            nodes: text("看这个"),
        },
        Content::Edit {
            target: first,
            nodes: text("在吗？"),
        },
        Content::Message {
            reply_to: None,
            nodes: vec![Node::Emote(Emote {
                platform: Platform::Qq,
                id: "76".into(),
                name: Some("赞".into()),
            })],
        },
        Content::Unsend { target: first },
    ];
    let mut last = first;
    for (minute, content) in (1..).zip(&contents) {
        last = commit(&mut conn, &group, &xiaoming, content, minute).await?;
    }
    let conversation = group.endpoint.conversation;
    let rows = rows(&mut conn, conversation, Some(first), last).await?;
    let read: Vec<&Content> = rows.iter().map(|row| &row.message.content).collect();
    assert_eq!(read, contents.iter().collect::<Vec<_>>());
    let row = &rows[0];
    assert_eq!(row.message.sender, xiaoming);
    assert_eq!(row.message.raw, json!({ "message_id": 1 }));
    assert_eq!(
        (row.message.at, row.command, row.delivery),
        (at(1), false, None)
    );
    assert_eq!(head(&mut conn, conversation).await?, Some(last));
    let endpoint = group.endpoint.id;
    assert_eq!(
        by_native_id(&mut conn, endpoint, "n1").await?,
        Some(rows[0].message.id)
    );
    assert_eq!(by_native_id(&mut conn, endpoint, "n99").await?, None);
    Ok(())
}

#[sqlx::test]
async fn a_row_belongs_to_its_conversation(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let group = group(&mut conn, "group:30001").await?;
    let other = platform::endpoint(
        &mut conn,
        Platform::Qq,
        "group:30002",
        group.max.identity,
        ConversationKind::Group,
        None,
    )
    .await?;
    let xiaoming = sender(group.xiaoming, "小明", None);
    let id = commit(&mut conn, &group, &xiaoming, &said("hi"), 0).await?;
    assert!(
        row(&mut conn, group.endpoint.conversation, id)
            .await?
            .is_some()
    );
    assert_eq!(row(&mut conn, other.conversation, id).await?, None);
    assert_eq!(head(&mut conn, other.conversation).await?, None);
    Ok(())
}

#[sqlx::test]
async fn deliveries_and_platform_ids(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let group = group(&mut conn, "group:30001").await?;
    let max = sender(group.max, "Max", None);
    let sent = commit(&mut conn, &group, &max, &said("一"), 0).await?;
    let failed = commit(&mut conn, &group, &max, &said("二"), 1).await?;
    commit(&mut conn, &group, &max, &said("三"), 2).await?;
    let xiaoming = sender(group.xiaoming, "小明", None);
    let inbound = commit(&mut conn, &group, &xiaoming, &said("四"), 3).await?;
    let endpoint = group.endpoint.id;
    let delivered = Sent::Delivered { native_id: "m1" };
    record_delivery(&mut conn, sent, endpoint, &delivered, at(0)).await?;
    let refused = Sent::Failed { error: "风控" };
    record_delivery(&mut conn, failed, endpoint, &refused, at(1)).await?;
    // Only the third, which never heard back, is unknown; and only once.
    assert_eq!(mark_unknown(&mut conn, Platform::Qq, at(9)).await?, 1);
    assert_eq!(mark_unknown(&mut conn, Platform::Qq, at(9)).await?, 0);
    let rows = rows(&mut conn, group.endpoint.conversation, None, inbound).await?;
    let deliveries: Vec<_> = rows.iter().map(|row| row.delivery).collect();
    assert_eq!(
        deliveries,
        [
            Some(Delivery::Sent),
            Some(Delivery::Failed),
            Some(Delivery::Unknown),
            None
        ]
    );
    assert_eq!(by_native_id(&mut conn, endpoint, "m1").await?, Some(sent));
    assert_eq!(
        by_native_id(&mut conn, endpoint, "n3").await?,
        Some(inbound)
    );
    assert_eq!(by_native_id(&mut conn, endpoint, "n2").await?, None);
    Ok(())
}

#[sqlx::test]
async fn the_roster_takes_each_persons_latest_snapshot(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let group = group(&mut conn, "group:30001").await?;
    let before = sender(group.xiaoming, "小明", Some(Role::Member));
    commit(&mut conn, &group, &before, &said("hi"), 0).await?;
    let after = sender(group.xiaoming, "明哥", Some(Role::Admin));
    commit(&mut conn, &group, &after, &said("hi"), 1).await?;
    let principal = group.xiaoming.principal;
    let people = [principal, PrincipalId(999)];
    let known = platform::roster(&mut conn, group.endpoint.id, &people).await?;
    assert_eq!(
        known,
        [Known {
            principal,
            name: "明哥".into(),
            role: Some(Role::Admin),
        }]
    );
    Ok(())
}
