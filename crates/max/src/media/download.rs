//! The download worker: each medium a message brings with an address, into
//! the content store and `message_media`. See "媒体" in
//! docs/rust-rewrite.md.

use std::fmt;
use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use color_eyre::eyre::{Result, eyre};
use max_core::ids::MessageId;
use max_core::message::{Content, MediaRef, Node, media};
use max_db::PgPool;
use max_db::media::{Blob, downloaded, pending, record};
use reqwest::Client;
use tracing::warn;

use super::fetch::{self, fetch};
use super::store::Store;
use crate::worker::{Attempt, Derivation, Policy, Row};

/// The most a medium may be; past it, only what QQ said of it is kept.
const MOST: u64 = 64 << 20;
/// How far back a scan looks. QQ's addresses expire: the Haskell version
/// tried hundreds of dead ones again on every restart (9f27fa7).
const SCAN: Duration = Duration::from_secs(3600);

pub const POLICY: Policy = Policy {
    name: "download",
    concurrent: 4,
    timeout: fetch::TIMEOUT,
    retries: &[Duration::from_secs(1), Duration::from_secs(4)],
    rescan: None,
};

pub struct Download {
    pub pool: PgPool,
    pub http: Client,
    pub store: Arc<Store>,
}

/// The `ordinal`-th medium of a message. The logs show only that: QQ's
/// addresses carry a key.
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct Medium {
    pub message: MessageId,
    pub ordinal: u16,
    pub url: String,
}

impl fmt::Debug for Medium {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}", self.message, self.ordinal)
    }
}

impl Derivation for Download {
    type Input = Row;
    type Unit = Medium;

    fn on_input(&self, row: Row) -> Vec<Medium> {
        match &row.message.content {
            Content::Message { nodes, .. } | Content::Edit { nodes, .. } => {
                remote(row.message.id, nodes)
            }
            Content::Unsend { .. } => Vec::new(),
        }
    }

    async fn scan(&self) -> Result<Vec<Medium>> {
        let since = Utc::now() - SCAN;
        let mut conn = self.pool.acquire().await?;
        let pending = pending(&mut conn, since).await?;
        Ok(pending
            .into_iter()
            .flat_map(|pending| {
                let message = pending.message;
                pending
                    .remote
                    .into_iter()
                    .map(move |(ordinal, url)| Medium {
                        message,
                        ordinal,
                        url,
                    })
            })
            .collect())
    }

    async fn run(&self, medium: &Medium, _: Attempt) -> Result<()> {
        let mut conn = self.pool.acquire().await?;
        let done = downloaded(&mut conn, medium.message).await?;
        drop(conn);
        if done.iter().any(|(ordinal, _)| *ordinal == medium.ordinal) {
            return Ok(());
        }
        let fetched = match fetch(&self.http, &medium.url, MOST).await {
            Ok(fetched) => fetched,
            Err(error) if error.retryable() => return Err(eyre!("{error}")),
            // An address that expired, or a file too large: another try
            // won't do better.
            Err(error) => {
                warn!(worker = POLICY.name, unit = ?medium, "gave up: {error}");
                return Ok(());
            }
        };
        let size = u64::try_from(fetched.bytes.len())?;
        let sha256 = self.store.put(fetched.bytes).await?;
        let blob = Blob {
            sha256,
            mime: fetched.mime,
            size,
            width: None,
            height: None,
        };
        let mut conn = self.pool.acquire().await?;
        record(&mut conn, medium.message, medium.ordinal, &blob, Utc::now()).await?;
        Ok(())
    }
}

/// The media of a message that came with an address.
fn remote(message: MessageId, nodes: &[Node]) -> Vec<Medium> {
    media(nodes)
        .filter_map(|(ordinal, media, _)| match media {
            Some(MediaRef::Remote(url)) => Some(Medium {
                message,
                ordinal,
                url: url.clone(),
            }),
            _ => None,
        })
        .collect()
}

#[cfg(test)]
mod tests;
