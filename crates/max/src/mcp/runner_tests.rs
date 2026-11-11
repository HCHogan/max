//! The guest's runner and maxx, run here with Node against the MCP
//! service on TCP: they need nothing of the VM but `/work`, which tests
//! point at a directory of their own.

use std::io::Cursor;
use std::path::Path;
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use crate::mcp::tool::TOOLS;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use chrono::Utc;
use max_core::ids::ConversationId;
use max_core::item::Part;
use max_core::message::{MediaKind, MediaMeta, MediaRef, Node};
use max_db::media::{self, Blob};
use serde_json::{Value, json};
use sqlx::PgPool;
use tokio::io::AsyncWriteExt;
use tokio::net::TcpListener;
use tokio::process::Command;

use super::{Context, Services, Sessions, serve};
use crate::conversation::Signal;
use crate::conversation::ingest;
use crate::conversation::testing::{from_xiaoming, group, group_named, offset, text};
use crate::inbound::InNode;
use crate::media::store::Store;
use crate::scope::Scope;

const RUNNER: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../nix/runner.js");
const MAXX: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../nix/maxx.js");

struct Ran {
    status: i32,
    stdout: String,
    stderr: String,
}

/// The MCP service for `conversation`'s VM on a port of its own: its URL,
/// and the scope it runs in.
async fn served(sessions: &Sessions, conversation: ConversationId) -> (String, Scope) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mcp = format!("http://{}/mcp", listener.local_addr().unwrap());
    let mut scope = Scope::new();
    let sessions = sessions.clone();
    scope.spawn(move |stop| serve(listener, conversation, sessions, stop));
    (mcp, scope)
}

/// Only the database, and `store`.
fn stored(pool: PgPool, store: &Arc<Store>) -> Services {
    Services {
        store: Some(Arc::clone(store)),
        ..Services::bare(pool)
    }
}

/// The content store's name for what a program showed.
fn sha256(part: &Part) -> &str {
    match part {
        Part::Media {
            media: MediaRef::Blob(sha256),
        }
        | Part::Video {
            media: MediaRef::Blob(sha256),
            ..
        } => sha256,
        _ => panic!("not what a program shows: {part:?}"),
    }
}

async fn run(mcp: &str, token: &str, code: &str) -> Ran {
    run_with(json!({ "code": code, "args": { "n": 2 }, "token": token, "mcp": mcp })).await
}

/// Runs `input` with Max's tools.
async fn run_with(mut input: Value) -> Ran {
    let tools: Vec<&str> = TOOLS
        .iter()
        .filter(|tool| tool.turn)
        .map(|tool| tool.name)
        .collect();
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
        from_xiaoming(1, vec![text("你好")]),
        Utc::now(),
        offset(),
    )
    .await
    .unwrap();
    drop(conn);
    let conversation = place.conversation;
    let sessions = Sessions::default();
    let grant = sessions.open(Context::check(Services::bare(pool), place));
    let (mcp, scope) = served(&sessions, conversation).await;
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

    let read = format!(
        "const r = await tools.history({{around: {id}, before: 0, after: 0}}); return r.text"
    );
    let ran = run(&mcp, token, &read).await;
    assert_eq!(
        ran.stdout,
        format!("[12:01 小明 #{id}]: 你好"),
        "{}",
        ran.stderr
    );

    let missing = format!("await tools.history({{around: {}}})", id + 1);
    let ran = run(&mcp, token, &missing).await;
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
    let ran = run(&mcp, token, &raw).await;
    assert_eq!(ran.stdout, r#"[true,false,"not_found"]"#, "{}", ran.stderr);
    assert_eq!(grant.calls()["history"], (2, 2));

    let ran = run(
        &mcp,
        token,
        &format!("return tools.history({{around: {id}}}).text"),
    )
    .await;
    assert_eq!(ran.status, 1);
    assert!(ran.stdout.contains("await it first"), "{}", ran.stdout);

    let ran = run(&mcp, token, "return (").await;
    assert_eq!(ran.status, 1);
    assert!(ran.stdout.starts_with("SyntaxError"), "{}", ran.stdout);

    // Not the run's token: a program's call, and here there are none.
    let ran = run(&mcp, "nope", &read).await;
    assert!(ran.stdout.contains("(unavailable)"), "{}", ran.stdout);

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
            ran.stdout.starts_with("Error: there is no browser here"),
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
        work: Some(work.clone()),
        call_time: max_core::limits::CALL_TIME,
        ..Context::check(stored(pool, &store), place)
    });
    let (mcp, scope) = served(&sessions, conversation).await;
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
        r#"[{"width":3,"height":1},{"width":2,"height":1},"max.image: /work/notes.txt isn't a PNG, JPEG, GIF or WebP that decodes (not_a_picture)","TypeError"]"#,
        "{}",
        ran.stderr
    );
    let shown = grant.shown();
    assert_eq!(shown.len(), 2);
    assert_eq!(
        std::fs::read(store.path(sha256(&shown[0]))).unwrap(),
        png(3)
    );
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
            .starts_with("ToolError: max.image: one run_code shows at most 4 pictures"),
        "{}",
        ran.stdout
    );
    assert_eq!(grant.shown().len(), 4);

    scope.close(Duration::from_secs(5)).await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// A video of ffmpeg's test pattern at `path`, `seconds` long: a phone's
/// size and rate, with a tone, in Matroska; or, `small`, a 16-pixel one at
/// a frame a second, silent, in MP4.
async fn clip(path: &Path, seconds: u32, small: bool) {
    let source = if small {
        format!("color=black:s=16x16:r=1:d={seconds}")
    } else {
        format!("testsrc2=s=1280x720:r=30:d={seconds}")
    };
    let mut command = Command::new("ffmpeg");
    command.args(["-v", "error", "-f", "lavfi", "-i", &source]);
    if !small {
        let tone = format!("sine=f=500:d={seconds}");
        command.args(["-f", "lavfi", "-i", &tone, "-c:a", "aac"]);
    }
    let made = command
        .args(["-c:v", "libx264", "-preset", "ultrafast"])
        .arg(path)
        .status()
        .await
        .expect("ffmpeg runs");
    assert!(made.success());
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn programs_show_the_model_videos(pool: PgPool) {
    let dir = std::env::temp_dir().join(format!("max-videos-{:016x}", rand::random::<u64>()));
    let work = dir.join("work");
    std::fs::create_dir_all(&work).unwrap();
    clip(&work.join("clip.mkv"), 3, false).await;
    clip(&work.join("long.mp4"), 601, true).await;
    clip(&work.join("half.mp4"), 300, true).await;
    std::fs::write(work.join("notes.bin"), "不是视频").unwrap();
    let store = Arc::new(Store::open(&dir.join("store")).await.unwrap());
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    drop(conn);
    let conversation = place.conversation;
    let sessions = Sessions::default();
    let context = |video| Context {
        video,
        work: Some(work.clone()),
        call_time: max_core::limits::CALL_TIME,
        ..Context::check(stored(pool.clone(), &store), Arc::clone(&place))
    };
    let grant = sessions.open(context(true));
    let (mcp, scope) = served(&sessions, conversation).await;
    let input = |token: &str, code: &str| json!({ "code": code, "args": {}, "token": token, "mcp": mcp, "work": work });

    // The whole clip, a second of it, the clip again; a file that isn't
    // one, ten minutes and a second, a time that isn't one, no path.
    let code = "const a = await max.video('/work/clip.mkv'); \
         const b = await max.video('clip.mkv', {start: 1, end: '0:02'}); \
         await max.video('clip.mkv'); \
         const failed = []; \
         for (const [path, options] of [['notes.bin'], ['long.mp4'], ['clip.mkv', {start: 'soon'}]]) { \
           try { await max.video(path, options) } catch (e) { failed.push(e.message) } } \
         let wrong; try { await max.video(42) } catch (e) { wrong = e.name } \
         return [a, b, failed, wrong]";
    let ran = run_with(input(grant.token(), code)).await;
    let ran: Value = serde_json::from_str(&ran.stdout)
        .unwrap_or_else(|_| panic!("{}{}", ran.stdout, ran.stderr));
    assert_eq!(
        ran,
        json!([
            { "seconds": 3 },
            { "seconds": 1 },
            [
                "max.video: can't read notes.bin: Invalid data found when processing input (not_a_video)",
                "max.video: this is 601 seconds, and at most 10 minutes are shown at a time: cut a piece with start and end (too_long)",
                "max.video: start and end take seconds, or a time such as \"1:30\" or \"1:02:03.5\" (bad_time)",
            ],
            "TypeError",
        ])
    );
    let shown = grant.shown();
    let lengths: Vec<_> = shown
        .iter()
        .map(|part| match part {
            Part::Video { seconds, .. } => Some(*seconds),
            _ => None,
        })
        .collect();
    assert_eq!(lengths, [Some(3), Some(1)]);
    // The model's copy: an MP4, smaller than what it was made from.
    let copy = std::fs::read(store.path(sha256(&shown[0]))).unwrap();
    assert_eq!(&copy[4..8], b"ftyp");
    assert!(
        u64::try_from(copy.len()).unwrap()
            < std::fs::metadata(work.join("clip.mkv")).unwrap().len()
    );
    // The copies' files are gone once the host has them.
    let left: Vec<_> = std::fs::read_dir(work.join(".max/shown"))
        .unwrap()
        .collect();
    assert!(left.is_empty(), "{left:?}");
    assert!(grant.calls().is_empty());

    // From a command, as part of the same run: five minutes more fit in
    // its ten, and the next five don't.
    let token = Some(grant.token());
    let watched = maxx_in(
        Some(&work),
        &mcp,
        token,
        &["video", "half.mp4", "--end", "300"],
        "",
    )
    .await;
    assert_eq!(
        watched.stdout, "{\n  \"seconds\": 300\n}\n",
        "{}",
        watched.stderr
    );
    let again = maxx_in(
        Some(&work),
        &mcp,
        token,
        &["video", "clip.mkv", "--start", "1:00"],
        "",
    )
    .await;
    assert_eq!(again.status, 1);
    assert!(
        again
            .stderr
            .contains("start is past the end: clip.mkv is only 3 seconds long"),
        "{}",
        again.stderr
    );
    let over = "await max.video('half.mp4', {start: 1})";
    let ran = run_with(input(grant.token(), over)).await;
    assert!(
        ran.stdout.starts_with(
            "ToolError: max.video: one run_code shows at most 10 minutes of video, and this is 299 seconds after 304 shown already"
        ),
        "{}{}",
        ran.stdout,
        ran.stderr
    );
    assert_eq!(grant.shown().len(), 3);

    // A model that doesn't watch videos.
    let blind = sessions.open(context(false));
    let ran = run_with(input(blind.token(), "await max.video('clip.mkv')")).await;
    assert!(
        ran.stdout
            .starts_with("ToolError: max.video: this model doesn't watch videos (unavailable)"),
        "{}",
        ran.stdout
    );

    scope.close(Duration::from_secs(5)).await;
    let _ = std::fs::remove_dir_all(&dir);
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn programs_fetch_the_chats_files(pool: PgPool) {
    let dir = std::env::temp_dir().join(format!("max-fetched-{:016x}", rand::random::<u64>()));
    let work = dir.join("work");
    std::fs::create_dir_all(&work).unwrap();
    let store = Arc::new(Store::open(&dir.join("store")).await.unwrap());
    let mut conn = pool.acquire().await.unwrap();
    let place = Arc::new(group(&mut conn).await);
    let other = group_named(&mut conn, "group:GROUP2").await;
    // 小明 sent a file here, and one in another group; both downloaded.
    let file = || {
        InNode::Node(Node::Media {
            media: Some(MediaRef::Remote("https://q.example/f".into())),
            meta: MediaMeta {
                kind: MediaKind::File,
                mime: Some("file".into()),
                size: Some(8),
                name: Some("周报.pdf".into()),
                description: None,
            },
        })
    };
    let mut ids = Vec::new();
    for (n, at) in [(0, &*place), (1, &other)] {
        let inbound = from_xiaoming(n, vec![file()]);
        let committed = ingest::inbound(&mut conn, at, inbound, Utc::now(), offset());
        let row = committed.await.unwrap().message.id;
        let blob = Blob {
            sha256: store.put(format!("%PDF-{n}").into_bytes()).await.unwrap(),
            mime: Some("application/pdf".into()),
            size: 6,
            width: None,
            height: None,
            model_sha256: None,
        };
        media::record(&mut conn, row, 0, &blob, Utc::now())
            .await
            .unwrap();
        ids.push(row.0);
    }
    drop(conn);
    let conversation = place.conversation;
    let sessions = Sessions::default();
    let grant = sessions.open(Context {
        work: Some(work.clone()),
        call_time: max_core::limits::CALL_TIME,
        ..Context::check(stored(pool, &store), place)
    });
    let (mcp, scope) = served(&sessions, conversation).await;

    // As the record shows it; the other group's; none such; not a handle.
    let code = "const fetched = await max.file(`[file#${args.ids[0]}.0: 周报.pdf]`); \
         const failed = []; \
         for (const h of [`file#${args.ids[1]}.0`, 'file#1.5', 'report.pdf']) \
           try { await max.file(h) } catch (e) { failed.push(e.message.match(/ \\((\\w+)\\)$/)[1]) } \
         return { fetched, failed }";
    let input = json!({ "code": code, "args": { "ids": ids }, "token": grant.token(), "mcp": mcp, "work": work });
    let ran = run_with(input).await;
    let value: Value = serde_json::from_str(&ran.stdout).expect(&ran.stderr);
    let name = format!("{}.0-周报.pdf", ids[0]);
    assert_eq!(
        value,
        json!({
            "fetched": { "path": format!("/work/chat/{name}"), "name": "周报.pdf", "size": 6 },
            "failed": ["not_found", "not_found", "bad_handle"],
        })
    );
    assert_eq!(
        std::fs::read(work.join("chat").join(&name)).unwrap(),
        b"%PDF-0"
    );
    // Not counted among Max's tools: the file is the program's.
    assert!(grant.calls().is_empty());

    scope.close(Duration::from_secs(5)).await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// `maxx` with `words`, as the run whose `token` it has, if any; `input`
/// on its stdin.
async fn maxx(mcp: &str, token: Option<&str>, words: &[&str], input: &str) -> Ran {
    maxx_in(None, mcp, token, words, input).await
}

/// The same, with `work` for /work, which maxx video reads and writes
/// itself.
async fn maxx_in(
    work: Option<&Path>,
    mcp: &str,
    token: Option<&str>,
    words: &[&str],
    input: &str,
) -> Ran {
    let mut command = Command::new("node");
    if let Some(work) = work {
        command.env("MAXX_WORK", work);
    }
    command
        .arg(MAXX)
        .args(words)
        .env("MAXX_MCP", mcp)
        .env_remove("MAXX_TOKEN")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    if let Some(token) = token {
        command.env("MAXX_TOKEN", token);
    }
    let mut node = command.spawn().expect("node runs maxx");
    let mut stdin = node.stdin.take().unwrap();
    stdin.write_all(input.as_bytes()).await.unwrap();
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
async fn commands_call_max_tools_with_maxx(pool: PgPool) {
    let dir = std::env::temp_dir().join(format!("max-maxx-{:016x}", rand::random::<u64>()));
    let work = dir.join("work");
    std::fs::create_dir_all(&work).unwrap();
    std::fs::write(work.join("shot.png"), png(3)).unwrap();
    let store = Arc::new(Store::open(&dir.join("store")).await.unwrap());
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
    let conversation = place.conversation;
    // A program's calls, which the group's actor would run, are answered
    // with what was called.
    let (programs, mut called) = tokio::sync::mpsc::unbounded_channel();
    let sessions = Sessions::with_programs(programs);
    let grant = sessions.open(Context {
        work: Some(work.clone()),
        call_time: max_core::limits::CALL_TIME,
        ..Context::check(stored(pool, &store), place)
    });
    let (mcp, mut scope) = served(&sessions, conversation).await;
    scope.spawn(move |_| async move {
        while let Some(Signal::Call {
            conversation: to,
            tool,
            args,
            reply,
        }) = called.recv().await
        {
            assert_eq!(to, conversation);
            let _ = reply.send(Ok(json!({ "tool": tool, "args": args })));
        }
    });
    let token = Some(grant.token());
    let id = hello.message.id.0;
    let read = format!("[12:01 小明 #{id}]: 你好");

    // The tools, and one tool's arguments.
    let listed = maxx(&mcp, token, &[], "").await;
    assert_eq!(listed.status, 0, "{}", listed.stderr);
    assert!(listed.stdout.contains("\n  history  "), "{}", listed.stdout);
    assert!(listed.stdout.contains("\n  show  "), "{}", listed.stdout);
    let help = maxx(&mcp, token, &["history", "--help"], "").await;
    assert!(
        help.stdout
            .contains("\n  --around (integer): read around this message: 123 for #123\n"),
        "{}",
        help.stdout
    );

    // By flags, as JSON, from stdin: the result as JSON.
    let around = id.to_string();
    let by_flags = ["history", "--around", &around, "--before=0", "--after", "0"];
    let one = json!({ "around": id, "before": 0, "after": 0 }).to_string();
    for (words, input) in [
        (&by_flags[..], ""),
        (&["history", &one][..], ""),
        (&["history", "-"][..], one.as_str()),
    ] {
        let ran = maxx(&mcp, token, words, input).await;
        assert_eq!(ran.status, 0, "{words:?}: {}", ran.stderr);
        let value: Value = serde_json::from_str(&ran.stdout).unwrap();
        assert_eq!(value["text"], read, "{words:?}");
    }

    // A tool's failure, a word by position, and a wrong command line.
    let after = (id + 1).to_string();
    let missing = maxx(&mcp, token, &["history", "--around", &after], "").await;
    assert_eq!(missing.status, 1);
    assert!(
        missing.stderr.starts_with("history: there is no message #")
            && missing.stderr.ends_with(" (not_found)\n"),
        "{}",
        missing.stderr
    );
    let search = maxx(&mcp, token, &["web-search", "示波器"], "").await;
    assert_eq!(search.status, 1);
    assert!(
        search.stderr.ends_with(" (unavailable)\n"),
        "{}",
        search.stderr
    );
    for (words, said) in [
        (
            &["history", "--nope", "1"][..],
            "there is no argument --nope",
        ),
        (&["history", "--before", "x"][..], "--before takes a number"),
        (&["nosuch"][..], "there is no tool named nosuch"),
        (&["history", "{"][..], "the argument isn't JSON"),
    ] {
        let ran = maxx(&mcp, token, words, "").await;
        assert_eq!(ran.status, 2, "{words:?}");
        assert!(ran.stderr.contains(said), "{words:?}: {}", ran.stderr);
    }
    assert_eq!(grant.calls()["history"], (3, 1));
    assert_eq!(grant.calls()["web_search"], (0, 1));

    // A picture for the model, from a command.
    let shown = maxx(&mcp, token, &["show", "shot.png"], "").await;
    assert_eq!(
        shown.stdout, "{\n  \"width\": 3,\n  \"height\": 1\n}\n",
        "{}",
        shown.stderr
    );
    assert_eq!(grant.shown().len(), 1);

    // What only programs call runs as a program's, from a run too.
    let woken = maxx(&mcp, token, &["wake", "到点了"], "").await;
    let woken: Value = serde_json::from_str(&woken.stdout).unwrap();
    assert_eq!(
        woken,
        json!({ "tool": "wake", "args": { "text": "到点了" } })
    );

    // Outside a run, as a program Max keeps in the VM: all of Max's
    // tools, but nothing to show a model, and each call the group's.
    let listed = maxx(&mcp, None, &[], "").await;
    assert_eq!(listed.status, 0, "{}", listed.stderr);
    for (name, listed_too) in [
        ("history", true),
        ("say", true),
        ("file", true),
        ("events", true),
        ("mute_member", true),
        ("agent", true),
        ("show", false),
        ("video", false),
    ] {
        let line = format!("\n  {name}  ");
        assert_eq!(
            listed.stdout.contains(&line),
            listed_too,
            "{name}: {}",
            listed.stdout
        );
    }
    let said = maxx(&mcp, None, &["say", "[reply#1] 好"], "").await;
    let said: Value = serde_json::from_str(&said.stdout).unwrap();
    assert_eq!(
        said,
        json!({ "tool": "say", "args": { "text": "[reply#1] 好" } })
    );
    // What a turn may do, a program may.
    let muted = maxx(&mcp, None, &["mute-member", "1"], "").await;
    assert_eq!(muted.status, 0, "{}", muted.stderr);
    let muted: Value = serde_json::from_str(&muted.stdout).unwrap();
    assert_eq!(muted["tool"], "mute_member", "{muted}");
    // A command that outlives its run, as one moved to the background
    // does, calls as a program from then on.
    let token = grant.token().to_owned();
    drop(grant);
    let ended = maxx(&mcp, Some(&token), &["history"], "").await;
    assert_eq!(ended.status, 0, "{}", ended.stderr);
    let ended: Value = serde_json::from_str(&ended.stdout).unwrap();
    assert_eq!(ended, json!({ "tool": "history", "args": {} }));

    scope.close(Duration::from_secs(5)).await;
    let _ = std::fs::remove_dir_all(&dir);
}
