//! The guest's runner and maxx, run here with Node against the MCP
//! service on TCP: they need nothing of the VM but `/work`, which tests
//! point at a directory of their own, and a call's directory, which is
//! one of the test's.

use std::io::Cursor;
use std::path::{Path, PathBuf};
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

use super::{Context, Services, serve, testing};
use crate::conversation::Signal;
use crate::conversation::ingest;
use crate::conversation::testing::{from_xiaoming, group, group_named, offset, text};
use crate::inbound::InNode;
use crate::media::store::Store;
use crate::scope::Scope;
use crate::tools;
use crate::tools::show::{Left, Shown, shown};

const RUNNER: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../nix/runner.js");
const MAXX: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../nix/maxx.js");
const TOOLS_JS: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../nix/tools.js");

struct Ran {
    status: i32,
    stdout: String,
    stderr: String,
}

/// The MCP service for the VM of `context`'s conversation on a port of
/// its own, in `scope`, its calls run in `context` as the conversation's
/// actor would run them: its URL.
async fn served(scope: &mut Scope, context: Context) -> String {
    let conversation = context.place.conversation;
    let calls = testing::answering(scope, context);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mcp = format!("http://{}/mcp", listener.local_addr().unwrap());
    scope.spawn(move |stop| serve(listener, conversation, calls, axum::Router::new(), stop));
    mcp
}

/// Only the database, and `store`.
fn stored(pool: PgPool, store: &Arc<Store>) -> Services {
    Services {
        store: Some(Arc::clone(store)),
        ..Services::bare(pool)
    }
}

/// The content store's name for what a call showed.
fn sha256(part: &Part) -> &str {
    match part {
        Part::Media {
            media: MediaRef::Blob(sha256),
        }
        | Part::Video {
            media: MediaRef::Blob(sha256),
            ..
        } => sha256,
        _ => panic!("not what a call shows: {part:?}"),
    }
}

/// A call's directory, as `maxx units run` gives a call's unit one, in `dir`:
/// what MAX_CALL names.
fn call_dir(dir: &Path) -> PathBuf {
    let call = dir.join("max-job-1-1");
    std::fs::create_dir_all(&call).unwrap();
    call
}

/// What the call of `call` left to show so far, as the guest reads it for
/// the call's line.
fn left(call: &Path) -> Vec<Left> {
    let list = std::fs::read_to_string(call.join("shown")).unwrap_or_default();
    list.lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

/// What the host makes of what the call of `call` left in `work`, for a
/// model that watches videos if `video`.
async fn seen(store: &Arc<Store>, work: &Path, call: &Path, video: bool) -> Shown {
    let context = tools::Context {
        conversation: ConversationId(1),
        store: Some(Arc::clone(store)),
        video,
    };
    shown(&context, work, &left(call)).await
}

async fn run(mcp: &str, code: &str) -> Ran {
    run_with(
        json!({ "code": code, "args": { "n": 2 }, "mcp": mcp }),
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
    let mcp = served(&mut scope, Context::check(Services::bare(pool), place)).await;
    let id = hello.message.id.0;

    let ran = run(&mcp, "return args.n + 1").await;
    assert_eq!(
        (ran.status, ran.stdout.as_str()),
        (0, "3"),
        "{}",
        ran.stderr
    );

    let ran = run(
        &mcp,
        "console.log('hi', {a: 1}); process.stdout.write('x\\n'); return {ok: true}",
    )
    .await;
    assert_eq!(ran.stdout, r#"{"ok":true}"#);
    assert_eq!(ran.stderr, "hi { a: 1 }\nx\n");

    let read = format!(
        "const r = await tools.history({{around: {id}, before: 0, after: 0}}); return r.text"
    );
    let ran = run(&mcp, &read).await;
    assert_eq!(
        ran.stdout,
        format!("[12:01 小明 #{id}]: 你好"),
        "{}",
        ran.stderr
    );

    let missing = format!("await tools.history({{around: {}}})", id + 1);
    let ran = run(&mcp, &missing).await;
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
    let ran = run(&mcp, &raw).await;
    assert_eq!(ran.stdout, r#"[true,false,"not_found"]"#, "{}", ran.stderr);

    let ran = run(
        &mcp,
        &format!("return tools.history({{around: {id}}}).text"),
    )
    .await;
    assert_eq!(ran.status, 1);
    assert!(ran.stdout.contains("await it first"), "{}", ran.stdout);

    let ran = run(&mcp, "return (").await;
    assert_eq!(ran.status, 1);
    assert!(ran.stdout.starts_with("SyntaxError"), "{}", ran.stdout);

    // Every tool is a program's, those the prompt doesn't declare too;
    // and what was the runner's own request until 2026-11-12 is gone.
    let ran = run(
        &mcp,
        "return [typeof tools.say, typeof tools.file, typeof max.file]",
    )
    .await;
    assert_eq!(ran.stdout, r#"["function","function","undefined"]"#);

    scope.close(Duration::from_secs(5)).await;
}

/// The browser's SDK, as far as it goes without a browser: here the runner
/// has no playwright-core, and snapshot gets a page that only answers.
#[tokio::test]
async fn the_browser_sdk_without_a_browser() {
    let nowhere = "http://127.0.0.1:9/mcp";
    for open in ["max.browser()", "max.page()"] {
        let ran = run(nowhere, &format!("await {open}")).await;
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
    let ran = run(nowhere, &format!("{page} return max.snapshot(page)")).await;
    assert_eq!(
        ran.stdout, "例子\nhttps://example.com/\n- button \"搜索\" [ref=e2] {\"mode\":\"ai\"}",
        "{}",
        ran.stderr
    );
    let narrowed = format!("{page} return max.snapshot(page, {{ selector: 'form', depth: 2 }})");
    let ran = run(nowhere, &narrowed).await;
    assert_eq!(
        ran.stdout, "例子\nhttps://example.com/\n- form [ref=e1] {\"mode\":\"ai\",\"depth\":2}",
        "{}",
        ran.stderr
    );
    for wrong in ["max.snapshot('page')", "max.snapshot(page, { depth: 0 })"] {
        let ran = run(nowhere, &format!("{page} return {wrong}")).await;
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

#[tokio::test]
async fn programs_show_the_model_pictures() {
    let dir = std::env::temp_dir().join(format!("max-shown-{:016x}", rand::random::<u64>()));
    let work = dir.join("work");
    std::fs::create_dir_all(&work).unwrap();
    std::fs::write(work.join("shot.png"), png(3)).unwrap();
    std::fs::write(work.join("notes.txt"), "不是图").unwrap();
    let store = Arc::new(Store::open(&dir.join("store")).await.unwrap());
    let call = call_dir(&dir);
    // Nothing is asked of the host.
    let nowhere = "http://127.0.0.1:9/mcp";
    let pngs = |widths: &[u32]| -> Vec<String> {
        widths
            .iter()
            .map(|&width| STANDARD.encode(png(width)))
            .collect()
    };
    let input = |code: &str, args: Value| json!({ "code": code, "args": args, "mcp": nowhere, "work": work });

    // A file, the same file again, bytes, and a file that isn't a
    // picture, which the host finds out; no such file, and no path.
    let code = "const a = await tools.show({path: '/work/shot.png'}); await tools.show({path: 'shot.png'}); \
         const b = await tools.show(Buffer.from(args.pngs[0], 'base64')); \
         await tools.show({path: '/work/notes.txt'}); \
         let failed; try { await tools.show({path: 'nope.png'}) } catch (e) { failed = e.message } \
         let wrong; try { await tools.show(42) } catch (e) { wrong = e.name } \
         let none; try { await tools.show({}) } catch (e) { none = e.code } \
         return [a, b.path.startsWith('/work/.max/shown/max-job-1-1/'), failed, wrong, none]";
    let ran = run_with(input(code, json!({ "pngs": pngs(&[2]) })), Some(&call)).await;
    assert_eq!(
        ran.stdout,
        r#"[{"path":"/work/shot.png"},true,"show: nope.png doesn't exist (not_found)","TypeError","bad_arguments"]"#,
        "{}",
        ran.stderr
    );
    let seen_now = seen(&store, &work, &call, true).await;
    assert_eq!(seen_now.parts.len(), 2, "{seen_now:?}");
    assert_eq!(
        std::fs::read(store.path(sha256(&seen_now.parts[0]))).unwrap(),
        png(3)
    );
    assert_eq!(
        seen_now.refused,
        ["/work/notes.txt wasn't shown: it isn't a PNG, JPEG, GIF or WebP that decodes"]
    );
    // The bytes' file is the call's own, for the guest to clear away.
    let kept: Vec<_> = std::fs::read_dir(work.join(".max/shown/max-job-1-1"))
        .unwrap()
        .collect();
    assert_eq!(kept.len(), 1, "{kept:?}");

    // More than a call shows.
    let code = "for (const png of args.pngs) await tools.show(Buffer.from(png, 'base64'))";
    let ran = run_with(
        input(code, json!({ "pngs": pngs(&[4, 5, 6]) })),
        Some(&call),
    )
    .await;
    assert_eq!(ran.status, 0, "{}{}", ran.stdout, ran.stderr);
    let seen_now = seen(&store, &work, &call, true).await;
    assert_eq!(seen_now.parts.len(), 4, "{seen_now:?}");
    assert_eq!(seen_now.refused.len(), 2, "{seen_now:?}");
    assert!(
        seen_now.refused[1].ends_with(" wasn't shown: one call shows at most 4 pictures"),
        "{seen_now:?}"
    );

    // Outside a call, nobody is there to see it.
    let ran = run_with(
        input("await tools.show({path: 'shot.png'})", json!({})),
        None,
    )
    .await;
    assert_eq!(ran.status, 1);
    assert!(
        ran.stdout
            .starts_with("ToolError: show: nobody is there to see it"),
        "{}",
        ran.stdout
    );

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

#[tokio::test]
async fn programs_show_the_model_videos() {
    let dir = std::env::temp_dir().join(format!("max-videos-{:016x}", rand::random::<u64>()));
    let work = dir.join("work");
    std::fs::create_dir_all(&work).unwrap();
    clip(&work.join("clip.mkv"), 3, false).await;
    clip(&work.join("long.mp4"), 601, true).await;
    clip(&work.join("half.mp4"), 300, true).await;
    std::fs::write(work.join("notes.bin"), "不是视频").unwrap();
    let store = Arc::new(Store::open(&dir.join("store")).await.unwrap());
    let call = call_dir(&dir);
    let nowhere = "http://127.0.0.1:9/mcp";
    let input = |code: &str| json!({ "code": code, "args": {}, "mcp": nowhere, "work": work });

    // The whole clip, a second of it, the clip again; a file that isn't
    // one, ten minutes and a second, a time that isn't one, no path.
    let code = "const a = await tools.video({path: '/work/clip.mkv'}); \
         const b = await tools.video({path: 'clip.mkv', start: 1, end: '0:02'}); \
         await tools.video({path: 'clip.mkv'}); \
         const failed = []; \
         for (const [path, options] of [['notes.bin'], ['long.mp4'], ['clip.mkv', {start: 'soon'}]]) { \
           try { await tools.video({path, ...options}) } catch (e) { failed.push(e.message) } } \
         let wrong; try { await tools.video(42) } catch (e) { wrong = e.name } \
         return [a, b, failed, wrong]";
    let ran = run_with(input(code), Some(&call)).await;
    let ran: Value = serde_json::from_str(&ran.stdout)
        .unwrap_or_else(|_| panic!("{}{}", ran.stdout, ran.stderr));
    assert_eq!(
        ran,
        json!([
            { "seconds": 3 },
            { "seconds": 1 },
            [
                "video: can't read notes.bin: Invalid data found when processing input (not_a_video)",
                "video: this is 601 seconds, and at most 10 minutes are shown at a time: cut a piece with start and end (too_long)",
                "video: start and end take seconds, or a time such as \"1:30\" or \"1:02:03.5\" (bad_time)",
            ],
            "TypeError",
        ])
    );
    let seen_now = seen(&store, &work, &call, true).await;
    let lengths = |shown: &Shown| -> Vec<Option<u32>> {
        let parts = shown.parts.iter();
        parts
            .map(|part| match part {
                Part::Video { seconds, .. } => Some(*seconds),
                _ => None,
            })
            .collect()
    };
    // The host reads each copy's length; the same piece twice is one.
    assert_eq!(lengths(&seen_now), [Some(3), Some(1)], "{seen_now:?}");
    assert!(seen_now.refused.is_empty(), "{seen_now:?}");
    // The model's copy: an MP4, smaller than what it was made from.
    let copy = std::fs::read(store.path(sha256(&seen_now.parts[0]))).unwrap();
    assert_eq!(&copy[4..8], b"ftyp");
    assert!(
        u64::try_from(copy.len()).unwrap()
            < std::fs::metadata(work.join("clip.mkv")).unwrap().len()
    );

    // From a command, as part of the same call: five minutes more fit in
    // its ten, and the next five don't, which the host says.
    let watched = maxx_in(
        Some(&work),
        nowhere,
        Some(&call),
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
        nowhere,
        Some(&call),
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
    let over = "return await tools.video({path: 'half.mp4', start: 1})";
    let ran = run_with(input(over), Some(&call)).await;
    assert_eq!(ran.stdout, r#"{"seconds":299}"#, "{}", ran.stderr);
    let seen_now = seen(&store, &work, &call, true).await;
    assert_eq!(lengths(&seen_now), [Some(3), Some(1), Some(300)]);
    assert_eq!(seen_now.refused.len(), 1, "{seen_now:?}");
    assert!(
        seen_now.refused[0].ends_with(
            " wasn't shown: one call shows at most 10 minutes of video, and this is 299 seconds after 304 shown already: cut a piece with start and end"
        ),
        "{seen_now:?}"
    );

    // A model that doesn't watch videos.
    let blind = seen(&store, &work, &call, false).await;
    assert!(blind.parts.is_empty(), "{blind:?}");
    assert!(
        blind.refused[0].ends_with(" wasn't shown: this model doesn't watch videos"),
        "{blind:?}"
    );
    // Outside a call, nobody is there to watch.
    let nobody = maxx_in(Some(&work), nowhere, None, &["video", "clip.mkv"], "").await;
    assert_eq!(nobody.status, 1);
    assert!(
        nobody
            .stderr
            .starts_with("video: nobody is there to see it"),
        "{}",
        nobody.stderr
    );

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
    let mut scope = Scope::new();
    let context = Context {
        work: Some(work.clone()),
        ..Context::check(stored(pool, &store), place)
    };
    let mcp = served(&mut scope, context).await;

    // As the record shows it; the other group's; none such; not a handle.
    let code = "const fetched = await tools.file({ handle: `[file#${args.ids[0]}.0: 周报.pdf]` }); \
         const failed = []; \
         for (const handle of [`file#${args.ids[1]}.0`, 'file#1.5', 'report.pdf']) \
           try { await tools.file({ handle }) } catch (e) { failed.push(e.message.match(/ \\((\\w+)\\)$/)[1]) } \
         return { fetched, failed }";
    let input = json!({ "code": code, "args": { "ids": ids }, "mcp": mcp, "work": work });
    let ran = run_with(input, None).await;
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
    // From a command, by position.
    let handle = format!("file#{}.0", ids[0]);
    let fetched = maxx(&mcp, &["file", &handle], "").await;
    assert_eq!(fetched.status, 0, "{}", fetched.stderr);
    let fetched: Value = serde_json::from_str(&fetched.stdout).unwrap();
    assert_eq!(fetched["path"], format!("/work/chat/{name}"));

    scope.close(Duration::from_secs(5)).await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// `maxx` with `words`; `input` on its stdin.
async fn maxx(mcp: &str, words: &[&str], input: &str) -> Ran {
    maxx_in(None, mcp, None, words, input).await
}

/// The same, with `work` for /work, which maxx show and maxx video read
/// and write themselves, as part of the call whose directory is `call`.
async fn maxx_in(
    work: Option<&Path>,
    mcp: &str,
    call: Option<&Path>,
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
        .env_remove("MAX_CALL")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    if let Some(call) = call {
        command.env("MAX_CALL", call);
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
    let mut scope = Scope::new();
    let mcp = served(&mut scope, Context::check(Services::bare(pool), place)).await;
    let id = hello.message.id.0;
    let read = format!("[12:01 小明 #{id}]: 你好");

    // The tools, all of them, with maxx's own; and one tool's arguments.
    let listed = maxx(&mcp, &[], "").await;
    assert_eq!(listed.status, 0, "{}", listed.stderr);
    for name in [
        "history",
        "file",
        "say",
        "wake",
        "mute_member",
        "ask",
        "show",
        "video",
        "events",
        "agent start",
        "units list",
        "units stop-all",
    ] {
        let line = format!("\n  {name}  ");
        assert!(listed.stdout.contains(&line), "{name}: {}", listed.stdout);
    }
    let help = maxx(&mcp, &["history", "--help"], "").await;
    assert!(
        help.stdout
            .contains("\n  --around (integer): read around this message: 123 for #123\n"),
        "{}",
        help.stdout
    );
    // One of the guest's own goes by its words, and by nothing else.
    let help = maxx(&mcp, &["agent", "start", "--help"], "").await;
    assert!(
        help.stdout.starts_with("agent start: ")
            && help.stdout.contains("\n  --task (string, required): "),
        "{}",
        help.stdout
    );
    for joined in ["agent-start", "agent_start"] {
        let ran = maxx(&mcp, &[joined, "--task", "x"], "").await;
        assert_eq!(ran.status, 2, "{}", ran.stdout);
        assert!(
            ran.stderr
                .starts_with(&format!("maxx: there is no tool named {joined}; ")),
            "{}",
            ran.stderr
        );
    }

    // By flags, as JSON, from stdin: the result as JSON.
    let around = id.to_string();
    let by_flags = ["history", "--around", &around, "--before=0", "--after", "0"];
    let one = json!({ "around": id, "before": 0, "after": 0 }).to_string();
    for (words, input) in [
        (&by_flags[..], ""),
        (&["history", &one][..], ""),
        (&["history", "-"][..], one.as_str()),
    ] {
        let ran = maxx(&mcp, words, input).await;
        assert_eq!(ran.status, 0, "{words:?}: {}", ran.stderr);
        let value: Value = serde_json::from_str(&ran.stdout).unwrap();
        assert_eq!(value["text"], read, "{words:?}");
    }

    // A tool's failure, a word by position, and a wrong command line.
    let after = (id + 1).to_string();
    let missing = maxx(&mcp, &["history", "--around", &after], "").await;
    assert_eq!(missing.status, 1);
    assert!(
        missing.stderr.starts_with("history: there is no message #")
            && missing.stderr.ends_with(" (not_found)\n"),
        "{}",
        missing.stderr
    );
    let search = maxx(&mcp, &["web-search", "示波器"], "").await;
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
        let ran = maxx(&mcp, words, "").await;
        assert_eq!(ran.status, 2, "{words:?}");
        assert!(ran.stderr.contains(said), "{words:?}: {}", ran.stderr);
    }

    // A picture for the model, from a command that is part of a call:
    // left in the call's directory, and nothing asked of the host.
    let call = call_dir(&dir);
    let shown = maxx_in(Some(&work), &mcp, Some(&call), &["show", "shot.png"], "").await;
    assert_eq!(
        shown.stdout, "{\n  \"path\": \"/work/shot.png\"\n}\n",
        "{}",
        shown.stderr
    );
    assert_eq!(left(&call).len(), 1);
    let nobody = maxx_in(Some(&work), &mcp, None, &["show", "shot.png"], "").await;
    assert_eq!(nobody.status, 1);
    assert!(
        nobody.stderr.starts_with("show: nobody is there to see it"),
        "{}",
        nobody.stderr
    );

    // What a call asks reaches the conversation's actor as it was
    // written: here answered with what was called.
    let (calls, mut called) = tokio::sync::mpsc::unbounded_channel();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let echo = format!("http://{}/mcp", listener.local_addr().unwrap());
    scope.spawn(move |stop| serve(listener, conversation, calls, axum::Router::new(), stop));
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
    for (words, tool, args) in [
        (&["wake", "到点了"][..], "wake", json!({ "text": "到点了" })),
        (
            &["say", "[reply#1] 好"][..],
            "say",
            json!({ "text": "[reply#1] 好" }),
        ),
        (&["history"][..], "history", json!({})),
    ] {
        let ran = maxx(&echo, words, "").await;
        assert_eq!(ran.status, 0, "{words:?}: {}", ran.stderr);
        let value: Value = serde_json::from_str(&ran.stdout).unwrap();
        assert_eq!(value, json!({ "tool": tool, "args": args }), "{words:?}");
    }
    let muted = maxx(&echo, &["mute-member", "1"], "").await;
    assert_eq!(muted.status, 0, "{}", muted.stderr);
    let muted: Value = serde_json::from_str(&muted.stdout).unwrap();
    assert_eq!(muted["tool"], "mute_member", "{muted}");

    scope.close(Duration::from_secs(5)).await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// Node with `args`, `input` on its stdin, and a stand-in for the guest's
/// `maxx`.
async fn node(args: &[&str], stub: &Path, input: &str) -> Ran {
    let mut command = Command::new("node");
    command
        .args(args)
        .env("MAXX_COMMAND", stub)
        .env("MAXX_MCP", "http://127.0.0.1:1/mcp")
        .env_remove("MAX_CALL")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut node = command.spawn().expect("node runs");
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

/// One of the guest's own tools is asked of `maxx` with its words and its
/// arguments as JSON, whoever calls: the command line, once it has read
/// the options; a run_code program; and a program of Max's own. A script
/// stands in for bin/maxx, which runs the guest's scripts.
#[tokio::test]
async fn the_guests_own_tools_are_asked_of_maxx_as_json() {
    use std::os::unix::fs::PermissionsExt;

    let dir = std::env::temp_dir().join(format!("max-local-{:016x}", rand::random::<u64>()));
    std::fs::create_dir_all(&dir).unwrap();
    let stub = dir.join("maxx");
    // What it was asked, a line an argument; a login shell's noise before
    // its answer; and a refusal.
    let script = "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"$(dirname \"$0\")/asked\"\n\
                  case \"$3\" in *refuse*) echo 'no room' >&2; exit 1 ;; esac\n\
                  echo noise\necho '{\"name\":\"max-agent-1\",\"said\":\"started\"}'\n";
    std::fs::write(&stub, script).unwrap();
    std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).unwrap();
    let asked = || {
        let asked = std::fs::read_to_string(dir.join("asked")).unwrap_or_default();
        let _ = std::fs::remove_file(dir.join("asked"));
        asked
    };
    let started = json!({ "name": "max-agent-1", "said": "started" });

    // The command line: options, and a text from stdin without the
    // newlines a heredoc ends it with.
    let words = ["agent", "start", "--title", "试试", "--task", "-"];
    let ran = node(&[&[MAXX], &words[..]].concat(), &stub, "第一行\n第二行\n\n").await;
    assert_eq!(ran.status, 0, "{}", ran.stderr);
    assert_eq!(serde_json::from_str::<Value>(&ran.stdout).unwrap(), started);
    assert_eq!(
        asked(),
        "agent\nstart\n{\"title\":\"试试\",\"task\":\"第一行\\n第二行\"}\n"
    );
    // By position, and a failure: why, and status 1.
    let words = ["agent", "steer", "max-agent-1", "refuse this"];
    let ran = node(&[&[MAXX], &words[..]].concat(), &stub, "").await;
    assert_eq!(ran.status, 1, "{}", ran.stdout);
    assert_eq!(ran.stderr, "agent steer: no room (failed)\n");
    assert_eq!(
        asked(),
        "agent\nsteer\n{\"name\":\"max-agent-1\",\"text\":\"refuse this\"}\n"
    );

    // A program of Max's own, which requires the tools: the same call,
    // its value or a ToolError.
    let program = format!(
        "const {{ tools, ToolError }} = require({TOOLS_JS:?}); (async () => {{ \
           const a = await tools.agent_start({{ task: '查一下' }}); \
           let failed; try {{ await tools.agent_steer({{ name: 'max-agent-1', text: 'refuse' }}) }} \
           catch (e) {{ failed = [e instanceof ToolError, e.message] }} \
           console.log(JSON.stringify([a, failed])); }})()"
    );
    let ran = node(&["-e", &program], &stub, "").await;
    assert_eq!(ran.status, 0, "{}", ran.stderr);
    assert_eq!(
        serde_json::from_str::<Value>(&ran.stdout).unwrap(),
        json!([started, [true, "agent_steer: no room (failed)"]])
    );
    assert!(asked().starts_with("agent\nstart\n{\"task\":\"查一下\"}\n"));

    // A run_code program: the same again, with the host's tools beside.
    let input = json!({
        "code": "return [await tools.agent_start({ task: 't' }), typeof tools.units_list, typeof tools.events, typeof max.image]",
        "tools": ["history"],
    });
    let ran = node(&[RUNNER], &stub, &input.to_string()).await;
    assert_eq!(ran.status, 0, "{}", ran.stderr);
    assert_eq!(
        serde_json::from_str::<Value>(&ran.stdout).unwrap(),
        json!([started, "function", "function", "undefined"])
    );
    std::fs::remove_dir_all(dir).unwrap();
}
