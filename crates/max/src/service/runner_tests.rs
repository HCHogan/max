//! The guest's runner and maxx, run here with Node against max's
//! service on TCP: they need nothing of the VM but `/work`, which tests
//! point at a directory of their own, and a call's directory, which is
//! one of the test's.

use std::path::Path;
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use crate::service::tool::TOOLS;
use chrono::Utc;
use serde_json::{Value, json};
use sqlx::PgPool;
use tokio::io::AsyncWriteExt;
use tokio::net::TcpListener;
use tokio::process::Command;

use super::{Context, Services, router, testing};
use crate::conversation::ingest;
use crate::conversation::testing::{from_xiaoming, group, offset, text};
use crate::scope::Scope;

const RUNNER: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../nix/runner.js");

struct Ran {
    status: i32,
    stdout: String,
    stderr: String,
}

/// The service for the VM of `context`'s conversation on a port of
/// its own, in `scope`, its calls run in `context` as the conversation's
/// actor would run them: its URL.
async fn served(scope: &mut Scope, context: Context) -> String {
    let conversation = context.place.conversation;
    let calls = testing::answering(scope, context);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let app = router(calls, axum::Router::new());
    scope.spawn(move |stop| testing::serve(conversation, listener, app, stop));
    url
}

async fn run(url: &str, code: &str) -> Ran {
    run_with(
        json!({ "code": code, "args": { "n": 2 }, "url": url }),
        None,
    )
    .await
}

/// Runs `input` with Max's tools, as part of the call whose directory is
/// `call`, if it is part of one.
async fn run_with(mut input: Value, call: Option<&Path>) -> Ran {
    let tools: Vec<&str> = TOOLS.iter().map(|tool| tool.name).collect();
    input["tools"] = json!(tools);
    let mut command = Command::new("node");
    command
        .arg(RUNNER)
        .env_remove("MAX_CALL")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    if let Some(call) = call {
        command.env("MAX_CALL", call);
    }
    let mut node = command.spawn().expect("node runs the runner");
    let mut stdin = node.stdin.take().unwrap();
    stdin.write_all(input.to_string().as_bytes()).await.unwrap();
    drop(stdin);
    let out = tokio::time::timeout(Duration::from_secs(20), node.wait_with_output())
        .await
        .unwrap()
        .unwrap();
    Ran {
        status: out.status.code().unwrap(),
        stdout: String::from_utf8(out.stdout).unwrap(),
        stderr: String::from_utf8(out.stderr).unwrap(),
    }
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn programs_call_max_tools_and_return(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    let hello = ingest::inbound(
        &mut conn,
        &place,
        from_xiaoming(1, vec![text("你好")]),
        Utc::now(),
        offset(),
    )
    .await
    .unwrap();
    drop(conn);
    let mut scope = Scope::new();
    let url = served(&mut scope, Context::check(Services::bare(pool), place)).await;
    let id = hello.message.id.0;

    let ran = run(&url, "return args.n + 1").await;
    assert_eq!(
        (ran.status, ran.stdout.as_str()),
        (0, "3"),
        "{}",
        ran.stderr
    );

    let ran = run(
        &url,
        "console.log('hi', {a: 1}); process.stdout.write('x\\n'); return {ok: true}",
    )
    .await;
    assert_eq!(ran.stdout, r#"{"ok":true}"#);
    assert_eq!(ran.stderr, "hi { a: 1 }\nx\n");

    let read = format!(
        "const r = await tools.history({{around: {id}, before: 0, after: 0}}); return r.text"
    );
    let ran = run(&url, &read).await;
    assert_eq!(
        ran.stdout,
        format!("[12:01 小明 #{id}]: 你好"),
        "{}",
        ran.stderr
    );

    let missing = format!("await tools.history({{around: {}}})", id + 1);
    let ran = run(&url, &missing).await;
    assert_eq!(ran.status, 1);
    assert!(
        ran.stdout
            .starts_with("ToolError: history: there is no message #"),
        "{}",
        ran.stdout
    );
    assert!(
        ran.stdout.contains("at the program's line 1,"),
        "{}",
        ran.stdout
    );

    let raw = format!(
        "const [a, b] = await Promise.all([max.raw('history', {{around: {id}}}), \
         max.raw('history', {{around: {}}})]); return [a.ok, b.ok, b.error.code]",
        id + 1
    );
    let ran = run(&url, &raw).await;
    assert_eq!(ran.stdout, r#"[true,false,"not_found"]"#, "{}", ran.stderr);

    let ran = run(
        &url,
        &format!("return tools.history({{around: {id}}}).text"),
    )
    .await;
    assert_eq!(ran.status, 1);
    assert!(ran.stdout.contains("await it first"), "{}", ran.stdout);

    let ran = run(&url, "return (").await;
    assert_eq!(ran.status, 1);
    assert!(ran.stdout.starts_with("SyntaxError"), "{}", ran.stdout);

    // Every tool is a program's, those the prompt doesn't declare too;
    // and what was the runner's own request until 2026-11-12 is gone.
    let ran = run(
        &url,
        "return [typeof tools.say, typeof tools.file, typeof max.file]",
    )
    .await;
    assert_eq!(ran.stdout, r#"["function","function","undefined"]"#);

    scope.close(Duration::from_secs(5)).await;
}
