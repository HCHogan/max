use max_core::message::{Content, MediaKind, MediaMeta, MediaRef, Node};
use sqlx::PgPool;

use super::*;
use crate::captions::{self, Caption, Kind};
use crate::media::{Blob, record};
use crate::testing::{Group, at, commit, group, sender};

fn medium(kind: MediaKind) -> Node {
    Node::Media {
        media: Some(MediaRef::Remote("https://example.com/x".into())),
        meta: MediaMeta {
            kind,
            mime: None,
            size: None,
            name: None,
            description: None,
        },
    }
}

fn sha(letter: char) -> String {
    letter.to_string().repeat(64)
}

/// A row of 小明's at `minute` with these media, the files by letter.
async fn row(
    conn: &mut PgConnection,
    group: &Group,
    minute: i64,
    media: &[(MediaKind, char)],
) -> sqlx::Result<MessageId> {
    let mut nodes = vec![Node::Text { text: "看".into() }];
    nodes.extend(media.iter().map(|(kind, _)| medium(*kind)));
    let content = Content::Message {
        reply_to: None,
        nodes,
    };
    let xiaoming = sender(group.xiaoming, "小明", None);
    let id = commit(conn, group, &xiaoming, &content, minute).await?;
    for (ordinal, (_, letter)) in (0..).zip(media) {
        let blob = Blob {
            sha256: sha(*letter),
            mime: None,
            size: 3,
            width: None,
            height: None,
            model_sha256: Some(sha(*letter)),
        };
        record(conn, id, ordinal, &blob, at(minute)).await?;
    }
    Ok(id)
}

async fn caption(
    conn: &mut PgConnection,
    letter: char,
    kind: Kind,
    text: &str,
    skip: bool,
    minute: i64,
) -> sqlx::Result<()> {
    let sha256 = sha(letter);
    let caption = Caption {
        sha256: &sha256,
        kind,
        text,
        skip,
        model: None,
        at: at(minute),
    };
    captions::write(conn, &caption).await?;
    Ok(())
}

/// Pointing along `axis`, leaning towards `lean` by `by`.
fn vector(axis: usize, lean: usize, by: f32) -> Vec<f32> {
    let mut vector = vec![0.0; DIMENSIONS];
    vector[axis] = 1.0;
    vector[lean] += by;
    vector
}

#[sqlx::test]
async fn the_nearest_stickers_by_their_last_row(pool: PgPool) -> sqlx::Result<()> {
    let mut conn = pool.acquire().await?;
    let one = group(&mut conn, "group:30001").await?;
    let two = group(&mut conn, "group:30002").await?;
    let first = row(&mut conn, &one, 0, &[(MediaKind::Sticker, 'a')]).await?;
    // a again, later, but as a picture: not a sticker's row.
    row(&mut conn, &one, 1, &[(MediaKind::Image, 'a')]).await?;
    // And as a sticker in another group, last.
    row(
        &mut conn,
        &two,
        2,
        &[(MediaKind::Image, 'd'), (MediaKind::Sticker, 'a')],
    )
    .await?;
    // e's caption is a sticker's, but no row has it as one.
    row(&mut conn, &one, 3, &[(MediaKind::Image, 'e')]).await?;
    let others = row(
        &mut conn,
        &one,
        4,
        &[
            (MediaKind::Sticker, 'b'),
            (MediaKind::Sticker, 'c'),
            (MediaKind::Sticker, 'f'),
        ],
    )
    .await?;
    caption(&mut conn, 'a', Kind::Sticker, "笑猫", false, 0).await?;
    caption(&mut conn, 'b', Kind::Sticker, "自拍", true, 1).await?;
    caption(&mut conn, 'c', Kind::Sticker, "", false, 2).await?;
    caption(&mut conn, 'd', Kind::Image, "截图", false, 3).await?;
    caption(&mut conn, 'e', Kind::Sticker, "哭猫", false, 4).await?;
    caption(&mut conn, 'f', Kind::Sticker, "狗", false, 5).await?;

    // Neither the skipped, the empty nor the picture's; newest first.
    let missing = [sha('f'), sha('e'), sha('a')];
    assert_eq!(unembedded(&mut conn, "bge-m3").await?, missing);
    assert_eq!(
        to_embed(&mut conn, &sha('a'), "bge-m3").await?.as_deref(),
        Some("笑猫")
    );
    for letter in ['b', 'c', 'd', 'z'] {
        assert_eq!(to_embed(&mut conn, &sha(letter), "bge-m3").await?, None);
    }
    for (letter, axis) in [('a', 0), ('e', 1), ('f', 2)] {
        let vector = vector(axis, 3, 0.0);
        write(&mut conn, &sha(letter), "bge-m3", &vector, at(9)).await?;
    }
    assert!(unembedded(&mut conn, "bge-m3").await?.is_empty());
    assert_eq!(to_embed(&mut conn, &sha('a'), "bge-m3").await?, None);
    assert_eq!(
        unembedded(&mut conn, "other").await?,
        missing,
        "another model"
    );

    let near_a = vector(0, 2, 0.5);
    let found = nearest(&mut conn, "bge-m3", &near_a, 5).await?;
    let last = MessageId(first.0 + 2);
    assert_eq!(
        found,
        [
            Sticker {
                message: last,
                ordinal: 1,
                caption: "笑猫".into()
            },
            Sticker {
                message: others,
                ordinal: 2,
                caption: "狗".into()
            },
        ],
        "e has no sticker's row"
    );
    assert_eq!(nearest(&mut conn, "bge-m3", &near_a, 1).await?.len(), 1);
    assert!(nearest(&mut conn, "other", &near_a, 5).await?.is_empty());

    // Another model's vector replaces it, and the first model's search
    // no longer finds it.
    write(&mut conn, &sha('a'), "other", &near_a, at(10)).await?;
    let found = nearest(&mut conn, "bge-m3", &near_a, 5).await?;
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].caption, "狗");
    assert_eq!(unembedded(&mut conn, "bge-m3").await?, [sha('a')]);
    Ok(())
}
