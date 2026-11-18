//! The pictures a model call is sent: the versions made for the model,
//! read from the content store. An item names a row's medium, and this
//! finds it; a tool result names the file itself, and names videos too.
//! See "Media" and "Multimodal results".

use std::collections::HashSet;
use std::io;
use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use max_core::ids::MessageId;
use max_core::item::{Image, ItemKind, Part};
use max_core::message::{MediaRef, Sha256};
use max_core::run::Request;
use max_db::media;
use max_llm::Medium;
use sqlx::PgPool;
use tokio::fs;
use tracing::warn;

use super::store::Store;
use max_core::limits::VIDEO_SECONDS;

/// How long after a row came in its pictures are waited for, while they
/// download. One not there by then is left out.
const WAIT: Duration = Duration::from_secs(10);
/// Between looks while waiting.
const POLL: Duration = Duration::from_millis(250);

/// Reads the pictures a model call is sent.
#[derive(Debug)]
pub struct Pictures {
    /// The database, which says which file a row's picture is.
    pub pool: PgPool,
    /// The content store, which has the files.
    pub store: Arc<Store>,
}

impl Pictures {
    /// The pictures `request` names, its rows' and its tool results',
    /// and its tool results' videos. Those that are gone, or can't be
    /// read, are left out with a warning; the model still has their
    /// handles.
    pub async fn read(&self, request: &Request) -> max_llm::Pictures {
        let mut pictures = max_llm::Pictures::default();
        for sha256 in shown(request) {
            match self.picture(sha256).await {
                Ok(picture) => pictures.add_file(sha256.clone(), picture),
                Err(error) => warn!(%sha256, %error, "reading a tool's picture for a model call"),
            }
        }
        for sha256 in videos(request) {
            match fs::read(self.store.path(sha256)).await {
                Ok(bytes) => {
                    let mime = "video/mp4";
                    pictures.add_file(sha256.clone(), Medium { mime, bytes });
                }
                Err(error) => warn!(%sha256, %error, "reading a tool's video for a model call"),
            }
        }
        let wanted: HashSet<Image> = request
            .items
            .iter()
            .flat_map(|item| match &item.kind {
                ItemKind::User { images, .. } => images.as_slice(),
                _ => &[],
            })
            .copied()
            .collect();
        if wanted.is_empty() {
            return pictures;
        }
        let found = match self.find(&wanted).await {
            Ok(found) => found,
            Err(error) => {
                warn!(%error, "finding the pictures for a model call");
                return pictures;
            }
        };
        for (image, sha256) in found {
            match self.picture(&sha256).await {
                Ok(picture) => pictures.add_row(image, picture),
                Err(error) => {
                    let handle = image.handle();
                    warn!(handle, %error, "reading a picture for a model call");
                }
            }
        }
        pictures
    }

    /// The model's version of each wanted picture there is, after those
    /// of rows newer than [`WAIT`] have downloaded or run out of time.
    async fn find(&self, wanted: &HashSet<Image>) -> sqlx::Result<Vec<(Image, Sha256)>> {
        let messages: Vec<MessageId> = wanted
            .iter()
            .map(|image| image.message)
            .collect::<HashSet<_>>()
            .into_iter()
            .collect();
        loop {
            let mut conn = self.pool.acquire().await?;
            let rows = media::for_model(&mut conn, &messages).await?;
            drop(conn);
            let now = Utc::now();
            let mut found = Vec::new();
            let mut waiting = false;
            for image in wanted {
                let Some(row) = rows.get(&image.message) else {
                    continue;
                };
                match row.pictures.get(&image.ordinal) {
                    Some(sha256) => found.push((*image, sha256.clone())),
                    None => waiting |= now < row.received + WAIT,
                }
            }
            if !waiting {
                return Ok(found);
            }
            tokio::time::sleep(POLL).await;
        }
    }

    async fn picture(&self, sha256: &Sha256) -> io::Result<Medium> {
        let bytes = fs::read(self.store.path(sha256)).await?;
        let format = image::guess_format(&bytes).map_err(io::Error::other)?;
        Ok(Medium {
            mime: format.to_mime_type(),
            bytes,
        })
    }
}

/// The parts of `request`'s tool results, newest first.
fn parts(request: &Request) -> impl Iterator<Item = &Part> {
    request.items.iter().rev().flat_map(|item| {
        let parts = match &item.kind {
            ItemKind::ToolResult { output, .. } => output.parts.as_slice(),
            _ => &[],
        };
        parts.iter().rev()
    })
}

/// The pictures tool results in `request` show, each once: all of them.
/// Leaving out older ones changed a result the provider had cached with
/// each new picture past the limit, and everything after it; the next
/// turn has none of them anyway.
fn shown(request: &Request) -> Vec<&Sha256> {
    let mut shown = Vec::new();
    for part in parts(request) {
        if let Part::Media {
            media: MediaRef::Blob(sha256),
        } = part
            && !shown.contains(&sha256)
        {
            shown.push(sha256);
        }
    }
    shown
}

/// The videos tool results in `request` show, newest first, each once,
/// as long as they come to at most [`VIDEO_SECONDS`].
fn videos(request: &Request) -> Vec<&Sha256> {
    let mut videos = Vec::new();
    let mut left = VIDEO_SECONDS;
    for part in parts(request) {
        if let Part::Video {
            media: MediaRef::Blob(sha256),
            seconds,
        } = part
            && !videos.contains(&sha256)
        {
            let Some(after) = left.checked_sub(*seconds) else {
                break;
            };
            left = after;
            videos.push(sha256);
        }
    }
    videos
}
