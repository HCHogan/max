use axum::Router;
use axum::routing::post;
use tokio::net::TcpListener;

use super::testing::{serve, vector};
use super::*;
use crate::scope::Scope;

#[tokio::test]
async fn a_vector_for_each_text_in_order() {
    let mut scope = Scope::new();
    let (embedder, asked) = serve(&mut scope).await;
    let vectors = embedder.embed(&["笑猫", "狗"]).await.unwrap();
    assert_eq!(vectors, [vector("笑猫"), vector("狗")]);
    assert_eq!(embedder.one("猫").await.unwrap(), vector("猫"));
    let (key, body) = asked.lock().unwrap()[0].clone();
    assert_eq!(key, None, "no key, no header");
    assert_eq!(body, json!({ "model": "test-m3", "input": ["笑猫", "狗"] }));

    let down = embedder.one("挂了").await.unwrap_err();
    assert_eq!(down, Error::Unavailable("HTTP 502: down".into()));
    scope.close(Duration::ZERO).await;
}

#[tokio::test]
async fn wrong_answers_are_errors() {
    // Three numbers for one text, whatever was asked.
    let answer = json!({ "data": [{ "index": 0, "embedding": [0.1, 0.2, 0.3] }] }).to_string();
    let app = Router::new().route("/v1/embeddings", post(move || async move { answer }));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/v1", listener.local_addr().unwrap());
    let mut scope = Scope::new();
    scope.spawn(move |stop| async move {
        let server = axum::serve(listener, app).with_graceful_shutdown(stop.cancelled_owned());
        server.await.unwrap();
    });
    let embedder = Embedder::new(&url, "bge-m3".into(), Some("KEY".into())).unwrap();
    let short = embedder.one("猫").await.unwrap_err();
    assert_eq!(short, Error::Malformed("3 numbers, not 1024".into()));
    let fewer = embedder.embed(&["猫", "狗"]).await.unwrap_err();
    assert_eq!(fewer, Error::Malformed("2 texts, vectors for [0]".into()));

    let nobody = Embedder::new("http://127.0.0.1:9/v1", "bge-m3".into(), None).unwrap();
    let error = nobody.one("猫").await.unwrap_err();
    assert!(matches!(error, Error::Unavailable(_)), "{error}");
    scope.close(Duration::ZERO).await;
}

#[tokio::test]
async fn the_key_goes_as_a_bearer() {
    let mut scope = Scope::new();
    let (embedder, asked) = serve(&mut scope).await;
    let url = embedder.url.trim_end_matches("/embeddings").to_owned();
    let keyed = Embedder::new(&url, "test-m3".into(), Some("KEY".into())).unwrap();
    keyed.one("猫").await.unwrap();
    assert_eq!(asked.lock().unwrap()[0].0.as_deref(), Some("Bearer KEY"));
    scope.close(Duration::ZERO).await;
}
