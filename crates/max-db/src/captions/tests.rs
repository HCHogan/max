use max_core::message::{Content, MediaMeta, MediaRef};
use sqlx::PgPool;

use super::*;
use crate::ledger;
use crate::media::{Blob, record};
use crate::testing::{at, commit, group, sender};

fn medium(kind: MediaKind, description: Option<&str>) -> Node {
    Node::Media {
        media: Some(MediaRef::Remote("https://example.com/x".into())),
        meta: MediaMeta {
            kind,
            mime: None,
            size: None,
            name: None,
            description: description.map(Into::into),
        },
    }
}

fn blob(byte: char, picture: bool) -> Blob {
    let sha256 = byte.to_string().repeat(64);
    Blob {
        model_sha256: picture.then(|| sha256.clone()),
        sha256,
        mime: None,
        size: 3,
        width: None,
        height: None,
    }
}

fn caption<'a>(sha256: &'a str, kind: Kind, text: &'a str) -> Caption<'a> {
    Caption {
        sha256,
        kind,
        text,
        skip: false,
        model: Some("test/vision"),
        at: at(0),
    }
}

fn description(row: &ledger::Row, ordinal: u16) -> Option<String> {
    let Content::Message { nodes, .. } = &row.message.content else {
        return None;
    };
    let (_, _, meta) = media(nodes).find(|(n, _, _)| *n == ordinal)?;
    meta.description.clone()
}

#[sqlx::test]
async fn pictures_get_one_caption_and_rows_show_it(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let group = group(&mut conn, "group:30001").await?;
    let xiaoming = sender(group.xiaoming, "小明", None);
    let first = Content::Message {
        reply_to: None,
        nodes: vec![
            medium(MediaKind::Image, None),
            medium(MediaKind::Video, None),
            medium(MediaKind::Image, Some("QQ 说的")),
        ],
    };
    let one = commit(&mut conn, &group, &xiaoming, &first, 0).await?;
    record(&mut conn, one, 0, &blob('a', true), at(0)).await?;
    record(&mut conn, one, 1, &blob('b', false), at(0)).await?;
    record(&mut conn, one, 2, &blob('c', true), at(0)).await?;
    // The same picture again, as a sticker this time.
    let again = Content::Message {
        reply_to: None,
        nodes: vec![medium(MediaKind::Sticker, None)],
    };
    let two = commit(&mut conn, &group, &xiaoming, &again, 1).await?;
    record(&mut conn, two, 0, &blob('a', true), at(1)).await?;
    let sticker = Content::Message {
        reply_to: None,
        nodes: vec![medium(MediaKind::Sticker, None)],
    };
    let three = commit(&mut conn, &group, &xiaoming, &sticker, 2).await?;
    record(&mut conn, three, 0, &blob('d', true), at(2)).await?;

    // Each picture once, from the first message it came in; the video
    // isn't one.
    let expected = vec![
        Uncaptioned {
            message: one,
            ordinal: 0,
            sha256: "a".repeat(64),
            kind: Kind::Image,
        },
        Uncaptioned {
            message: one,
            ordinal: 2,
            sha256: "c".repeat(64),
            kind: Kind::Image,
        },
        Uncaptioned {
            message: three,
            ordinal: 0,
            sha256: "d".repeat(64),
            kind: Kind::Sticker,
        },
    ];
    assert_eq!(uncaptioned(&mut conn, at(0)).await?, expected);
    assert_eq!(
        uncaptioned(&mut conn, at(2)).await?,
        expected[2..],
        "only since"
    );

    let a = "a".repeat(64);
    assert!(!exists(&mut conn, &a).await?);
    assert!(write(&mut conn, &caption(&a, Kind::Image, "一只猫")).await?);
    assert!(
        !write(&mut conn, &caption(&a, Kind::Image, "两只猫")).await?,
        "once"
    );
    assert!(exists(&mut conn, &a).await?);
    let c = "c".repeat(64);
    write(&mut conn, &caption(&c, Kind::Image, "截图")).await?;
    // A model that gave up leaves an empty one: not tried again, not shown.
    let d = "d".repeat(64);
    write(&mut conn, &caption(&d, Kind::Sticker, "")).await?;
    assert_eq!(uncaptioned(&mut conn, at(0)).await?, []);

    let rows = ledger::rows(&mut conn, group.endpoint.conversation, None, three).await?;
    assert_eq!(description(&rows[0], 0).as_deref(), Some("一只猫"));
    assert_eq!(description(&rows[0], 1), None, "no caption");
    assert_eq!(
        description(&rows[0], 2).as_deref(),
        Some("QQ 说的"),
        "its own first"
    );
    assert_eq!(
        description(&rows[1], 0).as_deref(),
        Some("一只猫"),
        "by file"
    );
    assert_eq!(description(&rows[2], 0), None, "empty");
    let recent = ledger::recent(&mut conn, group.endpoint.conversation, three, 5).await?;
    assert_eq!(description(&recent[1], 0).as_deref(), Some("一只猫"));
    Ok(())
}
