//! A made-up embedding service: a text's vector counts its characters,
//! so texts that share characters are near. A text with 挂 in it fails.

use std::sync::{Arc, Mutex};

use axum::Router;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::routing::post;
use max_db::embeddings::DIMENSIONS;
use serde_json::{Value, json};
use tokio::net::TcpListener;

use super::Embedder;
use crate::scope::Scope;

/// What the service was asked: the Authorization header and the body.
pub type Asked = Arc<Mutex<Vec<(Option<String>, Value)>>>;

/// The made-up vector of `text`.
pub fn vector(text: &str) -> Vec<f32> {
    let mut vector = vec![0.0; DIMENSIONS];
    for c in text.chars() {
        vector[c as usize % DIMENSIONS] += 1.0;
    }
    vector
}

async fn embeddings(
    State(asked): State<Asked>,
    headers: HeaderMap,
    body: String,
) -> (StatusCode, String) {
    let key = headers
        .get("authorization")
        .map(|value| value.to_str().unwrap().to_owned());
    let body: Value = serde_json::from_str(&body).unwrap();
    asked.lock().unwrap().push((key, body.clone()));
    let texts: Vec<&str> = body["input"]
        .as_array()
        .unwrap()
        .iter()
        .map(|text| text.as_str().unwrap())
        .collect();
    if texts.iter().any(|text| text.contains('挂')) {
        return (StatusCode::BAD_GATEWAY, "down".into());
    }
    // In reverse, as a server may: the index puts them in order.
    let data: Vec<Value> = texts
        .iter()
        .enumerate()
        .rev()
        .map(|(index, text)| json!({ "object": "embedding", "index": index, "embedding": vector(text) }))
        .collect();
    let answer = json!({ "object": "list", "model": body["model"], "data": data });
    (StatusCode::OK, answer.to_string())
}

/// Serves until `scope` closes; an Embedder of model `test-m3` that asks
/// it, and what it was asked.
pub async fn serve(scope: &mut Scope) -> (Arc<Embedder>, Asked) {
    let asked = Asked::default();
    let app = Router::new()
        .route("/v1/embeddings", post(embeddings))
        .with_state(Arc::clone(&asked));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    scope.spawn(move |stop| async move {
        let server = axum::serve(listener, app).with_graceful_shutdown(stop.cancelled_owned());
        server.await.unwrap();
    });
    let url = format!("http://{address}/v1/");
    let embedder = Embedder::new(&url, "test-m3".into(), None).unwrap();
    (Arc::new(embedder), asked)
}
