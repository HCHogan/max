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
