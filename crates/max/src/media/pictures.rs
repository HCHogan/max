//! The pictures a model call is sent: the versions made for the model,
//! read from the content store as data URLs. An item names a row's
//! medium, and this finds it; a tool result names the file itself, and
//! names videos too. See "媒体" and "多模态结果".

use std::collections::{BTreeMap, HashSet};
use std::io;
use std::sync::Arc;
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use chrono::Utc;
use max_core::ids::MessageId;
use max_core::item::{Image, ItemKind, Part};
use max_core::message::MediaRef;
use max_core::run::Request;
use max_db::media;
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

pub struct Pictures {
    pub pool: PgPool,
    pub store: Arc<Store>,
}

impl Pictures {
    /// The pictures `request` names: rows' by handle, tool results' by
    /// SHA-256; and its tool results' videos, by SHA-256. Those that are
    /// gone, or can't be read, are left out with a warning; the model
    /// still has their handles.
    pub async fn read(&self, request: &Request) -> max_llm::Pictures {
        let mut pictures = BTreeMap::new();
        for sha256 in shown(request) {
            match self.data_url(sha256).await {
                Ok(url) => {
                    pictures.insert(sha256.to_owned(), url);
                }
                Err(error) => warn!(%sha256, %error, "reading a tool's picture for a model call"),
            }
        }
        for sha256 in videos(request) {
            match fs::read(self.store.path(sha256)).await {
                Ok(bytes) => {
                    let url = format!("data:video/mp4;base64,{}", STANDARD.encode(&bytes));
                    pictures.insert(sha256.to_owned(), url);
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
            return max_llm::Pictures(pictures);
        }
        let found = match self.find(&wanted).await {
            Ok(found) => found,
            Err(error) => {
                warn!(%error, "finding the pictures for a model call");
                return max_llm::Pictures(pictures);
            }
        };
        for (image, sha256) in found {
            let handle = image.handle();
            match self.data_url(&sha256).await {
                Ok(url) => {
                    pictures.insert(handle, url);
                }
                Err(error) => warn!(%handle, %error, "reading a picture for a model call"),
            }
        }
        max_llm::Pictures(pictures)
    }

    /// The model's version of each wanted picture there is, after those
    /// of rows newer than [`WAIT`] have downloaded or run out of time.
    async fn find(&self, wanted: &HashSet<Image>) -> sqlx::Result<Vec<(Image, String)>> {
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
                let Some((received, pictures)) = rows.get(&image.message) else {
                    continue;
                };
                match pictures.get(&image.ordinal) {
                    Some(sha256) => found.push((*image, sha256.clone())),
                    None => waiting |= now < *received + WAIT,
                }
            }
            if !waiting {
                return Ok(found);
            }
            tokio::time::sleep(POLL).await;
        }
    }

    async fn data_url(&self, sha256: &str) -> io::Result<String> {
        let bytes = fs::read(self.store.path(sha256)).await?;
        let format = image::guess_format(&bytes).map_err(io::Error::other)?;
        Ok(format!(
            "data:{};base64,{}",
            format.to_mime_type(),
            STANDARD.encode(&bytes)
        ))
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
fn shown(request: &Request) -> Vec<&str> {
    let mut shown = Vec::new();
    for part in parts(request) {
        if let Part::Media {
            media: MediaRef::Blob(sha256),
        } = part
            && !shown.contains(&sha256.as_str())
        {
            shown.push(sha256.as_str());
        }
    }
    shown
}

/// The videos tool results in `request` show, newest first, each once,
/// as long as they come to at most [`VIDEO_SECONDS`].
fn videos(request: &Request) -> Vec<&str> {
    let mut videos = Vec::new();
    let mut left = VIDEO_SECONDS;
    for part in parts(request) {
        if let Part::Video {
            media: MediaRef::Blob(sha256),
            seconds,
        } = part
            && !videos.contains(&sha256.as_str())
        {
            let Some(after) = left.checked_sub(*seconds) else {
                break;
            };
            left = after;
            videos.push(sha256.as_str());
        }
    }
    videos
}

#[cfg(test)]
mod tests;
