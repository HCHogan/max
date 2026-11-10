//! What a program shows the model after its result: `max.image`'s
//! pictures and `max.video`'s videos, files it has in /work. Not Max's
//! tools: the runner's SDK calls them by these names, and the model sees
//! the picture or the video, not a value. The host never decodes a video:
//! the VM's ffmpeg made it small (video.js), the host reads its movie
//! header for the length, and the provider gets the bytes. See
//! "Multimodal results".

use std::sync::{Arc, Mutex};

use max_core::item::Part;
use max_core::message::MediaRef;
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::task::spawn_blocking;
use tracing::warn;

use super::work::{beneath_work, read};
use super::{Context, Failure, arguments, internal, lock};
use crate::media::mp4;
use crate::media::prepare::prepare;
use crate::media::store::Store;
use max_core::limits::{PICTURE_BYTES, PICTURES_PER_RUN, VIDEO_BYTES, VIDEO_SECONDS};

pub const IMAGE: &str = "max.image";
pub const VIDEO: &str = "max.video";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Args {
    path: String,
}

/// The model's copy of the picture at `path`, added to `shown`, the
/// program's pictures and videos so far.
pub async fn image(
    context: &Context,
    shown: &Mutex<Vec<Part>>,
    args: Value,
) -> Result<Value, Failure> {
    let Args { path } = arguments(IMAGE, args)?;
    let room = |shown: &[Part]| {
        let pictures = shown
            .iter()
            .filter(|part| matches!(part, Part::Media { .. }))
            .count();
        if pictures >= PICTURES_PER_RUN {
            return Err(Failure::new(
                "too_many",
                format!("one run_code shows at most {PICTURES_PER_RUN} pictures"),
            ));
        }
        Ok(())
    };
    room(&lock(shown))?;
    let (store, bytes) = read_work(context, &path, PICTURE_BYTES, "pictures").await?;
    let (prepared, bytes) = spawn_blocking(move || (prepare(&bytes), bytes))
        .await
        .map_err(|_| internal())?;
    let Ok(Some(prepared)) = prepared else {
        return Err(Failure::new(
            "not_a_picture",
            format!("{path} isn't a PNG, JPEG, GIF or WebP that decodes"),
        ));
    };
    let picture = |sha256| Part::Media {
        media: MediaRef::Blob(sha256),
    };
    let copy = prepared.copy.unwrap_or(bytes);
    keep(&store, copy, shown, picture, room).await?;
    Ok(json!({ "width": prepared.width, "height": prepared.height }))
}

/// The MP4 at `path`, which video.js made for the model, added to `shown`.
pub async fn video(
    context: &Context,
    shown: &Mutex<Vec<Part>>,
    args: Value,
) -> Result<Value, Failure> {
    let Args { path } = arguments(VIDEO, args)?;
    if !context.video {
        return Err(Failure::new(
            "unavailable",
            "this model doesn't watch videos",
        ));
    }
    let (store, bytes) = read_work(context, &path, VIDEO_BYTES, "videos").await?;
    let Some(length) = mp4::length(&bytes) else {
        return Err(Failure::new(
            "not_a_video",
            format!("{path} isn't an MP4 that decodes"),
        ));
    };
    // Whole seconds, at least one: the sound runs a little past the last
    // frame. The header is the program's word, so a length past any real
    // video's is just too long.
    #[expect(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        reason = "`as` saturates, and a header's length is never negative"
    )]
    let seconds = u32::try_from(length.round() as u64)
        .unwrap_or(u32::MAX)
        .max(1);
    let room = |shown: &[Part]| {
        let so_far: u32 = shown
            .iter()
            .map(|part| match part {
                Part::Video { seconds, .. } => *seconds,
                _ => 0,
            })
            .sum();
        if so_far.saturating_add(seconds) > VIDEO_SECONDS {
            return Err(Failure::new(
                "too_long",
                format!(
                    "one run_code shows at most {} minutes of video, and this is {seconds} seconds after {so_far} shown already: cut a piece with start and end",
                    VIDEO_SECONDS / 60
                ),
            ));
        }
        Ok(())
    };
    room(&lock(shown))?;
    let video = |sha256| Part::Video {
        media: MediaRef::Blob(sha256),
        seconds,
    };
    keep(&store, bytes, shown, video, room).await?;
    Ok(json!({ "seconds": seconds }))
}

/// The file at `path` in the program's /work, at most `largest` bytes,
/// and the store to keep what is shown of it, a `what`.
async fn read_work(
    context: &Context,
    path: &str,
    largest: u64,
    what: &str,
) -> Result<(Arc<Store>, Vec<u8>), Failure> {
    let (Some(work), Some(store)) = (&context.work, &context.services.store) else {
        return Err(Failure::new(
            "unavailable",
            format!("{what} can't be shown here"),
        ));
    };
    let relative = beneath_work(path)?;
    let work = work.clone();
    let bytes = spawn_blocking(move || read(&work, &relative, largest))
        .await
        .map_err(|_| internal())??;
    Ok((Arc::clone(store), bytes))
}

/// Stores `bytes`, and adds what `part` makes of their SHA-256 to `shown`
/// unless it is there already, if `room` finds room for it.
async fn keep(
    store: &Store,
    bytes: Vec<u8>,
    shown: &Mutex<Vec<Part>>,
    part: impl FnOnce(String) -> Part,
    room: impl Fn(&[Part]) -> Result<(), Failure>,
) -> Result<(), Failure> {
    let sha256 = store.put(bytes).await.map_err(|error| {
        warn!(%error, "couldn't store what a program showed");
        internal()
    })?;
    let part = part(sha256);
    let mut shown = lock(shown);
    if !shown.contains(&part) {
        room(&shown)?;
        shown.push(part);
    }
    Ok(())
}
