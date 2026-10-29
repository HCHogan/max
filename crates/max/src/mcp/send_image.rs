//! `send_image`: a picture a program made or fetched in /work, sent to
//! its group. See "发图".

use chrono::Utc;
use image::ImageFormat;
use max_core::message::{Draft, DraftNode};
use max_db::media::{self, Blob};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::task::spawn_blocking;
use tracing::warn;

use super::work::{beneath_work, read};
use super::{Context, Failure, arguments, internal};
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
    let (Some(work), Some(store), Some(poster)) = (
        &context.work,
        &context.services.store,
        context.caller.poster(),
    ) else {
        return Err(Failure::new("unavailable", "这里发不了图。"));
    };
    let relative = beneath_work(&path)?;
    let work = work.clone();
    let read = spawn_blocking(move || read(&work, &relative, MOST));
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
    let mut conn = context.services.pool.acquire().await?;
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
