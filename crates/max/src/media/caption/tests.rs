use std::io::Cursor;

use max_core::ids::MessageId;
use max_core::message::{Content, MediaKind, MediaMeta, MediaRef, Node, media};
use max_db::ledger;
use max_db::media::{self, Blob};
use sqlx::PgPool;

use super::*;
use crate::conversation::ingest;
use crate::conversation::testing::{from_xiaoming, group, offset};
use crate::inbound::InNode;
use crate::llm::testing::{Answer, Script, models};
use crate::media::store::Store;

fn medium(kind: MediaKind) -> InNode {
    InNode::Node(Node::Media {
        media: Some(MediaRef::Remote("https://q.example/x".into())),
        meta: MediaMeta {
            kind,
            mime: None,
            size: None,
            name: None,
            description: None,
        },
    })
}

fn png(width: u32) -> Vec<u8> {
    let mut bytes = Cursor::new(Vec::new());
    image::RgbImage::new(width, 1)
        .write_to(&mut bytes, image::ImageFormat::Png)
        .unwrap();
    bytes.into_inner()
}

const FIRST: Attempt = Attempt {
    number: 1,
    last: false,
};

const LAST: Attempt = Attempt {
    number: 2,
    last: true,
};

struct Fixture {
    captioner: Captioner,
    script: Arc<Script>,
    place: crate::conversation::Place,
    /// A row with a picture and a sticker, both stored.
    row: MessageId,
    picture: Picture,
    sticker: Picture,
    dir: std::path::PathBuf,
}

async fn fixture(pool: &PgPool) -> Fixture {
    let dir = std::env::temp_dir().join(format!("max-caption-{:016x}", rand::random::<u64>()));
    let store = Arc::new(Store::open(&dir).await.unwrap());
    let mut conn = pool.acquire().await.unwrap();
    let place = group(&mut conn).await;
    let nodes = vec![medium(MediaKind::Image), medium(MediaKind::Sticker)];
    let row = ingest::inbound(
        &mut conn,
        &place,
        &from_xiaoming(1, nodes),
        Utc::now(),
        offset(),
    )
    .await
    .unwrap()
    .message
    .id;
    let mut stored = Vec::new();
    for (ordinal, width) in [(0, 1), (1, 2)] {
        let sha256 = store.put(png(width)).await.unwrap();
        let blob = Blob {
            sha256: sha256.clone(),
            mime: Some("image/png".into()),
            size: 0,
            width: Some(width),
            height: Some(1),
            model_sha256: Some(sha256.clone()),
        };
        media::record(&mut conn, row, ordinal, &blob, Utc::now())
            .await
            .unwrap();
        stored.push(sha256);
    }
    let picture = |kind, ordinal: u16| Picture {
        image: Image {
            kind,
            message: row,
            ordinal,
        },
        sha256: stored[usize::from(ordinal)].clone(),
    };
    let script = Arc::new(Script::default());
    let chosen = models(&script).choose("test/big", Some("low")).unwrap();
    let captioner = Captioner {
        pool: pool.clone(),
        chosen,
        pictures: Arc::new(Pictures {
            pool: pool.clone(),
            store,
        }),
    };
    Fixture {
        captioner,
        script,
        place,
        row,
        picture: picture(MediaKind::Image, 0),
        sticker: picture(MediaKind::Sticker, 1),
        dir,
    }
}

/// The descriptions the row's media show.
async fn shown(pool: &PgPool, fixture: &Fixture) -> Vec<Option<String>> {
    let mut conn = pool.acquire().await.unwrap();
    let after = MessageId(fixture.row.0 + 1);
    let rows = ledger::recent(&mut conn, fixture.place.conversation, after, 1)
        .await
        .unwrap();
    let Content::Message { nodes, .. } = &rows[0].message.content else {
        panic!("not a message");
    };
    media(nodes)
        .map(|(_, _, meta)| meta.description.clone())
        .collect()
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn each_file_is_captioned_once(pool: PgPool) {
    let fixture = fixture(&pool).await;
    let captioner = &fixture.captioner;
    let script = &fixture.script;

    script.push(Answer::says("“一张白底的图，\n什么都没画。”"));
    captioner.run(&fixture.picture, FIRST).await.unwrap();
    script.push(Answer::says("SKIP：一张聊天截图"));
    captioner.run(&fixture.sticker, FIRST).await.unwrap();
    // Again: it has one, so the model isn't asked.
    captioner.run(&fixture.picture, FIRST).await.unwrap();
    assert_eq!(script.calls(), 2);

    let requests: Vec<Vec<ItemKind>> = script
        .requests
        .lock()
        .unwrap()
        .iter()
        .map(|request| request.items.iter().map(|item| item.kind.clone()).collect())
        .collect();
    let [ItemKind::System { text }, _] = requests[0].as_slice() else {
        panic!("no prompt");
    };
    assert!(text.contains("截图"), "the picture's prompt");
    let [ItemKind::System { text }, ItemKind::User { images, .. }] = requests[1].as_slice() else {
        panic!("no prompt");
    };
    assert!(text.contains("SKIP"), "the sticker's prompt");
    assert_eq!(images, &[fixture.sticker.image]);
    let handles = script.pictures.lock().unwrap().clone();
    let row = fixture.row;
    assert_eq!(
        handles,
        [
            vec![format!("image#{row}.0")],
            vec![format!("sticker#{row}.1")]
        ]
    );

    // One line, no quotes; a sticker that isn't one is still described.
    assert_eq!(
        shown(&pool, &fixture).await,
        [
            Some("一张白底的图， 什么都没画。".to_owned()),
            Some("一张聊天截图".to_owned())
        ]
    );
    let skips: Vec<bool> = sqlx::query_scalar("select skip from media_captions order by kind")
        .fetch_all(&pool)
        .await
        .unwrap();
    assert_eq!(skips, [false, true]);
    assert!(captioner.scan().await.unwrap().is_empty());
    let _ = std::fs::remove_dir_all(&fixture.dir);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_model_that_fails_twice_leaves_it_empty(pool: PgPool) {
    let fixture = fixture(&pool).await;
    let captioner = &fixture.captioner;
    let missed = captioner.scan().await.unwrap();
    assert_eq!(missed, [fixture.picture.clone(), fixture.sticker.clone()]);

    fixture
        .script
        .push(Answer::Fails(max_llm::Error::Truncated));
    assert!(captioner.run(&fixture.picture, FIRST).await.is_err());
    // An empty answer is a failure too.
    fixture.script.push(Answer::says("  "));
    captioner.run(&fixture.picture, LAST).await.unwrap();
    assert_eq!(fixture.script.calls(), 2);
    // Not shown, not tried again.
    assert_eq!(shown(&pool, &fixture).await, [None, None]);
    assert_eq!(
        captioner.scan().await.unwrap(),
        std::slice::from_ref(&fixture.sticker)
    );
    let _ = std::fs::remove_dir_all(&fixture.dir);
}

#[test]
fn what_the_model_wrote() {
    let sticker = |said| parse(said, Kind::Sticker).unwrap();
    assert_eq!(sticker("skip: 自拍"), ("自拍".to_owned(), true));
    assert_eq!(sticker("SKIP"), (String::new(), true));
    assert_eq!(sticker("「翻白眼的猫」"), ("翻白眼的猫".to_owned(), false));
    // Only a sticker's may be skipped.
    let picture = parse("SKIP：自拍", Kind::Image).unwrap();
    assert_eq!(picture, ("SKIP：自拍".to_owned(), false));
    let long = "猫".repeat(400);
    assert_eq!(sticker(&long).0.chars().count(), MOST);
    assert!(parse("", Kind::Image).is_err());
}
