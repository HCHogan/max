use max_core::message::{Content, MediaKind, MediaMeta, MediaRef, Node};
use serde_json::json;
use sqlx::PgPool;

use super::*;
use crate::ledger::{self, NewMessage};
use crate::summaries::{self, Summary};
use crate::testing::{at, commit, group, said, sender};

/// A made-up vector, its first number `x`.
fn vector(x: f32) -> Vec<f32> {
    let mut vector = vec![0.0; 1024];
    vector[0] = x;
    vector
}

async fn stored(conn: &mut PgConnection) -> sqlx::Result<Vec<(i64, String, Vec<f32>)>> {
    sqlx::query_as(
        "select message_id, model, embedding::real[] from message_embeddings
         union all
         select -summary_id, model, embedding::real[] from summary_embeddings
         order by 1",
    )
    .fetch_all(conn)
    .await
}

#[sqlx::test]
async fn rows_that_say_something(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let group = group(&mut conn, "group:30001").await?;
    let xiaoming = sender(group.xiaoming, "小明", None);
    let conversation = group.endpoint.conversation;
    let deploy = commit(&mut conn, &group, &xiaoming, &said("今晚部署新版本"), 0).await?;
    // Too short to be found by, with or without a quote's handle.
    commit(&mut conn, &group, &xiaoming, &said("好的"), 1).await?;
    let quote = Content::Message {
        reply_to: Some(deploy),
        nodes: vec![Node::Text {
            text: "收到".into(),
        }],
    };
    commit(&mut conn, &group, &xiaoming, &quote, 2).await?;
    // A picture's handle says nothing; the words with it do.
    let picture = Content::Message {
        reply_to: None,
        nodes: vec![
            Node::Text {
                text: "看看这个截图".into(),
            },
            Node::Media {
                media: Some(MediaRef::Remote("https://example.com/x".into())),
                meta: MediaMeta {
                    kind: MediaKind::Image,
                    mime: None,
                    size: None,
                    name: None,
                    description: None,
                },
            },
        ],
    };
    let screenshot = commit(&mut conn, &group, &xiaoming, &picture, 3).await?;
    ledger::insert(
        &mut conn,
        &NewMessage {
            conversation,
            endpoint: group.endpoint.id,
            sender: &xiaoming,
            native_id: Some("n4"),
            quote_id: None,
            sent_at: at(4),
            received_at: at(4),
            command: true,
            content: &said("/persona 部署的时候认真点"),
            raw: &json!({}),
            text: "/persona 部署的时候认真点",
            turn: None,
            segment: None,
        },
    )
    .await?;
    let done = commit(&mut conn, &group, &xiaoming, &said("部署完了没出问题"), 5).await?;
    let keys = |ids: &[MessageId]| -> Vec<Key> { ids.iter().map(|id| Key::Message(*id)).collect() };

    let missing = unembedded(&mut conn, "m3", None, 10).await?;
    assert_eq!(missing, keys(&[done, screenshot, deploy]));
    let older = unembedded(&mut conn, "m3", Some(Key::Message(done)), 1).await?;
    assert_eq!(older, keys(&[screenshot]));
    let all: Vec<Key> = (deploy.0..=done.0)
        .map(|id| Key::Message(MessageId(id)))
        .collect();
    let texts = to_embed(&mut conn, "m3", &all).await?;
    assert_eq!(
        texts,
        [
            (
                Key::Message(done),
                conversation,
                "部署完了没出问题".to_owned()
            ),
            (
                Key::Message(screenshot),
                conversation,
                "看看这个截图".to_owned()
            ),
            (
                Key::Message(deploy),
                conversation,
                "今晚部署新版本".to_owned()
            ),
        ]
    );

    // Written, a row is done; by another model, it is still to do, and
    // this model's vector takes its place.
    let written = [
        (Key::Message(deploy), conversation, vector(1.0)),
        (Key::Message(screenshot), conversation, vector(2.0)),
    ];
    write(&mut conn, "m3", &written, at(9)).await?;
    let other = [(Key::Message(done), conversation, vector(3.0))];
    write(&mut conn, "old", &other, at(9)).await?;
    let missing = unembedded(&mut conn, "m3", None, 10).await?;
    assert_eq!(missing, keys(&[done]));
    assert!(
        to_embed(&mut conn, "m3", &keys(&[deploy]))
            .await?
            .is_empty()
    );
    let again = [(Key::Message(done), conversation, vector(4.0))];
    write(&mut conn, "m3", &again, at(9)).await?;
    assert!(unembedded(&mut conn, "m3", None, 10).await?.is_empty());
    assert_eq!(
        stored(&mut conn).await?,
        [
            (deploy.0, "m3".to_owned(), vector(1.0)),
            (screenshot.0, "m3".to_owned(), vector(2.0)),
            (done.0, "m3".to_owned(), vector(4.0)),
        ]
    );
    Ok(())
}

#[sqlx::test]
async fn active_summaries(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let group = group(&mut conn, "group:30001").await?;
    let xiaoming = sender(group.xiaoming, "小明", None);
    let conversation = group.endpoint.conversation;
    let mut ids = Vec::new();
    for minute in 0..4 {
        ids.push(commit(&mut conn, &group, &xiaoming, &said("聊聊部署"), minute).await?);
    }
    let summary = |first: usize, last: usize, title: &str, full: &str| Summary {
        first: ids[first],
        last: ids[last],
        started_at: at(first as i64),
        ended_at: at(last as i64),
        title: title.into(),
        kind: "mixed".into(),
        importance: 50,
        full: full.into(),
        brief: None,
        line: None,
    };
    let titled = summaries::insert(
        &mut conn,
        conversation,
        &summary(0, 1, "部署", "定了方案。"),
        "m",
        at(9),
    )
    .await?;
    let untitled = summaries::insert(
        &mut conn,
        conversation,
        &summary(2, 2, "", "别的。"),
        "m",
        at(9),
    )
    .await?;
    let old = summaries::insert(
        &mut conn,
        conversation,
        &summary(3, 3, "旧的", "被取代了。"),
        "m",
        at(9),
    )
    .await?;
    sqlx::query!(
        "update summaries set status = 'superseded', superseded_by = $1 where id = $2",
        titled.0,
        old.0
    )
    .execute(&mut *conn)
    .await?;

    // Summaries first, then rows, each newest first, a page at a time.
    let rows: Vec<Key> = ids.iter().rev().map(|id| Key::Message(*id)).collect();
    let missing = unembedded(&mut conn, "m3", None, 3).await?;
    assert_eq!(
        missing,
        [Key::Summary(untitled), Key::Summary(titled), rows[0]]
    );
    let next = unembedded(&mut conn, "m3", Some(Key::Summary(untitled)), 2).await?;
    assert_eq!(next, [Key::Summary(titled), rows[0]]);
    let next = unembedded(&mut conn, "m3", Some(rows[0]), 10).await?;
    assert_eq!(next, rows[1..]);
    let keys = [
        Key::Summary(titled),
        Key::Summary(untitled),
        Key::Summary(old),
    ];
    assert_eq!(
        to_embed(&mut conn, "m3", &keys).await?,
        [
            (Key::Summary(untitled), conversation, "别的。".to_owned()),
            (
                Key::Summary(titled),
                conversation,
                "部署\n定了方案。".to_owned()
            ),
        ]
    );
    let written = [(Key::Summary(titled), conversation, vector(1.0))];
    write(&mut conn, "m3", &written, at(9)).await?;
    let missing = unembedded(&mut conn, "m3", None, 1).await?;
    assert_eq!(missing, [Key::Summary(untitled)]);
    assert_eq!(
        stored(&mut conn).await?,
        [(-titled.0, "m3".to_owned(), vector(1.0))]
    );
    Ok(())
}
