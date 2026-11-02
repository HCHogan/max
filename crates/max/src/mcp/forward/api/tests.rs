use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::http::{HeaderMap, Method, Uri};
use axum::routing::any;
use tokio::net::TcpListener;

use super::*;
use crate::scope::Scope;

/// What the API was asked: the method, the path and query, the headers,
/// and the body.
type Asked = Arc<Mutex<Vec<(Method, String, HeaderMap, String)>>>;

/// An API that answers every call with `{"id":"e_1"}` and a header of
/// its own, but `/v1/moved` with a redirect.
async fn upstream(scope: &mut Scope, asked: Asked) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let app = axum::Router::new().fallback(any(
        move |method: Method, uri: Uri, headers: HeaderMap, body: String| {
            let asked = Arc::clone(&asked);
            async move {
                let moved = uri.path() == "/v1/moved";
                asked
                    .lock()
                    .unwrap()
                    .push((method, uri.to_string(), headers, body));
                let response = Response::builder().header("x-request-id", "r_1");
                let response = if moved {
                    response
                        .status(StatusCode::FOUND)
                        .header(header::LOCATION, "http://elsewhere.example/")
                } else {
                    response.header(header::CONTENT_TYPE, "application/json")
                };
                response.body(Body::from("{\"id\":\"e_1\"}")).unwrap()
            }
        },
    ));
    scope.spawn(move |stop| async move {
        let _ = axum::serve(listener, app)
            .with_graceful_shutdown(stop.cancelled_owned())
            .await;
    });
    format!("http://{address}/v1")
}

fn secret_file() -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("max-api-{:016x}", rand::random::<u64>()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("mail-api-key");
    std::fs::write(&file, "s3cret\n").unwrap();
    file
}

fn mail(base_url: &str) -> config::Api {
    let rule = |text: &str| Rule::try_from(text.to_owned()).unwrap();
    config::Api {
        base_url: base_url.to_owned(),
        secret_file: secret_file(),
        headers: BTreeMap::from([("Authorization".into(), "Bearer {secret}".into())]),
        query: BTreeMap::new(),
        allow: Some(vec![
            rule("POST /emails"),
            rule("GET /emails/*"),
            rule("GET /moved"),
        ]),
        per_hour: Some(3),
        about: "发邮件。".into(),
    }
}

/// The APIs served as a VM's, at the returned address.
async fn served(scope: &mut Scope, apis: Apis) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let app = router(ConversationId(7), Arc::new(apis));
    scope.spawn(move |stop| async move {
        let _ = axum::serve(listener, app)
            .with_graceful_shutdown(stop.cancelled_owned())
            .await;
    });
    format!("http://{address}")
}

#[tokio::test]
async fn a_call_goes_on_with_the_key_and_comes_back_as_it_is() {
    let mut scope = Scope::new();
    let asked = Asked::default();
    let base = upstream(&mut scope, Arc::clone(&asked)).await;
    let apis = Apis::load(&BTreeMap::from([("mail".to_owned(), mail(&base))])).unwrap();
    assert_eq!(
        apis.prompt(),
        format!(
            "- mail（{base}）：发邮件。只许 POST /emails、GET /emails/*、GET /moved。\
             所有群加起来一小时最多 3 次。"
        )
    );
    let vm = served(&mut scope, apis).await;
    let client = reqwest::Client::builder()
        .redirect(Policy::none())
        .build()
        .unwrap();

    let answer = client
        .post(format!("{vm}/api/mail/emails"))
        .bearer_auth("the-runs-token")
        .header("idempotency-key", "k_1")
        .header("content-type", "application/json")
        .header("expect", "100-continue")
        .body("{\"to\":\"someone@example.com\"}")
        .send()
        .await
        .unwrap();
    assert_eq!(answer.status(), StatusCode::OK);
    assert_eq!(answer.headers()["x-request-id"], "r_1");
    assert_eq!(answer.text().await.unwrap(), "{\"id\":\"e_1\"}");
    {
        let asked = asked.lock().unwrap();
        let (method, path, headers, body) = &asked[0];
        assert_eq!((method, path.as_str()), (&Method::POST, "/v1/emails"));
        assert_eq!(headers["authorization"], "Bearer s3cret");
        assert_eq!(headers["idempotency-key"], "k_1");
        assert!(!headers.contains_key("expect"));
        assert_eq!(body, "{\"to\":\"someone@example.com\"}");
    }

    let answer = client
        .get(format!("{vm}/api/mail/emails/e_1?fields=id"))
        .send()
        .await
        .unwrap();
    assert_eq!(answer.status(), StatusCode::OK);
    assert_eq!(asked.lock().unwrap()[1].1, "/v1/emails/e_1?fields=id");

    // Not followed: it would take the key along.
    let answer = client
        .get(format!("{vm}/api/mail/moved"))
        .send()
        .await
        .unwrap();
    assert_eq!(answer.status(), StatusCode::FOUND);
    assert_eq!(
        answer.headers()[header::LOCATION],
        "http://elsewhere.example/"
    );
    assert_eq!(asked.lock().unwrap().len(), 3);

    // What the configuration doesn't allow, or past the hour's calls,
    // never reaches the API.
    for (method, path, status) in [
        (
            Method::DELETE,
            "/api/mail/emails/e_1",
            StatusCode::FORBIDDEN,
        ),
        (Method::GET, "/api/mail/domains", StatusCode::FORBIDDEN),
        (
            Method::GET,
            "/api/mail/emails/a%2F..%2Fb",
            StatusCode::BAD_REQUEST,
        ),
        (Method::GET, "/api/sms/send", StatusCode::NOT_FOUND),
        (
            Method::POST,
            "/api/mail/emails",
            StatusCode::TOO_MANY_REQUESTS,
        ),
    ] {
        let answer = client
            .request(method.clone(), format!("{vm}{path}"))
            .send()
            .await
            .unwrap();
        assert_eq!(answer.status(), status, "{method} {path}");
        let said = answer.text().await.unwrap();
        assert!(said.starts_with("{\"error\":{\"message\":"), "{said}");
    }
    assert_eq!(asked.lock().unwrap().len(), 3);
    scope.close(Duration::from_secs(1)).await;
}

#[test]
fn a_call_stays_below_the_base() {
    let mut api = mail("https://mail.example/v1/");
    api.query = BTreeMap::from([("key".into(), "{secret}".into())]);
    let api = Api::load(&api).unwrap();
    let url = |path: &str, query: Option<&str>| {
        api.url(path, query)
            .map(|(url, below)| (url.to_string(), below))
    };
    assert_eq!(
        url("/emails", Some("key=mine&page=2")),
        Some((
            "https://mail.example/v1/emails?page=2&key=s3cret".into(),
            "/emails".into()
        ))
    );
    assert_eq!(
        url("", None),
        Some(("https://mail.example/v1?key=s3cret".into(), "/".into()))
    );
    for away in [
        "/../emails",
        "/%2e%2E/emails",
        "/emails%2Fbatch",
        "/a%5C..%5Cb",
        "/emails/../../v2",
    ] {
        assert_eq!(url(away, None), None, "{away}");
    }
    // Normalized, it is still below.
    assert_eq!(
        url("/domains/../emails", None).map(|(_, below)| below),
        Some("/emails".into())
    );
}

#[test]
fn none_configured() {
    let apis = Apis::load(&BTreeMap::new()).unwrap();
    assert_eq!(apis.prompt(), "");
    let mut missing = mail("https://mail.example");
    missing.secret_file = "/nonexistent/mail-api-key".into();
    let error = Apis::load(&BTreeMap::from([("mail".to_owned(), missing)]))
        .err()
        .unwrap();
    assert!(format!("{error:#}").contains("in api.mail"), "{error:#}");
}
