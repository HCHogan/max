//! The recall vector worker: a vector of each chat row that says
//! something, for `context_search`'s search by meaning. Each committed row
//! comes to it; its scan, at the start and every hour, finds the rest a
//! page at a time, newest first, and all of them again after a change of
//! model. See "召回".

use std::collections::HashSet;
use std::slice;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use chrono::Utc;
use color_eyre::eyre::Result;
use max_core::ids::MessageId;
use max_db::PgPool;
use max_db::vectors::{self, Of};
use tokio::sync::Semaphore;
use tokio::sync::mpsc::UnboundedReceiver;
use tokio::time::{MissedTickBehavior, interval, sleep};
use tokio_util::sync::CancellationToken;
use tracing::{debug, info, warn};

use crate::embedding::Embedder;
use crate::scope::Scope;
use crate::worker::Row;

/// Requests to the embedding service at a time.
const AT_ONCE: usize = 2;
/// How long to wait before each retry, as the stickers' worker does.
const RETRIES: [Duration; 2] = [Duration::from_secs(10), Duration::from_secs(60)];
/// How often what has no vector is looked for.
const RESCAN: Duration = Duration::from_secs(3600);
/// Texts a scan embeds in one request.
const PAGE: i64 = 16;
/// Characters of a text that are embedded: a long one's start says what
/// it is about, and a request stays well inside the service's time limit.
const MOST_CHARS: usize = 2000;

pub struct Vectors {
    pub pool: PgPool,
    pub embedder: Arc<Embedder>,
}

/// A committed row comes to the worker by its id.
impl From<Row> for MessageId {
    fn from(row: Row) -> Self {
        row.message.id
    }
}

impl Vectors {
    /// Until `stop`: each row that comes, and every hour from
    /// the start a scan, one at a time. Vectors still being made then are
    /// dropped; a scan finds them.
    pub async fn run(self, mut keys: UnboundedReceiver<MessageId>, stop: CancellationToken) {
        let worker = Arc::new(self);
        let slots = Arc::new(Semaphore::new(AT_ONCE));
        // What is being embedded: a row that a scan finds meanwhile is
        // embedded twice, which is only a waste.
        let busy = Arc::new(Mutex::new(HashSet::new()));
        let scanning = Arc::new(AtomicBool::new(false));
        let mut tasks = Scope::new();
        let mut scans = interval(RESCAN);
        scans.set_missed_tick_behavior(MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                () = stop.cancelled() => break,
                _ = scans.tick() => {
                    if scanning.swap(true, Ordering::SeqCst) {
                        continue;
                    }
                    let (worker, slots, scanning) =
                        (Arc::clone(&worker), Arc::clone(&slots), Arc::clone(&scanning));
                    tasks.spawn(move |_| async move {
                        match worker.scan(&slots).await {
                            Ok(pages) if pages > 0 => info!(pages, "recall vector pages made"),
                            Ok(_) => {}
                            Err(error) => warn!("the recall vector scan failed: {error:#}"),
                        }
                        scanning.store(false, Ordering::SeqCst);
                    });
                }
                key = keys.recv() => {
                    let Some(key) = key else { break };
                    if !busy.lock().unwrap_or_else(PoisonError::into_inner).insert(key) {
                        continue;
                    }
                    let (worker, slots, busy) =
                        (Arc::clone(&worker), Arc::clone(&slots), Arc::clone(&busy));
                    tasks.spawn(move |_| async move {
                        worker.tries(key, &slots).await;
                        busy.lock().unwrap_or_else(PoisonError::into_inner).remove(&key);
                    });
                }
            }
        }
        tasks.close(Duration::ZERO).await;
    }

    /// Embeds what of `key` has no vector, again after each failure, and
    /// gives up after the last retry until a scan finds it.
    async fn tries(&self, key: MessageId, slots: &Semaphore) {
        let mut retries = RETRIES.iter();
        loop {
            let Err(error) = self.once(slice::from_ref(&key), slots).await else {
                return;
            };
            match retries.next() {
                Some(wait) => {
                    debug!(?key, "a recall vector failed: {error:#}");
                    sleep(*wait).await;
                }
                None => {
                    warn!(?key, "gave up a recall vector: {error:#}");
                    return;
                }
            }
        }
    }

    /// Embeds a page at a time what has no vector, until nothing is left;
    /// how many pages were done. The next scan is a failed page's retry. A
    /// page that fails is tried again a text at a time, so that a text the
    /// service turns down doesn't hold up the rest; if none of them goes
    /// through either, the service is down, and the scan ends.
    async fn scan(&self, slots: &Semaphore) -> Result<usize> {
        let mut after = None;
        let mut pages = 0;
        loop {
            let mut conn = self.pool.acquire().await?;
            let page = vectors::unembedded(&mut conn, &self.embedder.model, after, PAGE).await?;
            drop(conn);
            let Some(last) = page.last() else {
                return Ok(pages);
            };
            if let Err(error) = self.once(&page, slots).await {
                debug!("a page of recall vectors failed: {error:#}");
                let mut any = false;
                for key in &page {
                    any |= self.once(slice::from_ref(key), slots).await.is_ok();
                }
                if !any {
                    warn!("the recall vector scan gave up: {error:#}");
                    return Ok(pages);
                }
            }
            after = Some(*last);
            pages += 1;
        }
    }

    /// One try, holding a slot.
    async fn once(&self, keys: &[MessageId], slots: &Semaphore) -> Result<()> {
        let _slot = slots.acquire().await?;
        self.embed(keys).await
    }

    /// One try at the vectors of what of `keys` has none from this model.
    async fn embed(&self, keys: &[MessageId]) -> Result<()> {
        let model = &self.embedder.model;
        let mut conn = self.pool.acquire().await?;
        let texts = vectors::to_embed(&mut conn, model, keys).await?;
        drop(conn);
        if texts.is_empty() {
            return Ok(());
        }
        let cut: Vec<String> = texts
            .iter()
            .map(|(_, _, text)| text.chars().take(MOST_CHARS).collect())
            .collect();
        let inputs: Vec<&str> = cut.iter().map(String::as_str).collect();
        let embedded = self.embedder.embed(&inputs).await?;
        let written: Vec<Of<Vec<f32>>> = texts
            .into_iter()
            .zip(embedded)
            .map(|((key, conversation, _), vector)| (key, conversation, vector))
            .collect();
        let mut conn = self.pool.acquire().await?;
        vectors::write(&mut conn, model, &written, Utc::now()).await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests;
