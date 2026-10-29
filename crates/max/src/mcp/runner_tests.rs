//! The guest's runner, run here with Node against the MCP service on TCP:
//! it needs nothing of the VM but `/work`, which these programs don't use.

use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use max_core::tools::MAX_TOOLS;
use serde_json::json;
use sqlx::PgPool;
use tokio::io::AsyncWriteExt;
use tokio::net::TcpListener;
use tokio::process::Command;

use super::{Context, Sessions, serve};
use crate::conversation::ingest;
use crate::conversation::testing::{from_xiaoming, group, offset, text};
use crate::scope::Scope;

const RUNNER: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../nix/runner.js");

struct Ran {
    status: i32,
    stdout: String,
    stderr: String,
}

async fn run(mcp: &str, token: &str, code: &str) -> Ran {
    let tools: Vec<&str> = MAX_TOOLS.iter().map(|tool| tool.name).collect();
    let input =
        json!({ "code": code, "args": { "n": 2 }, "token": token, "tools": tools, "mcp": mcp });
    let mut node = Command::new("node")
        .arg(RUNNER)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .expect("node runs the runner");
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
        &from_xiaoming(1, vec![text("你好")]),
        Utc::now(),
        offset(),
    )
    .await
    .unwrap();
    drop(conn);
    let conversation = place.conversation;
    let sessions = Sessions::default();
    let grant = sessions.open(Context {
        pool,
        place,
        offset: offset(),
        page_tokens: 2000,
        search: None,
        work: None,
        store: None,
        poster: None,
        embedder: None,
        admin: None,
    });
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mcp = format!("http://{}/mcp", listener.local_addr().unwrap());
    let mut scope = Scope::new();
    let served = sessions.clone();
    scope.spawn(move |stop| serve(listener, conversation, served, stop));
    let token = grant.token();
    let id = hello.message.id.0;

    let ran = run(&mcp, token, "return args.n + 1").await;
    assert_eq!(
        (ran.status, ran.stdout.as_str()),
        (0, "3"),
        "{}",
        ran.stderr
    );

    let ran = run(
        &mcp,
        token,
        "console.log('hi', {a: 1}); process.stdout.write('x\\n'); return {ok: true}",
    )
    .await;
    assert_eq!(ran.stdout, r#"{"ok":true}"#);
    assert_eq!(ran.stderr, "hi { a: 1 }\nx\n");

    let read = format!("const r = await tools.context_read({{id: {id}}}); return r.text");
    let ran = run(&mcp, token, &read).await;
    assert_eq!(
        ran.stdout,
        format!("[12:01 小明 #{id}]: 你好"),
        "{}",
        ran.stderr
    );

    let missing = format!("await tools.context_read({{id: {}}})", id + 1);
    let ran = run(&mcp, token, &missing).await;
    assert_eq!(ran.status, 1);
    assert!(
        ran.stdout.starts_with("ToolError: context_read: 这里没有"),
        "{}",
        ran.stdout
    );
    assert!(ran.stdout.contains("at 程序第 1 行"), "{}", ran.stdout);

    let raw = format!(
        "const [a, b] = await Promise.all([max.raw('context_read', {{id: {id}}}), \
         max.raw('context_read', {{id: {}}})]); return [a.ok, b.ok, b.error.code]",
        id + 1
    );
    let ran = run(&mcp, token, &raw).await;
    assert_eq!(ran.stdout, r#"[true,false,"not_found"]"#, "{}", ran.stderr);
    assert_eq!(grant.calls()["context_read"], (2, 2));

    let ran = run(
        &mcp,
        token,
        &format!("return tools.context_read({{id: {id}}}).text"),
    )
    .await;
    assert_eq!(ran.status, 1);
    assert!(ran.stdout.contains("先 await"), "{}", ran.stdout);

    let ran = run(&mcp, token, "return (").await;
    assert_eq!(ran.status, 1);
    assert!(ran.stdout.starts_with("SyntaxError"), "{}", ran.stdout);

    let ran = run(&mcp, "nope", &read).await;
    assert!(ran.stdout.contains("token 不对"), "{}", ran.stdout);

    scope.close(Duration::from_secs(5)).await;
}

/// The browser's SDK, as far as it goes without a browser: here the runner
/// has no camoufox, and snapshot gets a page that only answers.
#[tokio::test]
async fn the_browser_sdk_without_a_browser() {
    let nowhere = "http://127.0.0.1:9/mcp";
    let ran = run(nowhere, "-", "await max.browser()").await;
    assert_eq!(ran.status, 1);
    assert!(
        ran.stdout.starts_with("Error: 这里没有浏览器"),
        "{}",
        ran.stdout
    );
    let ran = run(nowhere, "-", "await max.browser('https://example.com')").await;
    assert!(ran.stdout.starts_with("TypeError"), "{}", ran.stdout);

    let page = "const page = { evaluate: async (f, options) => options.selector === '#none' ? null : \
         ({ elements: [{ tag: 'button', selector: '#go', role: 'button', name: '搜索' }], truncated: false, \
         page: typeof f, options }), url: () => 'https://example.com/', title: async () => '例子' };";
    let ran = run(
        nowhere,
        "-",
        &format!("{page} return max.snapshot(page, {{ selector: 'form' }})"),
    )
    .await;
    assert_eq!(
        ran.stdout,
        r##"{"url":"https://example.com/","title":"例子","elements":[{"tag":"button","selector":"#go","role":"button","name":"搜索"}],"truncated":false,"page":"function","options":{"selector":"form","limit":100}}"##,
        "{}",
        ran.stderr
    );
    let ran = run(
        nowhere,
        "-",
        &format!("{page} return max.snapshot(page, {{ selector: '#none' }})"),
    )
    .await;
    assert_eq!(ran.status, 1);
    assert!(
        ran.stdout.starts_with("Error: 页面上没有 #none"),
        "{}",
        ran.stdout
    );
    for wrong in ["max.snapshot('page')", "max.snapshot(page, { limit: 0 })"] {
        let ran = run(nowhere, "-", &format!("{page} return {wrong}")).await;
        assert!(
            ran.stdout.starts_with("TypeError"),
            "{wrong}: {}",
            ran.stdout
        );
    }
}
