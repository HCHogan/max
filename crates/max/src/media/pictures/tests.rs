use std::collections::BTreeSet;
use std::io::Cursor;
use std::time::Instant;

use chrono::TimeDelta;
use max_core::item::{Item, ModelTag, Protocol};
use max_core::message::{MediaKind, MediaMeta, MediaRef, Node};
use max_db::media::Blob;

use super::*;
use crate::conversation::ingest;
use crate::conversation::testing::{from_xiaoming, group, offset};
use crate::inbound::InNode;

fn picture() -> InNode {
    InNode::Node(Node::Media {
        media: Some(MediaRef::Remote("https://q.example/x".into())),
        meta: MediaMeta {
            kind: MediaKind::Image,
            mime: None,
            size: None,
            name: None,
            description: None,
        },
    })
}

fn png() -> Vec<u8> {
    let mut bytes = Cursor::new(Vec::new());
    image::RgbImage::new(2, 2)
        .write_to(&mut bytes, image::ImageFormat::Png)
        .unwrap();
    bytes.into_inner()
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn pictures_are_read_and_new_ones_waited_for(pool: PgPool) {
    let dir = std::env::temp_dir().join(format!("max-pictures-{:016x}", rand::random::<u64>()));
    let store = Arc::new(Store::open(&dir).await.unwrap());
    let sha256 = store.put(png()).await.unwrap();
    let blob = Blob {
        sha256: sha256.clone(),
        mime: Some("image/png".into()),
        size: 0,
        width: Some(2),
        height: Some(2),
        model_sha256: Some(sha256),
    };
    let mut conn = pool.acquire().await.unwrap();
    let place = group(&mut conn).await;
    let now = Utc::now();
    // An old row: one picture downloaded, one that never was.
    let old = from_xiaoming(1, vec![picture(), picture()]);
    let old = ingest::inbound(
        &mut conn,
        &place,
        &old,
        now - TimeDelta::minutes(1),
        offset(),
    )
    .await
    .unwrap()
    .message
    .id;
    media::record(&mut conn, old, 0, &blob, now).await.unwrap();
    // A row just in, its picture still downloading.
    let new = from_xiaoming(2, vec![picture()]);
    let new = ingest::inbound(&mut conn, &place, &new, now, offset())
        .await
        .unwrap()
        .message
        .id;
    drop(conn);

    let image = |message, ordinal| Image {
        kind: MediaKind::Image,
        message,
        ordinal,
    };
    let images = vec![image(old, 0), image(old, 1), image(new, 0)];
    let request = Request {
        model: ModelTag {
            protocol: Protocol::Responses,
            model: "gpt-5.6-luna".into(),
        },
        items: vec![Item::new(
            ItemKind::User {
                text: "看".into(),
                images,
            },
            1,
        )],
        tools: &[],
        max_output: None,
        roster: BTreeSet::new(),
    };
    let pictures = Pictures {
        pool: pool.clone(),
        store,
    };
    let downloaded = async {
        tokio::time::sleep(Duration::from_millis(300)).await;
        let mut conn = pool.acquire().await.unwrap();
        media::record(&mut conn, new, 0, &blob, Utc::now())
            .await
            .unwrap();
    };
    let started = Instant::now();
    let (read, ()) = tokio::join!(pictures.read(&request), downloaded);
    assert!(started.elapsed() < Duration::from_secs(3), "waited out");
    let handles: Vec<&str> = read.0.keys().map(String::as_str).collect();
    assert_eq!(
        handles,
        [format!("image#{old}.0"), format!("image#{new}.0")]
    );
    assert!(
        read.0
            .values()
            .all(|url| url.starts_with("data:image/png;base64,iVBOR"))
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn the_newest_pictures_programs_showed_are_read(pool: PgPool) {
    let dir = std::env::temp_dir().join(format!("max-shown-{:016x}", rand::random::<u64>()));
    let store = Arc::new(Store::open(&dir).await.unwrap());
    let mut stored = Vec::new();
    for width in 1..=10 {
        let mut bytes = Cursor::new(Vec::new());
        image::RgbImage::new(width, 1)
            .write_to(&mut bytes, image::ImageFormat::Png)
            .unwrap();
        stored.push(store.put(bytes.into_inner()).await.unwrap());
    }
    let result = |shown: &[String]| {
        let parts = shown
            .iter()
            .map(|sha256| Part::Media {
                media: MediaRef::Blob(sha256.clone()),
            })
            .collect();
        let output = max_core::item::ToolOutput {
            parts,
            error: false,
            tokens: 1,
        };
        Item::new(
            ItemKind::ToolResult {
                call: max_core::ids::CallId("call_1".into()),
                output,
            },
            1,
        )
    };
    // The first again, last: it counts where it was shown last.
    let mut later = stored[5..].to_vec();
    later.push(stored[0].clone());
    let request = Request {
        model: ModelTag {
            protocol: Protocol::Chat,
            model: "qwen3.8-27b".into(),
        },
        items: vec![result(&stored[..5]), result(&later)],
        tools: &[],
        max_output: None,
        roster: BTreeSet::new(),
    };
    let pictures = Pictures { pool, store };
    let read = pictures.read(&request).await;
    let mut expected: Vec<&String> = [0, 3, 4, 5, 6, 7, 8, 9]
        .iter()
        .map(|&n| &stored[n])
        .collect();
    expected.sort();
    assert_eq!(read.0.keys().collect::<Vec<_>>(), expected);
    assert!(
        read.0
            .values()
            .all(|url| url.starts_with("data:image/png;base64,"))
    );
    let _ = std::fs::remove_dir_all(&dir);
}
