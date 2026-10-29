//! The pictures a model call is sent: the versions made for the model,
//! read from the content store as data URLs. An item names a row's
//! medium; this finds it. See "媒体".

use std::collections::{BTreeMap, HashSet};
use std::io;
use std::sync::Arc;
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use chrono::Utc;
use max_core::ids::MessageId;
use max_core::item::{Image, ItemKind};
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

pub struct Pictures {
    pub pool: PgPool,
    pub store: Arc<Store>,
}

impl Pictures {
    /// The pictures `request` names, by handle. Those that are gone, or
    /// can't be read, are left out with a warning; the model still has
    /// their handles.
    pub async fn read(&self, request: &Request) -> max_llm::Pictures {
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
            return max_llm::Pictures::default();
        }
        let found = match self.find(&wanted).await {
            Ok(found) => found,
            Err(error) => {
                warn!(%error, "finding the pictures for a model call");
                return max_llm::Pictures::default();
            }
        };
        let mut pictures = BTreeMap::new();
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

#[cfg(test)]
mod tests;
