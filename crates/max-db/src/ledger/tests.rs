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
    let delivered = Sent::Delivered {
        native_id: "m1",
        quote_id: Some("REFIDX_1"),
    };
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
    assert_eq!(
        by_quote_id(&mut conn, endpoint, "REFIDX_1").await?,
        Some(sent)
    );
    assert_eq!(
        quote_id(&mut conn, sent).await?.as_deref(),
        Some("REFIDX_1")
    );
    assert_eq!(quote_id(&mut conn, failed).await?, None);
    Ok(())
}

#[sqlx::test]
async fn what_an_unsend_finds_and_leaves(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let group = group(&mut conn, "group:30001").await?;
    let endpoint = group.endpoint.id;
    let max = sender(group.max, "Max", None);
    let xiaoming = sender(group.xiaoming, "小明", None);
    let heard = commit(&mut conn, &group, &xiaoming, &said("广告"), 0).await?;
    let mine = commit(&mut conn, &group, &max, &said("一"), 1).await?;
    let queued = commit(&mut conn, &group, &max, &said("二"), 2).await?;
    let delivered = Sent::Delivered {
        native_id: "m1",
        quote_id: None,
    };
    record_delivery(&mut conn, mine, endpoint, &delivered, at(3)).await?;
    let heard_as = native(&mut conn, heard, endpoint).await?;
    assert_eq!(heard_as, Some(("n0".into(), at(0))));
    let mine_as = native(&mut conn, mine, endpoint).await?;
    assert_eq!(mine_as, Some(("m1".into(), at(3))));
    assert_eq!(native(&mut conn, queued, endpoint).await?, None);

    // Max takes back its own, too late, and then 小明's: an unsend that
    // went through is sent without an id of its own.
    let unsend = |target| Content::Unsend { target };
    let late = commit(&mut conn, &group, &max, &unsend(mine), 4).await?;
    let refused = Sent::Failed { error: "40064004" };
    record_delivery(&mut conn, late, endpoint, &refused, at(4)).await?;
    assert!(!unsent(&mut conn, mine).await?);
    let done = commit(&mut conn, &group, &max, &unsend(heard), 5).await?;
    assert!(unsent(&mut conn, heard).await?, "on its way");
    record_delivery(&mut conn, done, endpoint, &Sent::Done, at(5)).await?;
    assert!(unsent(&mut conn, heard).await?);
    let rows = rows(&mut conn, group.endpoint.conversation, Some(queued), done).await?;
    let deliveries: Vec<_> = rows.iter().map(|row| row.delivery).collect();
    assert_eq!(deliveries, [Some(Delivery::Failed), Some(Delivery::Sent)]);
    Ok(())
}

#[sqlx::test]
async fn quoting_someone_by_their_quote_id(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let group = group(&mut conn, "group:30001").await?;
    let xiaoming = sender(group.xiaoming, "小明", None);
    let content = said("在吗");
    let id = insert(
        &mut conn,
        &NewMessage {
            conversation: group.endpoint.conversation,
            endpoint: group.endpoint.id,
            sender: &xiaoming,
            native_id: Some("ROBOT1.0_x"),
            quote_id: Some("REFIDX_7"),
            sent_at: at(0),
            received_at: at(0),
            command: false,
            content: &content,
            raw: &json!({}),
            text: "在吗",
            turn: None,
            segment: None,
        },
    )
    .await?;
    let endpoint = group.endpoint.id;
    assert_eq!(
        by_quote_id(&mut conn, endpoint, "REFIDX_7").await?,
        Some(id)
    );
    assert_eq!(by_quote_id(&mut conn, endpoint, "ROBOT1.0_x").await?, None);
    assert_eq!(quote_id(&mut conn, id).await?.as_deref(), Some("REFIDX_7"));
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

#[sqlx::test]
async fn what_the_classifier_and_the_sender_read(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let group = group(&mut conn, "group:30001").await?;
    let max = sender(group.max, "Max", None);
    let xiaoming = sender(group.xiaoming, "小明", None);
    let mut ids = Vec::new();
    for minute in 0..5 {
        let who = if minute == 3 { &max } else { &xiaoming };
        ids.push(
            commit(
                &mut conn,
                &group,
                who,
                &said(&format!("第{minute}条")),
                minute,
            )
            .await?,
        );
    }
    let conversation = group.endpoint.conversation;
    let before: Vec<_> = recent(&mut conn, conversation, ids[4], 2)
        .await?
        .into_iter()
        .map(|row| row.message.id)
        .collect();
    assert_eq!(before, [ids[2], ids[3]]);

    let endpoint = group.endpoint.id;
    sqlx::query!("update messages set text = sent_at::text")
        .execute(&mut *conn)
        .await?;
    let said = said_by(&mut conn, endpoint, group.max.identity, 10).await?;
    assert_eq!(said.iter().map(|(id, _)| *id).collect::<Vec<_>>(), [ids[3]]);

    Ok(())
}
