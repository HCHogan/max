//! The embedding worker: a vector of each sticker's caption, for the
//! sticker library that `find_stickers` searches. The caption worker hands
//! it the captions it writes; its scan finds the rest, and all of them
//! again after a change of model. See "发图".

use std::collections::HashSet;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use chrono::Utc;
use color_eyre::eyre::Result;
use max_db::{PgPool, embeddings};
use tokio::sync::Semaphore;
use tokio::sync::mpsc::UnboundedReceiver;
use tokio::time::{MissedTickBehavior, interval, sleep};
use tokio_util::sync::CancellationToken;
use tracing::{debug, warn};

use crate::embedding::Embedder;
use crate::scope::Scope;

/// Captions embedded at a time.
const AT_ONCE: usize = 2;
/// How long to wait before each retry: the way to the embedding service
/// drops packets in the evenings. The client's own limit bounds each try.
const RETRIES: [Duration; 2] = [Duration::from_secs(10), Duration::from_secs(60)];
/// How often the captions without a vector are looked for: those given
/// up on, and after a change of model all of them.
const RESCAN: Duration = Duration::from_secs(3600);

pub struct Stickers {
    pub pool: PgPool,
    pub embedder: Arc<Embedder>,
}

impl Stickers {
    /// Until `stop`: the file of each sticker caption the caption worker
    /// writes, and every hour from the start those still without a
    /// vector. Vectors still being made then are dropped; a scan finds
    /// them.
    pub async fn run(self, mut written: UnboundedReceiver<String>, stop: CancellationToken) {
        let stickers = Arc::new(self);
        let slots = Arc::new(Semaphore::new(AT_ONCE));
        // The files being embedded: one written again meanwhile, or found
        // by a scan, isn't sent twice.
        let busy = Arc::new(Mutex::new(HashSet::new()));
        let mut embedding = Scope::new();
        let mut start = |sha256: String| {
            let mut files = busy.lock().unwrap_or_else(PoisonError::into_inner);
            if !files.insert(sha256.clone()) {
                return;
            }
            let (stickers, slots, busy) =
                (Arc::clone(&stickers), Arc::clone(&slots), Arc::clone(&busy));
            embedding.spawn(move |_| async move {
                stickers.tries(&sha256, &slots).await;
                let mut files = busy.lock().unwrap_or_else(PoisonError::into_inner);
                files.remove(&sha256);
            });
        };
        let mut scans = interval(RESCAN);
        scans.set_missed_tick_behavior(MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                () = stop.cancelled() => break,
                _ = scans.tick() => match stickers.scan().await {
                    Ok(missed) => missed.into_iter().for_each(&mut start),
                    Err(error) => warn!("the embedding scan failed: {error:#}"),
                },
                sha256 = written.recv() => match sha256 {
                    Some(sha256) => start(sha256),
                    None => break,
                },
            }
        }
        embedding.close(Duration::ZERO).await;
    }

    /// Embeds the caption of `sha256`, again after each failure, and gives
    /// up after the last retry until a scan finds it. A slot is held only
    /// while trying.
    async fn tries(&self, sha256: &str, slots: &Semaphore) {
        let mut retries = RETRIES.iter();
        loop {
            let Ok(slot) = slots.acquire().await else {
                return;
            };
            let tried = self.embed(sha256).await;
            drop(slot);
            let Err(error) = tried else { return };
            match retries.next() {
                Some(wait) => {
                    debug!(sha256, "an embedding failed: {error:#}");
                    sleep(*wait).await;
                }
                None => {
                    warn!(sha256, "gave up an embedding: {error:#}");
                    return;
                }
            }
        }
    }

    async fn scan(&self) -> Result<Vec<String>> {
        let mut conn = self.pool.acquire().await?;
        Ok(embeddings::unembedded(&mut conn, &self.embedder.model).await?)
    }

    /// One try at the vector of `sha256`'s caption, if it is a sticker's
    /// caption without one from this model.
    async fn embed(&self, sha256: &str) -> Result<()> {
        let model = &self.embedder.model;
        let mut conn = self.pool.acquire().await?;
        let Some(caption) = embeddings::to_embed(&mut conn, sha256, model).await? else {
            return Ok(());
        };
        drop(conn);
        let vector = self.embedder.one(&caption).await?;
        let mut conn = self.pool.acquire().await?;
        embeddings::write(&mut conn, sha256, model, &vector, Utc::now()).await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests;
