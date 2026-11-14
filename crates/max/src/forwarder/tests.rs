use std::time::Duration;

use axum::body::Bytes;
use axum::http::{Method, Uri};
use axum::routing::{any, get};
use futures_util::stream;
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::oneshot;
use tokio::time::timeout;

use super::*;

const PATIENCE: Duration = Duration::from_secs(10);

/// A configuration with no model for the agents and no APIs; `more` is
/// added to it.
fn config(more: &str) -> String {
    format!(
        r#"
        [database]
        url = "postgresql:///nowhere?host=/nonexistent"

        [llm]
        default = {{ model = "local/small" }}
        intent = {{ model = "local/small" }}

        [llm.providers.local]
        base_url = "http://127.0.0.1:9/v1"
        protocol = "chat"

        [llm.providers.local.models.small]
        context_window = 32768
        {more}
        "#
    )
}

/// A VM's directory, conversation 7's, with nothing in it: short, as a
/// socket's path must be.
fn vm() -> PathBuf {
    let dir = PathBuf::from(format!("/tmp/max-fw-{:08x}/7", rand::random::<u32>()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A stand-in for max at `dir`'s socket: it says what it was asked, and
/// streams two rows.
fn max(scope: &mut Scope, dir: &Path) {
    let listener = UnixListener::bind(dir.join(MAX)).unwrap();
    let asked = |method: Method, uri: Uri, headers: HeaderMap, body: Bytes| async move {
        let kept = headers.get("x-kept").and_then(|kept| kept.to_str().ok());
        let said = json!({
            "method": method.as_str(),
            "asked": uri.to_string(),
            "kept": kept,
            "host": headers.get("host").and_then(|host| host.to_str().ok()),
            "body": String::from_utf8_lossy(&body),
        });
        ([("x-from", "max")], said.to_string())
    };
    let rows = || async {
        let rows = stream::unfold(0, |sent| async move {
            if sent == 2 {
                return None;
            }
            tokio::time::sleep(Duration::from_millis(100 * sent)).await;
            let row = Bytes::from(format!("{{\"id\":{}}}\n", sent + 1));
            Some((Ok::<_, std::io::Error>(row), sent + 1))
        });
        ([("max-head", "5")], Body::from_stream(rows))
    };
    let app = Router::new()
        .route("/tools/{name}", any(asked))
        .route("/events", get(rows));
    scope.spawn(move |stop| async move {
        let _ = axum::serve(listener, app)
            .with_graceful_shutdown(stop.cancelled_owned())
            .await;
    });
}

/// What the guest's calls reach: the forwarder's socket in `dir`.
fn guest(dir: &Path) -> reqwest::Client {
    reqwest::Client::builder()
        .unix_socket(dir.join(SOCKET))
        .pool_max_idle_per_host(0)
        .build()
        .unwrap()
}

/// The forwarder's answer to `path`: its status, and what it said.
async fn asks(guest: &reqwest::Client, path: &str) -> (StatusCode, String) {
    let answer = guest.get(format!("http://host{path}")).send().await;
    let answer = answer.unwrap();
    (answer.status(), answer.text().await.unwrap())
}

/// Until `path` is answered with `said` in it.
async fn until(guest: &reqwest::Client, path: &str, said: &str) {
    let answered = async {
        loop {
            if asks(guest, path).await.1.contains(said) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
    };
    timeout(PATIENCE, answered)
        .await
        .unwrap_or_else(|_| panic!("{path} never said {said}"));
}

#[tokio::test]
async fn a_forwarder_carries_its_own_and_passes_the_rest_to_max() {
    let dir = vm();
    let first = dir.join("first.toml");
    std::fs::write(&first, config("")).unwrap();
    configure(&dir, &first).await.unwrap();
    let (named, read) = configured(&dir).unwrap();
    assert_eq!(named.path, first);
    let mut scope = Scope::new();
    let stop = CancellationToken::new();
    let (stopped, served) = (stop.clone(), dir.clone());
    let (done, ended) = oneshot::channel();
    scope.spawn(move |_| async move {
        let _ = done.send(run(&served, named, read, stopped).await);
    });
    let guest = guest(&dir);
    let listening = async {
        while !dir.join(SOCKET).exists() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    };
    timeout(PATIENCE, listening).await.unwrap();

    // Its own, whether max is there or not: the models, of which the
    // agents have none here, and the APIs, of which there are none.
    let (status, said) = asks(&guest, "/llm").await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(
        said.contains("no model is configured for background agents"),
        "{said}"
    );
    let (status, said) = asks(&guest, "/api/mail/emails").await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(
        said.contains("the host has no keyed APIs configured"),
        "{said}"
    );

    // The rest is max's. While nothing listens there it is away, and the
    // guest's client asks again.
    let away = guest.get("http://host/tools").send().await.unwrap();
    assert_eq!(away.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(away.headers()["max-away"], "1");

    // Once max is back it is passed on as it was asked, and the answer
    // comes back as max gave it.
    max(&mut scope, &dir);
    let answer = guest
        .post("http://host/tools/say?now=1")
        .header("x-kept", "yes")
        .body("{\"text\":\"好\"}")
        .send()
        .await
        .unwrap();
    assert_eq!(answer.status(), StatusCode::OK);
    assert_eq!(answer.headers()["x-from"], "max");
    let said: Value = answer.json().await.unwrap();
    assert_eq!(
        said,
        json!({
            "method": "POST",
            "asked": "/tools/say?now=1",
            "kept": "yes",
            "host": "max",
            "body": "{\"text\":\"好\"}",
        })
    );
    // A stream comes as a stream, with its headers.
    let mut rows = guest.get("http://host/events").send().await.unwrap();
    assert_eq!(rows.headers()["max-head"], "5");
    let first_row = timeout(PATIENCE, rows.chunk()).await.unwrap().unwrap();
    assert_eq!(first_row.unwrap(), "{\"id\":1}\n");
    let second = timeout(PATIENCE, rows.chunk()).await.unwrap().unwrap();
    assert_eq!(second.unwrap(), "{\"id\":2}\n");

    // max names another configuration, as a deploy's does when the new
    // max attaches: the forwarder reads it without a restart.
    let key = dir.join("key");
    std::fs::write(&key, "s3cret\n").unwrap();
    let mail = format!(
        "[api.mail]\nbase_url = \"http://127.0.0.1:9/v1\"\nsecret_file = \"{}\"\n\
         headers = {{ Authorization = \"Bearer {{secret}}\" }}\nabout = \"发邮件。\"\n",
        key.display()
    );
    let second = dir.join("second.toml");
    std::fs::write(&second, config(&mail)).unwrap();
    configure(&dir, &second).await.unwrap();
    until(
        &guest,
        "/api/sms/send",
        "there is no API named sms; there are: mail",
    )
    .await;
    // Named again, the same file is read again: what it names may be
    // new, as a key is.
    let note = mail.replace("api.mail", "api.note");
    std::fs::write(&second, config(&format!("{mail}\n{note}"))).unwrap();
    configure(&dir, &second).await.unwrap();
    let both = "there is no API named sms; there are: mail, note";
    until(&guest, "/api/sms/send", both).await;
    // A newer max's may have what this build doesn't know, beside what
    // a forwarder reads: that is left unread.
    let newer = dir.join("newer.toml");
    let post = mail.replace("api.mail", "api.post");
    let beside = format!("[from_a_newer_max]\nkey = 1\n\n{post}");
    std::fs::write(&newer, config(&beside)).unwrap();
    configure(&dir, &newer).await.unwrap();
    let posts = "there is no API named sms; there are: post";
    until(&guest, "/api/sms/send", posts).await;
    // One it can't read is left, and it goes on with the last.
    let unread = dir.join("unread.toml");
    let models = config("").replace("protocol = \"chat\"", "protocol = \"chat\"\nnewer = 1");
    std::fs::write(&unread, models).unwrap();
    configure(&dir, &unread).await.unwrap();
    tokio::time::sleep(LOOK + Duration::from_millis(500)).await;
    until(&guest, "/api/sms/send", posts).await;

    stop.cancel();
    timeout(PATIENCE, ended).await.unwrap().unwrap().unwrap();
    scope.close(Duration::from_secs(1)).await;
    let _ = std::fs::remove_dir_all(dir.parent().unwrap());
}

/// A call max drops in the middle is a failed call, which may have
/// acted; one the guest drops is dropped at max too, which cancels it.
#[tokio::test]
async fn a_call_ends_at_max_as_it_ends_at_the_guest() {
    let dir = vm();
    let listener = UnixListener::bind(dir.join(MAX)).unwrap();
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
    let max = Max::at(&dir.join(MAX)).unwrap();
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
