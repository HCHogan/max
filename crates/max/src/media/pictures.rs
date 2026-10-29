//! The pictures a model call is sent: the versions made for the model,
//! read from the content store as data URLs. An item names a row's
//! medium, and this finds it; a tool result names the file itself. See
//! "媒体" and "多模态结果".

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

/// How long after a row came in its pictures are waited for, while they
/// download. One not there by then is left out.
const WAIT: Duration = Duration::from_secs(10);
/// Between looks while waiting.
const POLL: Duration = Duration::from_millis(250);
/// The most pictures of tool results a call is sent: the newest. Older
/// ones are named in their results instead.
const MOST_SHOWN: usize = 8;

pub struct Pictures {
    pub pool: PgPool,
    pub store: Arc<Store>,
}

impl Pictures {
    /// The pictures `request` names: rows' by handle, tool results' by
    /// SHA-256. Those that are gone, or can't be read, are left out with a
    /// warning; the model still has their handles.
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

/// The pictures tool results in `request` show, newest first, each once,
/// at most [`MOST_SHOWN`].
fn shown(request: &Request) -> Vec<&str> {
    let mut shown = Vec::new();
    let parts = request.items.iter().rev().flat_map(|item| {
        let parts = match &item.kind {
            ItemKind::ToolResult { output, .. } => output.parts.as_slice(),
            _ => &[],
        };
        parts.iter().rev()
    });
    for part in parts {
        if let Part::Media {
            media: MediaRef::Blob(sha256),
        } = part
            && !shown.contains(&sha256.as_str())
        {
            shown.push(sha256.as_str());
        }
    }
    shown.truncate(MOST_SHOWN);
    shown
}

#[cfg(test)]
mod tests;
