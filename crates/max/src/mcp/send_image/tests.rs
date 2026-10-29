use std::io::Cursor;
use std::sync::Arc;

use max_core::ids::TurnId;
use max_core::message::{MediaKind, MediaMeta, MediaRef, Node};
use sqlx::PgPool;
use tokio::sync::mpsc;

use super::*;
use crate::conversation::testing::{group, offset};
use crate::conversation::{Act, Event, Poster, ingest};
use crate::media::store::Store;
use crate::scope::Scope;

fn encoded(format: ImageFormat) -> Vec<u8> {
    let mut bytes = Cursor::new(Vec::new());
    image::RgbImage::new(2, 1)
        .write_to(&mut bytes, format)
        .unwrap();
    bytes.into_inner()
}

/// A scratch directory, gone when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Self {
        let dir =
            std::env::temp_dir().join(format!("max-send-image-{:016x}", rand::random::<u64>()));
        std::fs::create_dir_all(dir.join("work/charts")).unwrap();
        Self(dir)
    }

    fn work(&self) -> PathBuf {
        self.0.join("work")
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn paths_stay_in_work() {
    let ok = |path: &str| beneath_work(path).unwrap();
    assert_eq!(ok("/work/charts/a.png"), Path::new("charts/a.png"));
    assert_eq!(ok("charts/./a.png"), Path::new("charts/a.png"));
    for bad in [
        "/etc/passwd",
        "../a.png",
        "charts/../../a.png",
        "/work",
        "/workshop/a.png",
        "",
    ] {
        assert_eq!(beneath_work(bad).unwrap_err().code, "bad_path", "{bad}");
    }
}

#[test]
fn symlinks_and_big_files_are_refused() {
    let scratch = Scratch::new();
    let work = scratch.work();
    std::fs::write(work.join("charts/a.png"), b"png").unwrap();
    let outside = scratch.0.join("secret.png");
    std::fs::write(&outside, b"secret").unwrap();
    std::os::unix::fs::symlink(&outside, work.join("link.png")).unwrap();
    std::os::unix::fs::symlink(&scratch.0, work.join("up")).unwrap();
    let big = File::create(work.join("big.png")).unwrap();
    big.set_len(MOST + 1).unwrap();

    assert_eq!(read(&work, Path::new("charts/a.png")).unwrap(), b"png");
    let code = |path: &str| read(&work, Path::new(path)).unwrap_err().code;
    assert_eq!(code("link.png"), "bad_path");
    assert_eq!(code("up/secret.png"), "bad_path");
    assert_eq!(code("charts"), "bad_path", "a directory");
    assert_eq!(code("big.png"), "too_big");
    assert_eq!(code("charts/b.png"), "not_found");
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_chart_goes_out_with_its_caption(pool: PgPool) {
    let scratch = Scratch::new();
    let store = Arc::new(Store::open(&scratch.0.join("store")).await.unwrap());
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    // The actor's part: commit what is posted, and say it went out.
    let (mailbox, mut posts) = mpsc::unbounded_channel();
    let committing = Arc::clone(&place);
    let mut scope = Scope::new();
    scope.spawn(move |_| async move {
        while let Some(event) = posts.recv().await {
            let Event::Post(post) = event else { continue };
            let Act::Say(draft) = post.act else { continue };
            let said = ingest::said(
                &mut conn,
                &committing,
                draft,
                None,
                None,
                Utc::now(),
                offset(),
            );
            let message = said.await.unwrap().unwrap();
            let _ = post.receipt.unwrap().send(Ok(message.id));
        }
    });
    let context = Context {
        pool: pool.clone(),
        place: Arc::clone(&place),
        offset: offset(),
        page_tokens: 2000,
        search: None,
        work: Some(scratch.work()),
        store: Some(Arc::clone(&store)),
        poster: Some(Poster::new(mailbox, TurnId(1))),
        embedder: None,
    };
    let work = scratch.work();
    std::fs::write(work.join("charts/daily.webp"), encoded(ImageFormat::WebP)).unwrap();
    std::fs::write(work.join("notes.txt"), "不是图").unwrap();

    let args = json!({ "path": "/work/charts/daily.webp", "caption": " 每日活跃 " });
    let sent = run(&context, args).await.unwrap();
    let handle = sent["handle"].as_str().unwrap();
    let id: i64 = handle
        .strip_prefix("image#")
        .and_then(|rest| rest.strip_suffix(".0"))
        .unwrap()
        .parse()
        .unwrap();
    let nodes: sqlx::types::Json<Vec<Node>> =
        sqlx::query_scalar("select nodes from messages where id = $1")
            .bind(id)
            .fetch_one(&pool)
            .await
            .unwrap();
    let [
        Node::Media {
            media: Some(MediaRef::Blob(sha256)),
            meta,
        },
        Node::Text { text },
    ] = nodes.0.as_slice()
    else {
        panic!("{nodes:?}");
    };
    assert_eq!(text, "每日活跃");
    let size = std::fs::metadata(store.path(sha256)).unwrap().len();
    let expected = MediaMeta {
        kind: MediaKind::Image,
        mime: Some("image/png".into()),
        size: Some(size),
        name: None,
        description: None,
    };
    assert_eq!(meta, &expected, "the WebP went as PNG");
    let png = std::fs::read(store.path(sha256)).unwrap();
    assert_eq!(image::guess_format(&png).unwrap(), ImageFormat::Png);
    // The row has it, as a downloaded picture would.
    let (width, linked): (Option<i32>, i64) = sqlx::query_as(
        "select md.width, (select count(*) from message_media where message_id = $1)
         from media md where md.sha256 = $2",
    )
    .bind(id)
    .bind(sha256)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!((width, linked), (Some(2), 1));

    let not_one = run(&context, json!({ "path": "notes.txt" })).await;
    assert_eq!(not_one.unwrap_err().code, "not_a_picture");
    let elsewhere = Context {
        poster: None,
        embedder: None,
        ..context
    };
    let refused = run(&elsewhere, json!({ "path": "charts/daily.webp" })).await;
    assert_eq!(refused.unwrap_err().code, "unavailable");
    // The poster is gone, so the actor's part ends.
    scope.close(std::time::Duration::from_secs(5)).await;
}
