use max_core::message::{Content, MediaKind, MediaMeta, MediaRef, Node};
use serde_json::json;
use sqlx::PgPool;

use super::*;
use crate::captions::{self, Caption, Kind};
use crate::ledger::{self, NewMessage};
use crate::media::{Blob, record};
use crate::testing::{Group, at, commit, group, said, sender};
use crate::vectors;

fn picture(kind: MediaKind) -> Content {
    Content::Message {
        reply_to: None,
        nodes: vec![Node::Media {
            media: Some(MediaRef::Remote("https://example.com/x".into())),
            meta: MediaMeta {
                kind,
                mime: None,
                size: None,
                name: None,
                description: None,
            },
        }],
    }
}

/// A picture at `minute`, captioned with `caption`.
async fn captioned(
    conn: &mut PgConnection,
    group: &Group,
    kind: MediaKind,
    byte: char,
    caption: &str,
    minute: i64,
) -> sqlx::Result<MessageId> {
    let xiaoming = sender(group.xiaoming, "小明", None);
    let id = commit(conn, group, &xiaoming, &picture(kind), minute).await?;
    let sha256 = byte.to_string().repeat(64);
    let blob = Blob {
        model_sha256: Some(sha256.clone()),
        sha256: sha256.clone(),
        mime: None,
        size: 3,
        width: None,
        height: None,
    };
    record(conn, id, 0, &blob, at(minute)).await?;
    let kind = if kind == MediaKind::Sticker {
        Kind::Sticker
    } else {
        Kind::Image
    };
    let caption = Caption {
        sha256: &sha256,
        kind,
        text: caption,
        skip: false,
        model: None,
        at: at(minute),
    };
    captions::write(conn, &caption).await?;
    Ok(id)
}

fn patterns(terms: &[&str]) -> Vec<String> {
    terms.iter().map(|term| format!("%{term}%")).collect()
}

fn query(conversation: ConversationId, patterns: &[String]) -> Query<'_> {
    Query {
        conversation,
        patterns,
        from: None,
        until: None,
        sender: None,
        limit: 10,
    }
}

#[sqlx::test]
async fn rows_with_the_most_terms_come_first(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let group = group(&mut conn, "group:30001").await?;
    let other = crate::testing::group(&mut conn, "group:30002").await?;
    let xiaoming = sender(group.xiaoming, "小明", None);
    let max = sender(group.max, "maxx", None);
    let both = commit(&mut conn, &group, &xiaoming, &said("部署方案定了吗"), 0).await?;
    let github = commit(
        &mut conn,
        &group,
        &xiaoming,
        &said("GitHub 上的部署脚本"),
        1,
    )
    .await?;
    let error = captioned(
        &mut conn,
        &group,
        MediaKind::Image,
        'a',
        "服务器报错的截图",
        2,
    )
    .await?;
    let sticker = captioned(&mut conn, &group, MediaKind::Sticker, 'b', "翻白眼的猫", 3).await?;
    let taken = commit(&mut conn, &group, &xiaoming, &said("部署炸了"), 4).await?;
    commit(
        &mut conn,
        &group,
        &xiaoming,
        &Content::Unsend { target: taken },
        5,
    )
    .await?;
    let mine = commit(&mut conn, &group, &max, &said("方案在 wiki 上"), 6).await?;
    ledger::insert(
        &mut conn,
        &NewMessage {
            conversation: group.endpoint.conversation,
            endpoint: group.endpoint.id,
            sender: &xiaoming,
            native_id: Some("n7"),
            quote_id: None,
            sent_at: at(7),
            received_at: at(7),
            command: true,
            content: &said("/persona 部署方案"),
            raw: &json!({}),
            text: "/persona 部署方案",
            turn: None,
            segment: None,
        },
    )
    .await?;
    let elsewhere = sender(other.xiaoming, "小明", None);
    commit(&mut conn, &other, &elsewhere, &said("部署方案"), 8).await?;
    let conversation = group.endpoint.conversation;

    let terms = patterns(&["部署", "方案"]);
    let found = messages(&mut conn, &query(conversation, &terms)).await?;
    assert_eq!(
        found,
        [(both, vec![0, 1]), (mine, vec![1]), (github, vec![0])]
    );

    // ASCII without regard to case; a picture or a sticker by its caption.
    let terms = patterns(&["github", "服务器", "猫"]);
    let found = messages(&mut conn, &query(conversation, &terms)).await?;
    assert_eq!(
        found,
        [(sticker, vec![2]), (error, vec![1]), (github, vec![0])]
    );

    let terms = patterns(&["部署", "方案"]);
    let window = Query {
        from: Some(github),
        until: Some(mine),
        ..query(conversation, &terms)
    };
    let found = messages(&mut conn, &window).await?;
    assert_eq!(found, [(github, vec![0])]);
    let one = Query {
        limit: 1,
        ..query(conversation, &terms)
    };
    assert_eq!(messages(&mut conn, &one).await?, [(both, vec![0, 1])]);
    Ok(())
}

fn toward(x: f32, y: f32) -> Vec<f32> {
    let mut vector = vec![0.0; 1024];
    vector[0] = x;
    vector[1] = y;
    vector
}

/// The ids found, and their similarities to two places.
fn rounded<T: Copy>(found: &[Near<T>]) -> Vec<(T, f32)> {
    let round = |similarity: f32| (similarity * 100.0).round() / 100.0;
    found.iter().map(|(id, near)| (*id, round(*near))).collect()
}

#[sqlx::test]
async fn rows_by_meaning(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let group = group(&mut conn, "group:30001").await?;
    let other = crate::testing::group(&mut conn, "group:30002").await?;
    let xiaoming = sender(group.xiaoming, "小明", None);
    let conversation = group.endpoint.conversation;
    let mut said_at = async |group: &Group, words: &str, minute: i64| {
        commit(&mut conn, group, &xiaoming, &said(words), minute).await
    };
    let same = said_at(&group, "今晚上线", 0).await?;
    let near = said_at(&group, "部署时间", 1).await?;
    let far = said_at(&group, "中午吃面", 2).await?;
    let taken = said_at(&group, "上线炸了", 3).await?;
    let stale = said_at(&group, "上线了吗", 5).await?;
    let elsewhere = said_at(&other, "今晚上线", 6).await?;
    commit(
        &mut conn,
        &group,
        &xiaoming,
        &Content::Unsend { target: taken },
        4,
    )
    .await?;
    let other_conversation = other.endpoint.conversation;
    let rows = [
        (same, conversation, toward(1.0, 0.0)),
        (near, conversation, toward(1.0, 1.0)),
        (far, conversation, toward(0.0, 1.0)),
        (taken, conversation, toward(1.0, 0.0)),
        (elsewhere, other_conversation, toward(1.0, 0.0)),
    ];
    vectors::write(&mut conn, "m3", &rows, at(9)).await?;
    // Another model's doesn't count.
    let old = [(stale, conversation, toward(1.0, 0.0))];
    vectors::write(&mut conn, "old", &old, at(9)).await?;

    let query = query(conversation, &[]);
    let found = near_messages(&mut conn, &query, "m3", &toward(1.0, 0.0)).await?;
    assert_eq!(rounded(&found), [(same, 1.0), (near, 0.71), (far, 0.0)]);
    let window = Query {
        from: Some(near),
        until: Some(far),
        ..query.clone()
    };
    let found = near_messages(&mut conn, &window, "m3", &toward(1.0, 0.0)).await?;
    assert_eq!(rounded(&found), [(near, 0.71)]);
    let one = Query {
        limit: 1,
        ..query.clone()
    };
    let found = near_messages(&mut conn, &one, "m3", &toward(0.0, 1.0)).await?;
    assert_eq!(rounded(&found), [(far, 1.0)]);

    Ok(())
}
