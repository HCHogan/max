//! `send_image`: a picture a program made or fetched in /work, sent to
//! its group. See "发图".

use std::fs::File;
use std::io::Read;
use std::path::{Component, Path, PathBuf};

use chrono::Utc;
use image::ImageFormat;
use max_core::message::{Draft, DraftNode};
use max_db::media::{self, Blob};
use rustix::fs::{Mode, OFlags};
use rustix::io::Errno;
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::task::spawn_blocking;
use tracing::warn;

use super::{Context, Failure, arguments};
use crate::media::prepare::{png, prepare};

/// The largest picture sent, in bytes.
const MOST: u64 = 10 << 20;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Args {
    path: String,
    caption: Option<String>,
}

pub async fn run(context: &Context, args: Value) -> Result<Value, Failure> {
    let Args { path, caption } = arguments("send_image", args)?;
    let (Some(work), Some(store), Some(poster)) = (&context.work, &context.store, &context.poster)
    else {
        return Err(Failure::new("unavailable", "这里发不了图。"));
    };
    let relative = beneath_work(&path)?;
    let work = work.clone();
    let read = spawn_blocking(move || read(&work, &relative));
    let bytes = read.await.map_err(|_| internal())??;
    let (bytes, mime) = picture(bytes).await?;
    let (prepared, bytes) = spawn_blocking(move || (prepare(&bytes), bytes))
        .await
        .map_err(|_| internal())?;
    let Ok(Some(prepared)) = prepared else {
        return Err(Failure::new("not_a_picture", format!("{path} 解不开")));
    };
    let size = bytes.len() as u64;
    let stored = async {
        let sha256 = store.put(bytes).await?;
        let model_sha256 = match prepared.copy {
            Some(copy) => store.put(copy).await?,
            None => sha256.clone(),
        };
        Ok::<_, std::io::Error>((sha256, model_sha256))
    };
    let (sha256, model_sha256) = stored.await.map_err(|error| {
        warn!(%error, "couldn't store a picture to send");
        internal()
    })?;
    let blob = Blob {
        sha256: sha256.clone(),
        mime: Some(mime.to_owned()),
        size,
        width: Some(prepared.width),
        height: Some(prepared.height),
        model_sha256: Some(model_sha256),
    };
    let mut conn = context.pool.acquire().await?;
    media::remember(&mut conn, &blob, Utc::now()).await?;
    drop(conn);
    let mut nodes = vec![DraftNode::Made {
        sha256,
        mime: mime.to_owned(),
        size,
    }];
    if let Some(caption) = caption.map(|caption| caption.trim().to_owned())
        && !caption.is_empty()
    {
        nodes.push(DraftNode::Text { text: caption });
    }
    let draft = Draft {
        reply_to: None,
        nodes,
    };
    let id = poster
        .post(draft)
        .await
        .map_err(|error| Failure::new("not_sent", format!("没发出去：{error}")))?;
    Ok(json!({ "handle": format!("image#{id}.0") }))
}

fn internal() -> Failure {
    Failure::new("internal", "出错了，稍后再试。")
}

/// The path under /work that `path` names, from /work: absolute within
/// it, or relative to it. No `..`.
fn beneath_work(path: &str) -> Result<PathBuf, Failure> {
    let path = Path::new(path);
    let path = path.strip_prefix("/work").unwrap_or(path);
    let mut relative = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Normal(name) => relative.push(name),
            Component::CurDir => {}
            _ => {
                return Err(Failure::new(
                    "bad_path",
                    "只能发 /work 下的文件，路径里不能有 ..",
                ));
            }
        }
    }
    if relative.as_os_str().is_empty() {
        return Err(Failure::new("bad_path", "path 得是一个文件"));
    }
    Ok(relative)
}

/// Reads `relative` under `work`, opening one component at a time
/// without following a symlink: the guest writes /work, and a link there
/// would point into the host. Blocking.
fn read(work: &Path, relative: &Path) -> Result<Vec<u8>, Failure> {
    let shown = Path::new("/work").join(relative).display().to_string();
    let failed = |errno: Errno| match errno {
        Errno::NOENT => Failure::new("not_found", format!("{shown} 不存在")),
        Errno::LOOP | Errno::NOTDIR | Errno::MLINK => Failure::new(
            "bad_path",
            format!("{shown}：路径上有符号链接，或者有一段不是目录"),
        ),
        errno => Failure::new("unreadable", format!("读不了 {shown}：{errno}")),
    };
    let flags = OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC;
    let mut dir =
        rustix::fs::open(work, flags | OFlags::DIRECTORY, Mode::empty()).map_err(failed)?;
    let names: Vec<_> = relative.iter().collect();
    let Some((last, parents)) = names.split_last() else {
        return Err(Failure::new("bad_path", "path 得是一个文件"));
    };
    for name in parents {
        dir = rustix::fs::openat(&dir, *name, flags | OFlags::DIRECTORY, Mode::empty())
            .map_err(failed)?;
    }
    // Without blocking, so that a FIFO can't hold the open.
    let file =
        rustix::fs::openat(&dir, *last, flags | OFlags::NONBLOCK, Mode::empty()).map_err(failed)?;
    let mut file = File::from(file);
    let unreadable =
        |error: std::io::Error| Failure::new("unreadable", format!("读不了 {shown}：{error}"));
    let metadata = file.metadata().map_err(unreadable)?;
    if !metadata.is_file() {
        return Err(Failure::new("bad_path", format!("{shown} 不是普通文件")));
    }
    let too_big = || Failure::new("too_big", format!("{shown} 超过 10 MiB 了"));
    if metadata.len() > MOST {
        return Err(too_big());
    }
    let mut bytes = Vec::new();
    (&mut file)
        .take(MOST + 1)
        .read_to_end(&mut bytes)
        .map_err(unreadable)?;
    if bytes.len() as u64 > MOST {
        return Err(too_big());
    }
    Ok(bytes)
}

/// The picture as QQ takes it, and its type: PNG, JPEG and GIF as they
/// are, WebP as PNG.
async fn picture(bytes: Vec<u8>) -> Result<(Vec<u8>, &'static str), Failure> {
    let not_one = || Failure::new("not_a_picture", "只发得了 PNG、JPEG、GIF、WebP");
    match image::guess_format(&bytes).map_err(|_| not_one())? {
        ImageFormat::Png => Ok((bytes, "image/png")),
        ImageFormat::Jpeg => Ok((bytes, "image/jpeg")),
        ImageFormat::Gif => Ok((bytes, "image/gif")),
        ImageFormat::WebP => {
            let converted = spawn_blocking(move || png(&bytes))
                .await
                .map_err(|_| internal())?;
            let png = converted.map_err(|_| Failure::new("not_a_picture", "这张 WebP 解不开"))?;
            Ok((png, "image/png"))
        }
        _ => Err(not_one()),
    }
}

#[cfg(test)]
mod tests;
