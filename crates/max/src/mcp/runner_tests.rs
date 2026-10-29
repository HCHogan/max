//! The guest's runner, run here with Node against the MCP service on TCP:
//! it needs nothing of the VM but `/work`, which tests point at a
//! directory of their own.

use std::io::Cursor;
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use chrono::Utc;
use max_core::tools::MAX_TOOLS;
use serde_json::{Value, json};
use sqlx::PgPool;
use tokio::io::AsyncWriteExt;
use tokio::net::TcpListener;
use tokio::process::Command;

use super::{Context, Sessions, serve};
use crate::conversation::ingest;
use crate::conversation::testing::{from_xiaoming, group, offset, text};
use crate::media::store::Store;
use crate::scope::Scope;

const RUNNER: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../nix/runner.js");

struct Ran {
    status: i32,
    stdout: String,
    stderr: String,
}

async fn run(mcp: &str, token: &str, code: &str) -> Ran {
    run_with(json!({ "code": code, "args": { "n": 2 }, "token": token, "mcp": mcp })).await
}

/// Runs `input` with Max's tools.
async fn run_with(mut input: Value) -> Ran {
    let tools: Vec<&str> = MAX_TOOLS.iter().map(|tool| tool.name).collect();
    input["tools"] = json!(tools);
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
/// has no playwright-core, and snapshot gets a page that only answers.
#[tokio::test]
async fn the_browser_sdk_without_a_browser() {
    let nowhere = "http://127.0.0.1:9/mcp";
    for open in ["max.browser()", "max.page()"] {
        let ran = run(nowhere, "-", &format!("await {open}")).await;
        assert_eq!(ran.status, 1);
        assert!(
            ran.stdout.starts_with("Error: 这里没有浏览器"),
            "{}",
            ran.stdout
        );
    }

    // Answers as Playwright would, saying what it was asked.
    let page = "const page = { ariaSnapshot: async options => `- button \"搜索\" [ref=e2] ${JSON.stringify(options)}`, \
         locator: selector => ({ first: () => ({ ariaSnapshot: async options => \
         `- ${selector} [ref=e1] ${JSON.stringify(options)}` }) }), \
         url: () => 'https://example.com/', title: async () => '例子' };";
    let ran = run(nowhere, "-", &format!("{page} return max.snapshot(page)")).await;
    assert_eq!(
        ran.stdout, "例子\nhttps://example.com/\n- button \"搜索\" [ref=e2] {\"mode\":\"ai\"}",
        "{}",
        ran.stderr
    );
    let narrowed = format!("{page} return max.snapshot(page, {{ selector: 'form', depth: 2 }})");
    let ran = run(nowhere, "-", &narrowed).await;
    assert_eq!(
        ran.stdout, "例子\nhttps://example.com/\n- form [ref=e1] {\"mode\":\"ai\",\"depth\":2}",
        "{}",
        ran.stderr
    );
    for wrong in ["max.snapshot('page')", "max.snapshot(page, { depth: 0 })"] {
        let ran = run(nowhere, "-", &format!("{page} return {wrong}")).await;
        assert!(
            ran.stdout.starts_with("TypeError"),
            "{wrong}: {}",
            ran.stdout
        );
    }
}

fn png(width: u32) -> Vec<u8> {
    let mut bytes = Cursor::new(Vec::new());
    image::RgbImage::new(width, 1)
        .write_to(&mut bytes, image::ImageFormat::Png)
        .unwrap();
    bytes.into_inner()
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn programs_show_the_model_pictures(pool: PgPool) {
    let dir = std::env::temp_dir().join(format!("max-shown-{:016x}", rand::random::<u64>()));
    let work = dir.join("work");
    std::fs::create_dir_all(&work).unwrap();
    std::fs::write(work.join("shot.png"), png(3)).unwrap();
    std::fs::write(work.join("notes.txt"), "不是图").unwrap();
    let store = Arc::new(Store::open(&dir.join("store")).await.unwrap());
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    drop(conn);
    let conversation = place.conversation;
    let sessions = Sessions::default();
    let grant = sessions.open(Context {
        pool,
        place,
        offset: offset(),
        page_tokens: 2000,
        search: None,
        work: Some(work.clone()),
        store: Some(Arc::clone(&store)),
        poster: None,
        embedder: None,
        admin: None,
    });
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mcp = format!("http://{}/mcp", listener.local_addr().unwrap());
    let mut scope = Scope::new();
    let served = sessions.clone();
    scope.spawn(move |stop| serve(listener, conversation, served, stop));
    let pngs = |widths: &[u32]| -> Vec<String> {
        widths
            .iter()
            .map(|&width| STANDARD.encode(png(width)))
            .collect()
    };
    let input = |code: &str, args: Value| json!({ "code": code, "args": args, "token": grant.token(), "mcp": mcp, "work": work });

    // A file, the same file again, bytes, and a file that isn't one.
    let code = "const a = await max.image('/work/shot.png'); await max.image('shot.png'); \
         const b = await max.image(Buffer.from(args.pngs[0], 'base64')); \
         let failed; try { await max.image('/work/notes.txt') } catch (e) { failed = e.message } \
         let wrong; try { await max.image(42) } catch (e) { wrong = e.name } \
         return [a, b, failed, wrong]";
    let ran = run_with(input(code, json!({ "pngs": pngs(&[2]) }))).await;
    assert_eq!(
        ran.stdout,
        r#"[{"height":1,"width":3},{"height":1,"width":2},"max.image: /work/notes.txt 不是解得开的 PNG、JPEG、GIF、WebP（not_a_picture）","TypeError"]"#,
        "{}",
        ran.stderr
    );
    let shown = grant.shown();
    assert_eq!(shown.len(), 2);
    assert_eq!(std::fs::read(store.path(&shown[0])).unwrap(), png(3));
    // The bytes' file is gone once the host has its copy.
    let left: Vec<_> = std::fs::read_dir(work.join(".max/shown"))
        .unwrap()
        .collect();
    assert!(left.is_empty(), "{left:?}");
    // Not counted among Max's tools: the model sees the pictures.
    assert!(grant.calls().is_empty());

    let code = "for (const png of args.pngs) await max.image(Buffer.from(png, 'base64'))";
    let ran = run_with(input(code, json!({ "pngs": pngs(&[4, 5, 6]) }))).await;
    assert_eq!(ran.status, 1);
    assert!(
        ran.stdout
            .starts_with("ToolError: max.image: 一次 run_code 最多交 4 张图"),
        "{}",
        ran.stdout
    );
    assert_eq!(grant.shown().len(), 4);

    scope.close(Duration::from_secs(5)).await;
    let _ = std::fs::remove_dir_all(&dir);
}
