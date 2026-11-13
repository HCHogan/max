//! What a call shows the model after its result: the pictures and videos
//! its program left with `tools.show` and `tools.video`, or its command with
//! `maxx show` and `maxx video`. The guest asks the host nothing for
//! them: each is a path under /work in the list the call's line carries
//! (nix/shown.js, nix/max-jobs.sh), and the host reads the files here, as
//! it puts the result together. What can't be shown is said in the
//! result, since the program is over by then. The host never decodes a
//! video: the VM's ffmpeg made it small (video.js), the host reads its
//! movie header for the length, and the provider gets the bytes. See
//! "Multimodal results".

use std::path::Path;
use std::sync::Arc;

use max_core::item::Part;
use max_core::message::MediaRef;
use serde::Deserialize;
use tokio::task::spawn_blocking;
use tracing::warn;

use super::Context;
use crate::media::mp4;
use crate::media::prepare::prepare;
use crate::media::store::Store;
use crate::service::Failure;
use crate::service::work::{beneath_work, read};
use max_core::limits::{PICTURE_BYTES, PICTURES_PER_RUN, VIDEO_BYTES, VIDEO_SECONDS};

/// The most of a call's list that is looked at: what a call may show is a
/// few pictures and ten minutes of video.
const MOST: usize = 16;

/// One thing a call left to show: an `image` or a `video`, a file under
/// /work.
#[derive(Clone, Debug, Deserialize)]
pub(crate) struct Left {
    kind: String,
    path: String,
}

/// What the model is shown of a call's list, and a line for each thing
/// that isn't shown, saying why.
#[derive(Debug, Default)]
pub(crate) struct Shown {
    pub parts: Vec<Part>,
    pub refused: Vec<String>,
}

/// Reads what a call `left` from `work`, the host's side of its /work,
/// in order, each kept in the content store.
pub(crate) async fn shown(context: &Context, work: &Path, left: &[Left]) -> Shown {
    let mut shown = Shown::default();
    for Left { kind, path } in left.iter().take(MOST) {
        let part = match kind.as_str() {
            "image" => image(context, work, path, &shown.parts).await,
            "video" => video(context, work, path, &shown.parts).await,
            _ => Err(Failure::new("unknown", format!("nothing shows a {kind}"))),
        };
        match part {
            // The same thing twice is shown once.
            Ok(part) if shown.parts.contains(&part) => {}
            Ok(part) => shown.parts.push(part),
            Err(Failure { message, .. }) => {
                shown
                    .refused
                    .push(format!("{path} wasn't shown: {message}"));
            }
        }
    }
    if left.len() > MOST {
        let rest = left.len() - MOST;
        shown.refused.push(format!(
            "{rest} more weren't looked at: a call shows at most {MOST} things"
        ));
    }
    shown
}

/// The model's copy of the picture at `path`, if there is room for one
/// more after `so_far`.
async fn image(
    context: &Context,
    work: &Path,
    path: &str,
    so_far: &[Part],
) -> Result<Part, Failure> {
    let pictures = so_far
        .iter()
        .filter(|part| matches!(part, Part::Media { .. }))
        .count();
    let (store, bytes) = read_work(context, work, path, PICTURE_BYTES, "pictures").await?;
    let (prepared, bytes) = spawn_blocking(move || (prepare(&bytes), bytes))
        .await
        .map_err(|_| internal())?;
    let Ok(Some(prepared)) = prepared else {
        return Err(Failure::new(
            "not_a_picture",
            "it isn't a PNG, JPEG, GIF or WebP that decodes",
        ));
    };
    let copy = prepared.copy.unwrap_or(bytes);
    let part = Part::Media {
        media: MediaRef::Blob(keep(&store, copy).await?),
    };
    // One shown already takes no room.
    if pictures >= PICTURES_PER_RUN && !so_far.contains(&part) {
        return Err(Failure::new(
            "too_many",
            format!("one call shows at most {PICTURES_PER_RUN} pictures"),
        ));
    }
    Ok(part)
}

/// The MP4 at `path`, which video.js made for the model, if the model
/// watches videos and there is room for it after `so_far`.
async fn video(
    context: &Context,
    work: &Path,
    path: &str,
    so_far: &[Part],
) -> Result<Part, Failure> {
    if !context.video {
        return Err(Failure::new(
            "unavailable",
            "this model doesn't watch videos",
        ));
    }
    let (store, bytes) = read_work(context, work, path, VIDEO_BYTES, "videos").await?;
    let Some(length) = mp4::length(&bytes) else {
        return Err(Failure::new("not_a_video", "it isn't an MP4 that decodes"));
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
    let part = Part::Video {
        media: MediaRef::Blob(keep(&store, bytes).await?),
        seconds,
    };
    let watched: u32 = so_far
        .iter()
        .map(|part| match part {
            Part::Video { seconds, .. } => *seconds,
            _ => 0,
        })
        .sum();
    if watched.saturating_add(seconds) > VIDEO_SECONDS && !so_far.contains(&part) {
        return Err(Failure::new(
            "too_long",
            format!(
                "one call shows at most {} minutes of video, and this is {seconds} seconds after {watched} shown already: cut a piece with start and end",
                VIDEO_SECONDS / 60
            ),
        ));
    }
    Ok(part)
}

/// The file at `path` in the call's /work, at most `largest` bytes, and
/// the store to keep what is shown of it, a `what`.
async fn read_work(
    context: &Context,
    work: &Path,
    path: &str,
    largest: u64,
    what: &str,
) -> Result<(Arc<Store>, Vec<u8>), Failure> {
    let Some(store) = &context.store else {
        return Err(Failure::new(
            "unavailable",
            format!("{what} can't be shown here"),
        ));
    };
    let relative = beneath_work(path)?;
    let work = work.to_owned();
    let bytes = spawn_blocking(move || read(&work, &relative, largest))
        .await
        .map_err(|_| internal())??;
    Ok((Arc::clone(store), bytes))
}

/// Stores `bytes`: their SHA-256.
async fn keep(store: &Store, bytes: Vec<u8>) -> Result<String, Failure> {
    store.put(bytes).await.map_err(|error| {
        warn!(%error, "couldn't store what a call showed");
        internal()
    })
}

fn internal() -> Failure {
    Failure::new("internal", "something went wrong; try again later")
}
