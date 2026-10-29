//! The guest's webread, run here with Python against a local server.

use std::process::Stdio;
use std::time::Duration;

use axum::Router;
use axum::http::{StatusCode, header};
use axum::response::Redirect;
use axum::routing::get;
use tokio::net::TcpListener;
use tokio::process::Command;
use tokio_util::sync::CancellationToken;

const WEBREAD: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../nix/webread.py");

struct Read {
    status: i32,
    stdout: String,
    stderr: String,
}

async fn webread(dir: &std::path::Path, args: &[&str]) -> Read {
    let mut command = Command::new("python3");
    command
        .arg(WEBREAD)
        .args(args)
        .env("WEBREAD_DIR", dir)
        .stdin(Stdio::null())
        .kill_on_drop(true);
    for proxy in [
        "http_proxy",
        "HTTP_PROXY",
        "https_proxy",
        "HTTPS_PROXY",
        "all_proxy",
        "ALL_PROXY",
    ] {
        command.env_remove(proxy);
    }
    let out = tokio::time::timeout(Duration::from_secs(60), command.output())
        .await
        .unwrap()
        .expect("python3 runs webread");
    Read {
        status: out.status.code().unwrap(),
        stdout: String::from_utf8(out.stdout).unwrap(),
        stderr: String::from_utf8(out.stderr).unwrap(),
    }
}

fn article() -> String {
    let paragraph = "探头补偿不对，方波的边沿会过冲或者变圆。拿探头接校准端子，用小螺丝刀调补偿电容，直到方波平顶。";
    let paragraphs: String = (0..8)
        .map(|n| format!("<p>第{n}段：{paragraph}</p>"))
        .collect();
    format!(
        r#"<!doctype html><html><head><meta charset="utf-8"><title>示波器探头补偿 - 某论坛</title></head>
        <body><nav><a href="/">首页</a></nav><div class="sidebar"><a href="/x">热帖一</a></div>
        <article><h1>示波器探头补偿</h1>{paragraphs}<h2>步骤</h2><ul><li>先接地夹</li><li>再调电容</li></ul>
        <p>详见 <a href="https://example.com/manual">手册</a>。</p></article>
        <footer>版权所有 · 备案号</footer></body></html>"#
    )
}

/// A one-page PDF that says `text`, in Helvetica.
fn pdf(text: &str) -> Vec<u8> {
    let stream = format!("BT /F1 12 Tf 72 720 Td ({text}) Tj ET");
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>".to_owned(),
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_owned(),
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R \
         /Resources << /Font << /F1 5 0 R >> >> >>"
            .to_owned(),
        format!(
            "<< /Length {} >>\nstream\n{stream}\nendstream",
            stream.len()
        ),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".to_owned(),
    ];
    let mut out = String::from("%PDF-1.4\n");
    let mut offsets = Vec::new();
    for (n, object) in objects.iter().enumerate() {
        offsets.push(out.len());
        out += &format!("{} 0 obj\n{object}\nendobj\n", n + 1);
    }
    let xref = out.len();
    out += &format!("xref\n0 {}\n0000000000 65535 f \n", objects.len() + 1);
    for offset in offsets {
        out += &format!("{offset:010} 00000 n \n");
    }
    out += &format!(
        "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n",
        objects.len() + 1
    );
    out.into_bytes()
}

#[tokio::test]
async fn pages_pdfs_and_text_and_what_isnt() {
    let html = article();
    let app = Router::new()
        .route(
            "/article",
            get(|| async move { ([(header::CONTENT_TYPE, "text/html; charset=utf-8")], html) }),
        )
        .route("/hop", get(|| async { Redirect::temporary("/article") }))
        .route("/loop", get(|| async { Redirect::temporary("/loop") }))
        .route(
            "/doc.pdf",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "application/pdf")],
                    pdf("Probe compensation"),
                )
            }),
        )
        .route(
            "/data.json",
            get(|| async { ([(header::CONTENT_TYPE, "application/json")], r#"{"a":1}"#) }),
        )
        .route(
            "/a.png",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "image/png")],
                    b"\x89PNG\r\n".to_vec(),
                )
            }),
        )
        .route("/gone", get(|| async { StatusCode::NOT_FOUND }))
        .route("/big", get(|| async { "a".repeat((10 << 20) + 1) }));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let stop = CancellationToken::new();
    let server = axum::serve(listener, app).with_graceful_shutdown(stop.clone().cancelled_owned());
    let dir = std::env::temp_dir().join(format!("max-webread-{:016x}", rand::random::<u64>()));
    let url = |path: &str| format!("{base}{path}");

    let test = async {
        let read = webread(&dir, &[&url("/hop")]).await;
        assert_eq!(read.status, 0, "{}", read.stderr);
        let (first, text) = read.stdout.split_once('\n').unwrap();
        let header = format!(
            "URL: {} | 示波器探头补偿 | text/html | 第 0–",
            url("/article")
        );
        assert!(first.starts_with(&header), "{first}");
        assert!(first.contains("全文在"), "{first}");
        for kept in [
            "## 步骤",
            "- 先接地夹",
            "[手册](https://example.com/manual)",
            "第7段",
        ] {
            assert!(text.contains(kept), "{kept} in {text}");
        }
        for left in ["备案号", "热帖", "首页"] {
            assert!(!text.contains(left), "{left} in {text}");
        }
        // The rest comes from what was saved.
        let read = webread(&dir, &[&url("/hop"), "--offset", "10", "--max", "5"]).await;
        let first = read.stdout.lines().next().unwrap();
        assert!(
            first.starts_with(&header.replace("第 0–", "第 10–15 字")),
            "{first}"
        );
        let (_, shown) = read.stdout.split_once('\n').unwrap();
        assert_eq!(shown.strip_suffix('\n').unwrap().chars().count(), 5);

        let read = webread(&dir, &[&url("/doc.pdf")]).await;
        assert_eq!(read.status, 0, "{}", read.stderr);
        assert!(
            read.stdout.contains("Probe compensation"),
            "{}",
            read.stdout
        );
        assert!(read.stdout.contains("| （无标题） | application/pdf |"));

        let read = webread(&dir, &[&url("/data.json")]).await;
        assert!(read.stdout.ends_with("{\"a\":1}\n"), "{}", read.stdout);

        for (path, why) in [
            ("/a.png", "不是网页、PDF 或文本，是 image/png"),
            ("/gone", "HTTP 404"),
            ("/loop", "跳转超过 5 次"),
            ("/big", "太大了"),
        ] {
            let read = webread(&dir, &[&url(path)]).await;
            assert_eq!(read.status, 1, "{path}");
            assert!(read.stderr.contains(why), "{path}: {}", read.stderr);
        }
        assert_eq!(webread(&dir, &["ftp://example.com/x"]).await.status, 2);
        stop.cancel();
    };
    let (served, ()) = tokio::join!(server.into_future(), test);
    served.unwrap();
    let _ = std::fs::remove_dir_all(&dir);
}
