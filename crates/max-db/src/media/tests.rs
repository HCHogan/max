use max_core::message::{Content, MediaKind, MediaMeta};
use sqlx::PgPool;

use super::*;
use crate::testing::{at, commit, group, said, sender};

fn picture(url: &str) -> Node {
    Node::Media {
        media: Some(MediaRef::Remote(url.into())),
        meta: MediaMeta {
            kind: MediaKind::Image,
            mime: Some("image/png".into()),
            size: Some(3),
            name: None,
            description: None,
        },
    }
}

fn blob(byte: char) -> Blob {
    Blob {
        sha256: byte.to_string().repeat(64),
        mime: Some("image/png".into()),
        size: 3,
        width: Some(2),
        height: Some(1),
        model_sha256: None,
    }
}

#[sqlx::test]
async fn pending_until_every_picture_is_recorded(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let group = group(&mut conn, "group:30001").await?;
    let xiaoming = sender(group.xiaoming, "小明", None);
    commit(&mut conn, &group, &xiaoming, &said("没图"), 0).await?;
    let two = Content::Message {
        reply_to: None,
        nodes: vec![
            picture("https://example.com/a.png"),
            Node::Text { text: "和".into() },
            picture("https://example.com/b.png"),
        ],
    };
    let id = commit(&mut conn, &group, &xiaoming, &two, 1).await?;

    let all = vec![
        (0, MediaKind::Image, "https://example.com/a.png".to_owned()),
        (1, MediaKind::Image, "https://example.com/b.png".to_owned()),
    ];
    let expected = vec![Pending {
        message: id,
        remote: all,
    }];
    assert_eq!(pending(&mut conn, at(0)).await?, expected);
    assert_eq!(pending(&mut conn, at(2)).await?, [], "only since");

    record(&mut conn, id, 1, &blob('b'), at(1)).await?;
    let left = pending(&mut conn, at(0)).await?;
    assert_eq!(
        left[0].remote,
        [(0, MediaKind::Image, "https://example.com/a.png".to_owned())]
    );

    // The same bytes twice: one media row, two links.
    record(&mut conn, id, 0, &blob('b'), at(3)).await?;
    assert_eq!(pending(&mut conn, at(0)).await?, []);
    let b = "b".repeat(64);
    assert_eq!(downloaded(&mut conn, id).await?, [(0, b.clone()), (1, b)]);
    let seen = sqlx::query_scalar!("select first_seen_at from media")
        .fetch_all(&mut *conn)
        .await?;
    assert_eq!(seen, [at(1)]);
    Ok(())
}

#[sqlx::test]
async fn what_can_be_sent_again(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let group = group(&mut conn, "group:30001").await?;
    let xiaoming = sender(group.xiaoming, "小明", None);
    let sticker = Node::Media {
        media: Some(MediaRef::Remote("https://example.com/s.gif".into())),
        meta: MediaMeta {
            kind: MediaKind::Sticker,
            mime: None,
            size: None,
            name: None,
            description: None,
        },
    };
    let content = Content::Message {
        reply_to: None,
        nodes: vec![picture("https://example.com/a.png"), sticker],
    };
    let id = commit(&mut conn, &group, &xiaoming, &content, 0).await?;
    record(&mut conn, id, 1, &blob('b'), at(1)).await?;

    let found = stored(&mut conn, id, 1).await?;
    let expected = Stored {
        conversation: group.endpoint.conversation,
        kind: MediaKind::Sticker,
        name: None,
        sha256: "b".repeat(64),
        mime: Some("image/png".into()),
        size: 3,
    };
    assert_eq!(found, Some(expected));
    // Not downloaded, or no such medium.
    assert_eq!(stored(&mut conn, id, 0).await?, None);
    assert_eq!(stored(&mut conn, id, 2).await?, None);
    Ok(())
}
