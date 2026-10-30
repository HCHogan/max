//! `send_image`: a picture a program made or fetched in /work, sent to
//! its group. See "发图".

use chrono::Utc;
use image::ImageFormat;
use max_core::message::{Draft, DraftNode};
use max_db::media::{self, Blob};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use tokio::task::spawn_blocking;
use tracing::warn;

use super::tool::Tool;
use super::work::{beneath_work, read};
use super::{Context, Failure, internal};
use crate::media::prepare::{png, prepare};

/// The largest picture sent, in bytes.
const MOST: u64 = 10 << 20;
const PER_RUN: u32 = 5;

pub struct SendImage;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Args {
    #[schemars(length(min = 1), description = "/work 下的路径，相对路径从 /work 算")]
    path: String,
    #[schemars(description = "图下面的说明，可以不写")]
    caption: Option<String>,
}

#[derive(Serialize, JsonSchema)]
pub struct Sent {
    handle: String,
}

impl Tool for SendImage {
    const NAME: &'static str = "send_image";
    const DESCRIPTION: &'static str =
        "把 /work 下的一张图发到本群，比如画的图表、截的图、下载的图片。";
    const PER_RUN: Option<u32> = Some(PER_RUN);
    const JOB: bool = false;

    type Args = Args;
    type Output = Sent;

    fn guide() -> String {
        format!(
            "把 /work 下的一张图发到本群：画的图表、截的图、下载的图片。PNG、JPEG、GIF、WebP，最大 {} MiB；路径上不能有符号链接。\n  \
            caption 是图下面的一句说明，和图在同一条消息里。发出去了才返回，handle 是这条消息里那张图的句柄。一次运行最多发 {PER_RUN} 张。\n  \
            记录里已有的图和表情包不用这个，直接在回复里写它的句柄。",
            MOST >> 20
        )
    }

    async fn run(context: &Context, args: Args) -> Result<Sent, Failure> {
        send(context, args).await
    }
}

async fn send(context: &Context, Args { path, caption }: Args) -> Result<Sent, Failure> {
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
    Ok(Sent {
        handle: format!("image#{id}.0"),
    })
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
