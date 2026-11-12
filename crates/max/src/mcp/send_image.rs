//! `send_image`: a picture a program made or fetched in /work, sent to
//! its group. See "Sending images".

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
use max_core::limits::PICTURE_BYTES;

pub struct SendImage;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Args {
    #[schemars(
        length(min = 1),
        description = "a path under /work; a relative one is from /work"
    )]
    path: String,
    #[schemars(description = "a caption under the picture; may be left out")]
    caption: Option<String>,
}

#[derive(Serialize, JsonSchema)]
pub struct Sent {
    handle: String,
}

impl Tool for SendImage {
    const NAME: &'static str = "send_image";
    const DESCRIPTION: &'static str = "Sends a picture under /work to this chat, such as a chart you drew, a screenshot or a downloaded picture.";

    type Args = Args;
    type Output = Sent;

    fn guide() -> String {
        format!(
            "Sends a picture under /work to this chat: a chart you drew, a screenshot, a downloaded picture. PNG, JPEG, GIF or WebP, at most {} MiB; no symlink on the path.\n  \
            caption is a line under the picture, in the same message. It returns once the picture is sent, and handle is the handle of that picture in its message.\n  \
            A picture or sticker the records already have needs none of this: write its handle in your reply.",
            PICTURE_BYTES >> 20
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
        context.poster.as_ref(),
    ) else {
        return Err(Failure::new(
            "unavailable",
            "pictures can't be sent from here",
        ));
    };
    let relative = beneath_work(&path)?;
    let work = work.clone();
    let read = spawn_blocking(move || read(&work, &relative, PICTURE_BYTES));
    let bytes = read.await.map_err(|_| internal())??;
    let (bytes, mime) = picture(bytes).await?;
    let (prepared, bytes) = spawn_blocking(move || (prepare(&bytes), bytes))
        .await
        .map_err(|_| internal())?;
    let Ok(Some(prepared)) = prepared else {
        return Err(Failure::new(
            "not_a_picture",
            format!("{path} doesn't decode"),
        ));
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
        .map_err(|error| Failure::new("not_sent", format!("not sent: {error}")))?;
    Ok(Sent {
        handle: format!("image#{id}.0"),
    })
}

/// The picture as QQ takes it, and its type: PNG, JPEG and GIF as they
/// are, WebP as PNG.
async fn picture(bytes: Vec<u8>) -> Result<(Vec<u8>, &'static str), Failure> {
    let not_one = || Failure::new("not_a_picture", "only PNG, JPEG, GIF and WebP can be sent");
    match image::guess_format(&bytes).map_err(|_| not_one())? {
        ImageFormat::Png => Ok((bytes, "image/png")),
        ImageFormat::Jpeg => Ok((bytes, "image/jpeg")),
        ImageFormat::Gif => Ok((bytes, "image/gif")),
        ImageFormat::WebP => {
            let converted = spawn_blocking(move || png(&bytes))
                .await
                .map_err(|_| internal())?;
            let png =
                converted.map_err(|_| Failure::new("not_a_picture", "this WebP doesn't decode"))?;
            Ok((png, "image/png"))
        }
        _ => Err(not_one()),
    }
}

#[cfg(test)]
mod tests;
