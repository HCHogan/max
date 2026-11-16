use std::time::Duration;

use axum::http::Method;
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::time::timeout;

use super::*;

const PATIENCE: Duration = Duration::from_secs(10);

/// A VM's directory, conversation 7's, with nothing in it: short, as a
/// socket's path must be.
fn vm() -> PathBuf {
    let dir = PathBuf::from(format!("/tmp/max-fw-{:08x}/7", rand::random::<u32>()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Where max listens for the forwarder of the VM whose directory is
/// `dir`: beside it.
fn socket(dir: &Path) -> PathBuf {
    dir.parent().unwrap().join(MAX)
}

/// A call max drops in the middle is a failed call, which may have
/// acted; one the guest drops is dropped at max too, which cancels it.
#[tokio::test]
async fn a_call_ends_at_max_as_it_ends_at_the_guest() {
    let dir = vm();
    let listener = UnixListener::bind(socket(&dir)).unwrap();
    let (heard, mut hears) = tokio::sync::mpsc::unbounded_channel();
    let mut scope = Scope::new();
    scope.spawn(move |_| async move {
        // The first is read and closed with nothing said; the second is
        // held until its other end goes.
        let (mut first, _) = listener.accept().await.unwrap();
        let mut read = [0; 1024];
        let _ = first.read(&mut read).await.unwrap();
        drop(first);
        let (mut second, _) = listener.accept().await.unwrap();
        let _ = second.read(&mut read).await.unwrap();
        let _ = heard.send("asked");
        let gone = second.read(&mut read).await.unwrap_or(0);
        let _ = second.shutdown().await;
        let _ = heard.send(if gone == 0 { "gone" } else { "more" });
    });
    let max = Max::at(&socket(&dir), ConversationId(7)).unwrap();
    let request = || {
        Request::builder()
            .method(Method::POST)
            .uri("/tools/say")
            .body(Body::from("{}"))
            .unwrap()
    };

    let dropped = max.pass(request()).await;
    assert_eq!(dropped.status(), StatusCode::BAD_GATEWAY);
    let body = axum::body::to_bytes(dropped.into_body(), 4096).await;
    let outcome: Value = serde_json::from_slice(&body.unwrap()).unwrap();
    assert_eq!(
        (&outcome["ok"], &outcome["error"]["code"]),
        (&json!(false), &json!("closed"))
    );

    let mut call = Box::pin(max.pass(request()));
    let asked = async {
        tokio::select! {
            _ = &mut call => panic!("max never answers this one"),
            heard = hears.recv() => heard,
        }
    };
    assert_eq!(timeout(PATIENCE, asked).await.unwrap(), Some("asked"));
    // The guest closed its connection: the call's future is dropped.
    drop(call);
    assert_eq!(timeout(PATIENCE, hears.recv()).await.unwrap(), Some("gone"));
    scope.close(Duration::from_secs(1)).await;
    let _ = std::fs::remove_dir_all(dir.parent().unwrap());
}
