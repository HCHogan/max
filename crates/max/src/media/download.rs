//! The download worker: each medium a message brings with an address, into
//! the content store and `message_media`. See "媒体" in
//! docs/rust-rewrite.md.

use std::fmt;
use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use color_eyre::eyre::{Result, eyre};
use max_core::ids::MessageId;
use max_core::item::Image;
use max_core::message::{Content, MediaKind, MediaRef};
use max_db::PgPool;
use max_db::captions::Kind;
use max_db::media::{Blob, downloaded, pending, record};
use reqwest::Client;
use tokio::sync::Semaphore;
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};
use tokio::task::spawn_blocking;
use tokio::time::sleep;
use tokio_util::sync::CancellationToken;
use tracing::{debug, warn};

use super::caption::Picture;
use super::fetch;
use super::prepare::{SNIFF, is_picture, prepare};
use super::store::Store;
use crate::scope::Scope;
use crate::worker::Row;
use max_core::limits::FILE_BYTES;

/// How far back a scan looks. QQ's addresses expire: the Haskell version
/// tried hundreds of dead ones again on every restart (9f27fa7).
const SCAN: Duration = Duration::from_secs(3600);

/// Downloads at a time.
const AT_ONCE: usize = 4;
/// How long to wait before each retry of a download that may go through
/// next time; the HTTP client's own timeout limits each try.
const RETRIES: [Duration; 2] = [Duration::from_secs(1), Duration::from_secs(4)];

/// What a download got: a picture whole, or anything else stored.
enum Got {
    Picture(Vec<u8>),
    Stored { sha256: String, size: u64 },
}

/// Why a try at a download failed: the download, which may not go better
/// next time, or the store.
enum Failed {
    Fetch(fetch::Error),
    Store(std::io::Error),
}

impl From<fetch::Error> for Failed {
    fn from(error: fetch::Error) -> Self {
        Self::Fetch(error)
    }
}

impl From<std::io::Error> for Failed {
    fn from(error: std::io::Error) -> Self {
        Self::Store(error)
    }
}

pub struct Download {
    pub pool: PgPool,
    pub http: Client,
    pub store: Arc<Store>,
    /// Where each picture goes on to once stored, when there is a
    /// caption worker.
    pub captions: Option<UnboundedSender<Picture>>,
}

/// The `ordinal`-th medium of a message. The logs show only that: QQ's
/// addresses carry a key.
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct Medium {
    pub message: MessageId,
    pub ordinal: u16,
    pub kind: MediaKind,
    pub url: String,
}

impl fmt::Debug for Medium {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}", self.message, self.ordinal)
    }
}

impl Download {
    /// Until `stop`: the media that rows bring, and at the start those
    /// the last hour's rows left behind. Downloads still running then are
    /// dropped; the next start's scan finds them.
    pub async fn run(self, mut rows: UnboundedReceiver<Row>, stop: CancellationToken) {
        let download = Arc::new(self);
        let slots = Arc::new(Semaphore::new(AT_ONCE));
        let mut downloads = Scope::new();
        let mut start = |medium: Medium| {
            let download = Arc::clone(&download);
            let slots = Arc::clone(&slots);
            downloads.spawn(move |_| async move { download.tries(&medium, &slots).await });
        };
        match download.scan().await {
            Ok(missed) => missed.into_iter().for_each(&mut start),
            Err(error) => warn!("the download scan failed: {error:#}"),
        }
        loop {
            tokio::select! {
                () = stop.cancelled() => break,
                row = rows.recv() => match row {
                    Some(row) => media(&row).into_iter().for_each(&mut start),
                    None => break,
                },
            }
        }
        downloads.close(Duration::ZERO).await;
    }

    /// Downloads `medium`, again after a failure that may not happen next
    /// time, and gives up after the last retry. A slot is held only while
    /// trying.
    async fn tries(&self, medium: &Medium, slots: &Semaphore) {
        let mut retries = RETRIES.iter();
        loop {
            let Ok(slot) = slots.acquire().await else {
                return;
            };
            let tried = self.download(medium).await;
            drop(slot);
            let Err(error) = tried else { return };
            match retries.next() {
                Some(wait) => {
                    debug!(unit = ?medium, "a download failed: {error:#}");
                    sleep(*wait).await;
                }
                None => {
                    warn!(unit = ?medium, "gave up a download: {error:#}");
                    return;
                }
            }
        }
    }

    /// Downloads `url`. Its first bytes tell a picture, which is read
    /// whole to be prepared; anything else, a video or a file of up to
    /// 64 MiB, goes into the store as it comes.
    async fn receive(&self, url: &str) -> Result<(Got, Option<String>), Failed> {
        let (mut body, mime) = fetch::open(&self.http, url, FILE_BYTES).await?;
        let mut head = Vec::new();
        while head.len() < SNIFF {
            let Some(chunk) = body.chunk().await? else {
                break;
            };
            head.extend_from_slice(&chunk);
        }
        if is_picture(&head) {
            return Ok((Got::Picture(body.rest(head).await?), mime));
        }
        let mut partial = self.store.partial().await?;
        partial.write(&head).await?;
        while let Some(chunk) = body.chunk().await? {
            partial.write(&chunk).await?;
        }
        let (sha256, size) = partial.finish().await?;
        Ok((Got::Stored { sha256, size }, mime))
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
                    .map(move |(ordinal, kind, url)| Medium {
                        message,
                        ordinal,
                        kind,
                        url,
                    })
            })
            .collect())
    }

    /// One try at `medium`, in one transaction; nothing if it's there
    /// already. An error is one another try might not get.
    async fn download(&self, medium: &Medium) -> Result<()> {
        let mut conn = self.pool.acquire().await?;
        let done = downloaded(&mut conn, medium.message).await?;
        drop(conn);
        if done.iter().any(|(ordinal, _)| *ordinal == medium.ordinal) {
            return Ok(());
        }
        let (got, mime) = match self.receive(&medium.url).await {
            Ok(received) => received,
            Err(Failed::Fetch(error)) if error.retryable() => return Err(eyre!("{error}")),
            // An address that expired, or a file too large: another try
            // won't do better.
            Err(Failed::Fetch(error)) => {
                warn!(unit = ?medium, "gave up a download: {error}");
                return Ok(());
            }
            Err(Failed::Store(error)) => return Err(error.into()),
        };
        let (sha256, size, prepared) = match got {
            Got::Picture(bytes) => {
                let size = u64::try_from(bytes.len())?;
                let (prepared, bytes) = spawn_blocking(move || (prepare(&bytes), bytes)).await?;
                (self.store.put(bytes).await?, size, Some(prepared))
            }
            Got::Stored { sha256, size } => (sha256, size, None),
        };
        let (mut width, mut height, mut model_sha256) = (None, None, None);
        match prepared {
            Some(Ok(Some(prepared))) => {
                width = Some(prepared.width);
                height = Some(prepared.height);
                model_sha256 = Some(match prepared.copy {
                    Some(copy) => self.store.put(copy).await?,
                    None => sha256.clone(),
                });
            }
            Some(Ok(None)) | None => {}
            Some(Err(error)) => warn!(unit = ?medium, "a picture that doesn't decode: {error}"),
        }
        let blob = Blob {
            sha256,
            mime,
            size,
            width,
            height,
            model_sha256,
        };
        let mut conn = self.pool.acquire().await?;
        record(&mut conn, medium.message, medium.ordinal, &blob, Utc::now()).await?;
        if let Some(captions) = &self.captions
            && blob.model_sha256.is_some()
            && Kind::of(medium.kind).is_some()
        {
            let image = Image {
                kind: medium.kind,
                message: medium.message,
                ordinal: medium.ordinal,
            };
            let _ = captions.send(Picture {
                image,
                sha256: blob.sha256,
            });
        }
        Ok(())
    }
}

/// The media of a row that came with an address.
fn media(row: &Row) -> Vec<Medium> {
    let message = row.message.id;
    let nodes = match &row.message.content {
        Content::Message { nodes, .. } | Content::Edit { nodes, .. } => nodes,
        Content::Unsend { .. } => return Vec::new(),
    };
    max_core::message::media(nodes)
        .filter_map(|(ordinal, media, meta)| match media {
            Some(MediaRef::Remote(url)) => Some(Medium {
                message,
                ordinal,
                kind: meta.kind,
                url: url.clone(),
            }),
            _ => None,
        })
        .collect()
}

#[cfg(test)]
mod tests;
