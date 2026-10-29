use std::sync::{Arc, Mutex};

use axum::Router;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use axum::routing::post;
use serde_json::Value;
use tokio::net::TcpListener;
use tokio_util::sync::CancellationToken;

use super::*;

/// What the fake Exa was asked: the key and the body.
type Asked = Arc<Mutex<Vec<(String, Value)>>>;

async fn exa(State(asked): State<Asked>, headers: HeaderMap, body: String) -> impl IntoResponse {
    let key = headers["x-api-key"].to_str().unwrap().to_owned();
    let body: Value = serde_json::from_str(&body).unwrap();
    let query = body["query"].as_str().unwrap().to_owned();
    asked.lock().unwrap().push((key, body));
    match query.as_str() {
        "多了" => (StatusCode::TOO_MANY_REQUESTS, String::new()),
        "坏的" => (
            StatusCode::BAD_REQUEST,
            r#"{"error":"query is empty"}"#.to_owned(),
        ),
        "挂了" => (StatusCode::BAD_GATEWAY, String::new()),
        _ => {
            let long = "长".repeat(900);
            let answer = json!({ "results": [
                { "title": " 示波器探头补偿 ", "url": "https://example.com/a",
                  "publishedDate": "2026-10-01T08:00:00.000Z",
                  "highlights": ["第一段。", "第二段。"] },
                { "url": "https://example.com/b", "text": long },
                { "title": "多出来的", "url": "https://example.com/c" },
            ]});
            (StatusCode::OK, answer.to_string())
        }
    }
}

#[tokio::test]
async fn searches_exa_and_keeps_the_results_short() {
    let asked = Asked::default();
    let app = Router::new()
        .route("/search", post(exa))
        .with_state(Arc::clone(&asked));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/search", listener.local_addr().unwrap());
    let stop = CancellationToken::new();
    let server = axum::serve(listener, app).with_graceful_shutdown(stop.clone().cancelled_owned());
    let search = Search::new(&url, "KEY".into()).unwrap();
    let test = async {
        let found = search.search("示波器", 2).await.unwrap();
        assert_eq!(
            found[0],
            Found {
                title: "示波器探头补偿".into(),
                url: "https://example.com/a".into(),
                snippet: "第一段。\n第二段。".into(),
                published: Some("2026-10-01".into()),
            }
        );
        assert_eq!(found.len(), 2, "no more than asked for");
        assert_eq!(found[1].snippet.chars().count(), 801, "the text, cut");
        let shown = serde_json::to_value(&found[1]).unwrap();
        assert!(shown.get("published").is_none(), "{shown}");

        let (key, body) = asked.lock().unwrap()[0].clone();
        assert_eq!(key, "KEY");
        assert_eq!(body["numResults"], 2);
        assert_eq!(body["type"], "auto");
        assert_eq!(body["contents"]["highlights"], true);

        assert_eq!(search.search("多了", 5).await, Err(Error::RateLimited));
        let bad = search.search("坏的", 5).await.unwrap_err();
        assert_eq!(bad, Error::BadQuery(r#"{"error":"query is empty"}"#.into()));
        let down = search.search("挂了", 5).await.unwrap_err();
        assert_eq!(down, Error::Unavailable("HTTP 502".into()));
        stop.cancel();
    };
    let (served, ()) = tokio::join!(server.into_future(), test);
    served.unwrap();
}
