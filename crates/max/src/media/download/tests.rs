use axum::Router;
use axum::http::{StatusCode, header};
use axum::routing::get;
use max_core::message::{MediaKind, MediaMeta};
use tokio::net::TcpListener;
use tokio_util::sync::CancellationToken;

use super::*;
use crate::conversation::ingest;
use crate::conversation::testing::{from_xiaoming, group, offset, text};
use crate::inbound::InNode;

fn picture(url: String) -> InNode {
    InNode::Node(Node::Media {
        media: Some(MediaRef::Remote(url)),
        meta: MediaMeta {
            kind: MediaKind::Image,
            mime: None,
            size: None,
            name: None,
            description: None,
        },
    })
}

const FIRST: Attempt = Attempt {
    number: 1,
    last: false,
};

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn downloads_each_medium_once(pool: PgPool) {
    let app = Router::new()
        .route(
            "/a.png",
            get(|| async { ([(header::CONTENT_TYPE, "image/png")], "abc") }),
        )
        .route("/gone", get(|| async { StatusCode::NOT_FOUND }))
        .route("/busy", get(|| async { StatusCode::SERVICE_UNAVAILABLE }));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let stop = CancellationToken::new();
    let server = axum::serve(listener, app).with_graceful_shutdown(stop.clone().cancelled_owned());

    let dir = std::env::temp_dir().join(format!("max-download-{:016x}", rand::random::<u64>()));
    let store = Arc::new(Store::open(&dir).await.unwrap());
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    let nodes = ["a.png", "gone", "busy"].map(|path| picture(format!("{base}/{path}")));
    let mut nodes = Vec::from(nodes);
    nodes.insert(1, text("和"));
    let committed = ingest::inbound(
        &mut conn,
        &place,
        &from_xiaoming(1, nodes),
        Utc::now(),
        offset(),
    )
    .await
    .unwrap();
    drop(conn);
    let id = committed.message.id;
    let download = Download {
        pool: pool.clone(),
        http: fetch::client().unwrap(),
        store: Arc::clone(&store),
        captions: None,
    };

    let test = async {
        let row = Row {
            place,
            message: Arc::new(committed.message),
        };
        let units = download.on_input(row);
        let units: Vec<_> = units.into_iter().map(|(unit, _)| unit).collect();
        let shown: Vec<_> = units.iter().map(|unit| format!("{unit:?}")).collect();
        assert_eq!(
            shown,
            [format!("{id}.0"), format!("{id}.1"), format!("{id}.2")]
        );
        for unit in &units[..2] {
            download.run(unit, FIRST).await.unwrap();
        }
        let busy = download.run(&units[2], FIRST).await.unwrap_err();
        assert_eq!(busy.to_string(), "HTTP 503");

        let mut conn = pool.acquire().await.unwrap();
        let sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
        assert_eq!(
            downloaded(&mut conn, id).await.unwrap(),
            [(0, sha256.to_owned())]
        );
        assert_eq!(std::fs::read(store.path(sha256)).unwrap(), b"abc");
        // The one that expired is given up, but a scan finds it again:
        // it doesn't look back further than QQ's addresses last.
        let missed: Vec<_> = download
            .scan()
            .await
            .unwrap()
            .into_iter()
            .map(|unit| unit.ordinal)
            .collect();
        assert_eq!(missed, [1, 2]);
        // Again, nothing changes.
        download.run(&units[0], FIRST).await.unwrap();
        assert_eq!(downloaded(&mut conn, id).await.unwrap().len(), 1);
        stop.cancel();
    };
    let (served, ()) = tokio::join!(server.into_future(), test);
    served.unwrap();
    let _ = std::fs::remove_dir_all(&dir);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn pictures_go_on_to_the_caption_worker(pool: PgPool) {
    let mut png = std::io::Cursor::new(Vec::new());
    image::RgbImage::new(2, 1)
        .write_to(&mut png, image::ImageFormat::Png)
        .unwrap();
    let png = png.into_inner();
    let served = png.clone();
    let app = Router::new()
        .route("/p.png", get(move || async move { served }))
        .route("/a.txt", get(|| async { "abc" }));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let stop = CancellationToken::new();
    let server = axum::serve(listener, app).with_graceful_shutdown(stop.clone().cancelled_owned());

    let dir = std::env::temp_dir().join(format!("max-download-{:016x}", rand::random::<u64>()));
    let store = Arc::new(Store::open(&dir).await.unwrap());
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    let nodes = ["p.png", "a.txt"].map(|path| picture(format!("{base}/{path}")));
    let committed = ingest::inbound(
        &mut conn,
        &place,
        &from_xiaoming(1, Vec::from(nodes)),
        Utc::now(),
        offset(),
    )
    .await
    .unwrap();
    drop(conn);
    let id = committed.message.id;
    let (captions, mut picked) = tokio::sync::mpsc::unbounded_channel();
    let download = Download {
        pool: pool.clone(),
        http: fetch::client().unwrap(),
        store,
        captions: Some(captions),
    };

    let test = async {
        let row = Row {
            place,
            message: Arc::new(committed.message),
        };
        for (unit, _) in download.on_input(row) {
            download.run(&unit, FIRST).await.unwrap();
        }
        // The text isn't a picture.
        let picture = picked.try_recv().unwrap();
        assert!(picked.try_recv().is_err());
        assert_eq!(
            picture.image,
            Image {
                kind: MediaKind::Image,
                message: id,
                ordinal: 0
            }
        );
        let mut conn = pool.acquire().await.unwrap();
        let stored = downloaded(&mut conn, id).await.unwrap();
        assert_eq!(picture.sha256, stored[0].1);
        stop.cancel();
    };
    let (served, ()) = tokio::join!(server.into_future(), test);
    served.unwrap();
    let _ = std::fs::remove_dir_all(&dir);
}
