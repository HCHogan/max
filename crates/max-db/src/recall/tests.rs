use max_core::message::{Content, MediaKind, MediaMeta, MediaRef, Node};
use serde_json::json;
use sqlx::PgPool;

use super::*;
use crate::captions::{self, Caption, Kind};
use crate::ledger::{self, NewMessage};
use crate::media::{Blob, record};
use crate::summaries::{self, Summary};
use crate::testing::{Group, at, commit, group, said, sender};

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
        from: Some(at(1)),
        until: Some(at(6)),
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

#[sqlx::test]
async fn active_summaries_by_any_level(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let group = group(&mut conn, "group:30001").await?;
    let xiaoming = sender(group.xiaoming, "小明", None);
    let mut ids = Vec::new();
    for minute in 0..6 {
        ids.push(commit(&mut conn, &group, &xiaoming, &said("聊"), minute).await?);
    }
    let conversation = group.endpoint.conversation;
    let summary =
        |first: usize, last: usize, title: &str, full: &str, line: Option<&str>| Summary {
            first: ids[first],
            last: ids[last],
            started_at: at(first as i64),
            ended_at: at(last as i64),
            title: title.into(),
            kind: "mixed".into(),
            importance: 50,
            full: full.into(),
            brief: None,
            line: line.map(Into::into),
        };
    let insert = async |conn: &mut PgConnection, summary: &Summary| {
        summaries::insert(conn, conversation, summary, "m", at(9)).await
    };
    let early = insert(&mut conn, &summary(0, 1, "部署", "定了方案。", None)).await?;
    let middle = insert(&mut conn, &summary(2, 3, "", "别的。", Some("又说起部署"))).await?;
    // Superseded, as a rebuild would leave it.
    let old = insert(&mut conn, &summary(4, 5, "部署上线", "定了方案。", None)).await?;
    sqlx::query!(
        "update summaries set status = 'superseded', superseded_by = $1 where id = $2",
        early.0,
        old.0
    )
    .execute(&mut *conn)
    .await?;

    let terms = patterns(&["部署", "方案"]);
    let found = summaries(&mut conn, &query(conversation, &terms)).await?;
    assert_eq!(found, [(early, vec![0, 1]), (middle, vec![0])]);
    // Overlapping the window is enough.
    let window = Query {
        from: Some(at(1)),
        until: Some(at(2)),
        ..query(conversation, &terms)
    };
    assert_eq!(summaries(&mut conn, &window).await?, [(early, vec![0, 1])]);
    Ok(())
}
