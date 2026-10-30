use std::process::Command as Std;
use std::sync::{Arc, Mutex};

use axum::Router;
use axum::extract::State;
use axum::http::{Method as Verb, StatusCode, Uri};
use axum::routing::{get, patch, post};
use serde_json::Value;
use tokio::net::TcpListener;
use tokio_util::sync::CancellationToken;

use super::*;

/// The fake GitHub: what it holds, and what it was asked.
#[derive(Default)]
struct Hub {
    /// Pull requests Max opened in the last day.
    made: u64,
    forked: bool,
    searched: Vec<String>,
    /// The writes that reached it: method, path and body.
    written: Vec<(String, String, Value)>,
}

type Shared = Arc<Mutex<Hub>>;

fn repo(full_name: &str, owner: &str) -> String {
    json!({ "full_name": full_name, "default_branch": "main", "owner": { "login": owner } })
        .to_string()
}

async fn upstream() -> (StatusCode, String) {
    (StatusCode::OK, repo("octo/hello", "octo"))
}

async fn fork(State(hub): State<Shared>) -> (StatusCode, String) {
    hub.lock().unwrap().forked = true;
    (StatusCode::ACCEPTED, repo("maxxagent/hello", "maxxagent"))
}

async fn forked(State(hub): State<Shared>) -> (StatusCode, String) {
    if hub.lock().unwrap().forked {
        (StatusCode::OK, repo("maxxagent/hello", "maxxagent"))
    } else {
        (StatusCode::NOT_FOUND, r#"{"message":"Not Found"}"#.into())
    }
}

async fn search(State(hub): State<Shared>, uri: Uri) -> (StatusCode, String) {
    let mut hub = hub.lock().unwrap();
    hub.searched
        .push(uri.query().unwrap_or_default().to_owned());
    (
        StatusCode::OK,
        json!({ "total_count": hub.made }).to_string(),
    )
}

/// Who wrote issue 3 (Max) and 4, and comment 9.
async fn written_by(uri: Uri) -> (StatusCode, String) {
    let login = match uri.path().rsplit('/').next() {
        Some("3") => "maxxagent",
        _ => "octo",
    };
    (
        StatusCode::OK,
        json!({ "user": { "login": login } }).to_string(),
    )
}

async fn record(
    State(hub): State<Shared>,
    method: Verb,
    uri: Uri,
    body: String,
) -> (StatusCode, String) {
    let body = serde_json::from_str(&body).unwrap_or(Value::Null);
    let path = uri.path().to_owned();
    hub.lock()
        .unwrap()
        .written
        .push((method.to_string(), path, body));
    let pull = json!({ "number": 7, "html_url": "https://github.com/octo/hello/pull/7" });
    (StatusCode::CREATED, pull.to_string())
}

/// git with nobody's configuration, as the tests' guest and GitHub.
fn git(dir: &Path, args: &[&str]) -> String {
    let output = Std::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@example.com"])
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

/// GitHub's repositories under `root`: octo/hello with three commits, and
/// Max's fork of it. Then a guest's shallow clone with a commit on top,
/// bundled as the guide says: the bundle, and the commit.
fn repositories(root: &Path) -> (Vec<u8>, String) {
    let upstream = root.join("octo/hello.git");
    std::fs::create_dir_all(&upstream).unwrap();
    git(
        &upstream,
        &["init", "--quiet", "--bare", "--initial-branch=main"],
    );
    let work = root.join("work");
    git(
        root,
        &["clone", "--quiet", upstream.to_str().unwrap(), "work"],
    );
    for n in 1..=3 {
        std::fs::write(work.join("README"), format!("{n}\n")).unwrap();
        git(&work, &["add", "README"]);
        git(&work, &["commit", "--quiet", "-m", &format!("c{n}")]);
    }
    git(&work, &["push", "--quiet", "origin", "HEAD:main"]);
    // GitHub fetches any commit it has by id.
    git(
        &upstream,
        &["config", "uploadpack.allowAnySHA1InWant", "true"],
    );
    git(
        root,
        &[
            "clone",
            "--quiet",
            "--bare",
            upstream.to_str().unwrap(),
            "maxxagent/hello.git",
        ],
    );

    let guest = root.join("guest");
    let url = format!("file://{}", upstream.display());
    git(root, &["clone", "--quiet", "--depth=1", &url, "guest"]);
    std::fs::write(guest.join("README"), "fixed\n").unwrap();
    git(&guest, &["commit", "--quiet", "-am", "Fix the README"]);
    git(
        &guest,
        &[
            "bundle",
            "create",
            "--quiet",
            "../pr.bundle",
            "HEAD",
            "--not",
            "--remotes",
        ],
    );
    let commit = git(&guest, &["rev-parse", "HEAD"]);
    (std::fs::read(root.join("pr.bundle")).unwrap(), commit)
}

/// Runs `test` against the fake GitHub, with git's repositories in a
/// scratch directory.
async fn with_hub<F, T>(hub: Hub, test: F)
where
    F: FnOnce(GitHub, Shared, PathBuf) -> T,
    T: Future<Output = ()>,
{
    let shared: Shared = Arc::new(Mutex::new(hub));
    let app = Router::new()
        .route("/repos/octo/hello", get(upstream))
        .route("/repos/octo/hello/pulls", post(record))
        .route("/repos/octo/hello/forks", post(fork))
        .route("/repos/octo/hello/issues/{number}", get(written_by))
        .route(
            "/repos/octo/hello/issues/comments/{id}",
            get(written_by).patch(record),
        )
        .route("/repos/octo/hello/issues/{number}/comments", post(record))
        .route("/repos/octo/hello/pulls/{number}", patch(record))
        .route("/repos/maxxagent/hello", get(forked))
        .route(
            "/repos/maxxagent/hello/merge-upstream",
            post(|| async { (StatusCode::OK, "{}") }),
        )
        .route("/search/issues", get(search))
        .with_state(Arc::clone(&shared));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let api = format!("http://{}", listener.local_addr().unwrap());
    let stop = CancellationToken::new();
    let server = axum::serve(listener, app).with_graceful_shutdown(stop.clone().cancelled_owned());
    let scratch = Scratch::new().unwrap();
    let root = scratch.0.clone();
    let github = GitHub::new(
        &api,
        &format!("file://{}", root.display()),
        "maxxagent".into(),
        "TOKEN".into(),
    )
    .unwrap();
    let test = async {
        test(github, Arc::clone(&shared), root).await;
        stop.cancel();
    };
    let (served, ()) = tokio::join!(server, test);
    served.unwrap();
}

fn opening() -> Value {
    json!({ "title": "Fix the README", "head": "maxxagent:fix-readme", "base": "main", "body": "It said 3.\n" })
}

#[tokio::test]
async fn a_bundle_is_pushed_to_the_fork_and_opened_as_a_pull_request() {
    with_hub(Hub::default(), |github, hub, root| async move {
        let (bundle, commit) = repositories(&root);
        let pushed = github
            .push("octo/hello", "fix-readme", &bundle)
            .await
            .unwrap();
        assert_eq!(
            pushed,
            Pushed {
                repo: "maxxagent/hello".into(),
                head: "maxxagent:fix-readme".into(),
            }
        );
        let fork = root.join("maxxagent/hello.git");
        assert_eq!(git(&fork, &["rev-parse", "fix-readme"]), commit);

        let reply = github
            .api(Method::POST, "/repos/octo/hello/pulls", Some(opening()))
            .await
            .unwrap();
        assert_eq!(
            (reply.status, reply.body["number"].clone()),
            (201, json!(7))
        );
        let hub = hub.lock().unwrap();
        assert!(
            hub.searched[0].contains("author%3Amaxxagent"),
            "{}",
            hub.searched[0]
        );
        let (_, path, body) = &hub.written[0];
        assert_eq!(path, "/repos/octo/hello/pulls");
        assert_eq!(body["head"], "maxxagent:fix-readme");
        assert_eq!(body["body"], format!("It said 3.\n\n{FOOTER}"));
    })
    .await;
}

#[tokio::test]
async fn a_new_pull_request_stops_at_the_days_cap_but_a_push_doesnt() {
    let hub = Hub {
        made: DAILY,
        ..Hub::default()
    };
    with_hub(hub, |github, hub, root| async move {
        let refused = github
            .api(Method::POST, "/repos/octo/hello/pulls", Some(opening()))
            .await
            .unwrap_err();
        assert!(
            matches!(&refused, Error::Refused(why) if why.contains("一天最多")),
            "{refused:?}"
        );
        let (bundle, commit) = repositories(&root);
        github
            .push("octo/hello", "fix-readme", &bundle)
            .await
            .unwrap();
        assert_eq!(
            git(
                &root.join("maxxagent/hello.git"),
                &["rev-parse", "fix-readme"]
            ),
            commit
        );
        assert!(hub.lock().unwrap().written.is_empty());
    })
    .await;
}

#[tokio::test]
async fn max_writes_only_what_is_its_own() {
    with_hub(Hub::default(), |github, hub, _| async move {
        // Its pull request, #3: closed, its description rewritten.
        let closing = json!({ "state": "closed", "body": "Not needed." });
        let reply = github
            .api(Method::PATCH, "/repos/octo/hello/pulls/3", Some(closing))
            .await
            .unwrap();
        assert_eq!(reply.status, 201);
        let comment = json!({ "body": "Rebased." });
        github
            .api(
                Method::POST,
                "/repos/octo/hello/issues/3/comments",
                Some(comment.clone()),
            )
            .await
            .unwrap();
        // Someone else's.
        let refused = |result: Result<Reply, Error>| matches!(result, Err(Error::Refused(_)));
        let theirs = github.api(
            Method::PATCH,
            "/repos/octo/hello/pulls/4",
            Some(json!({ "state": "closed" })),
        );
        assert!(refused(theirs.await));
        let edit = github.api(
            Method::PATCH,
            "/repos/octo/hello/issues/comments/9",
            Some(comment.clone()),
        );
        assert!(refused(edit.await));
        let issue = github.api(Method::POST, "/repos/octo/hello/issues", Some(comment));
        assert!(refused(issue.await));
        assert!(refused(
            github
                .api(Method::PUT, "/user/starred/octo/hello", None)
                .await
        ));
        let other = github.api(
            Method::POST,
            "/repos/octo/hello/pulls",
            Some(json!({ "head": "octo:main" })),
        );
        assert!(refused(other.await));
        assert!(refused(
            github.api(Method::GET, "/repos/octo/../x", None).await
        ));
        // Reads are free.
        let read = github
            .api(Method::GET, "/repos/octo/hello?per_page=1", None)
            .await
            .unwrap();
        assert_eq!(read.body["full_name"], "octo/hello");

        let hub = hub.lock().unwrap();
        let written: Vec<(&str, &str)> = hub
            .written
            .iter()
            .map(|(method, path, _)| (method.as_str(), path.as_str()))
            .collect();
        assert_eq!(
            written,
            [
                ("PATCH", "/repos/octo/hello/pulls/3"),
                ("POST", "/repos/octo/hello/issues/3/comments")
            ]
        );
        assert_eq!(hub.written[0].2["body"], format!("Not needed.\n\n{FOOTER}"));
        assert_eq!(hub.written[1].2["body"], "Rebased.");
    })
    .await;
}

#[tokio::test]
async fn a_push_checks_its_names_and_bundle() {
    with_hub(Hub::default(), |github, _, _| async move {
        let bundle = format!("# v2 git bundle\n{} HEAD\n\nPACK", "a".repeat(40));
        let refused = github
            .push("octo/hello/x", "fix", bundle.as_bytes())
            .await
            .unwrap_err();
        assert!(matches!(refused, Error::Refused(_)));
        let refused = github
            .push("octo/hello", "-f", bundle.as_bytes())
            .await
            .unwrap_err();
        assert!(matches!(refused, Error::Refused(_)));
        let refused = github
            .push("octo/hello", "fix", b"PK\x03\x04")
            .await
            .unwrap_err();
        assert!(
            matches!(&refused, Error::Refused(why) if why.contains("git bundle")),
            "{refused:?}"
        );
    })
    .await;
}

#[test]
fn a_bundles_header_is_read() {
    let id = "a".repeat(40);
    let other = "b".repeat(40);
    let bundle =
        format!("# v2 git bundle\n-{id} c3\n{other} refs/heads/main\n{other} HEAD\n\nPACK");
    assert_eq!(
        header(bundle.as_bytes()),
        Some(Header {
            prerequisites: vec![id.clone()],
            head: "HEAD".into(),
        })
    );
    let branch = format!("# v3 git bundle\n@object-format=sha1\n{other} refs/heads/fix\n\nPACK");
    assert_eq!(header(branch.as_bytes()).unwrap().head, "refs/heads/fix");
    let option = format!("# v2 git bundle\n{other} --upload-pack=x\n\nPACK");
    assert_eq!(header(option.as_bytes()), None);
    assert!(branch_name("max/fix-readme") && !branch_name("a..b") && !branch_name("x.lock"));
    assert!(repo_name("octo/hello.rs") && !repo_name("octo/..") && !repo_name("octo"));
}
