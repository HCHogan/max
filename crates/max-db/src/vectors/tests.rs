use max_core::message::{Content, MediaKind, MediaMeta, MediaRef, Node};
use serde_json::json;
use sqlx::PgPool;

use super::*;
use crate::ledger::{self, NewMessage};
use crate::testing::{at, commit, group, said, sender};

/// A made-up vector, its first number `x`.
fn vector(x: f32) -> Vec<f32> {
    let mut vector = vec![0.0; 1024];
    vector[0] = x;
    vector
}

async fn stored(conn: &mut PgConnection) -> sqlx::Result<Vec<(i64, String, Vec<f32>)>> {
    sqlx::query_as("select message_id, model, embedding::real[] from message_embeddings order by 1")
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

    let missing = unembedded(&mut conn, "m3", None, 10).await?;
    assert_eq!(missing, [done, screenshot, deploy]);
    let older = unembedded(&mut conn, "m3", Some(done), 1).await?;
    assert_eq!(older, [screenshot]);
    let all: Vec<MessageId> = (deploy.0..=done.0).map(MessageId).collect();
    let texts = to_embed(&mut conn, "m3", &all).await?;
    assert_eq!(
        texts,
        [
            (done, conversation, "部署完了没出问题".to_owned()),
            (screenshot, conversation, "看看这个截图".to_owned()),
            (deploy, conversation, "今晚部署新版本".to_owned()),
        ]
    );

    // Written, a row is done; by another model, it is still to do, and
    // this model's vector takes its place.
    let written = [
        (deploy, conversation, vector(1.0)),
        (screenshot, conversation, vector(2.0)),
    ];
    write(&mut conn, "m3", &written, at(9)).await?;
    let other = [(done, conversation, vector(3.0))];
    write(&mut conn, "old", &other, at(9)).await?;
    let missing = unembedded(&mut conn, "m3", None, 10).await?;
    assert_eq!(missing, [done]);
    assert!(to_embed(&mut conn, "m3", &[deploy]).await?.is_empty());
    let again = [(done, conversation, vector(4.0))];
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
