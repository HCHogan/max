//! The embedding worker: a vector of each sticker's caption, for the
//! sticker library that `find_stickers` searches. The caption worker hands
//! it the captions it writes; its scan finds the rest, and all of them
//! again after a change of model. See "发图".

use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use color_eyre::eyre::Result;
use max_db::{PgPool, embeddings};

use crate::embedding::Embedder;
use crate::worker::{Attempt, Derivation, Policy, Wait};

pub const POLICY: Policy = Policy {
    name: "embedding",
    concurrent: 2,
    // The client's own limit is 30 seconds.
    timeout: Duration::from_secs(45),
    // The way to the embedding service drops packets in the evenings.
    retries: &[Duration::from_secs(10), Duration::from_secs(60)],
    // What was given up on is tried again an hour later.
    rescan: Some(Duration::from_secs(3600)),
};

pub struct Stickers {
    pub pool: PgPool,
    pub embedder: Arc<Embedder>,
}

impl Derivation for Stickers {
    /// The file of a sticker caption just written.
    type Input = String;
    type Unit = String;

    fn on_input(&self, sha256: String) -> Vec<(String, Wait)> {
        vec![(sha256, Wait::Now)]
    }

    async fn scan(&self) -> Result<Vec<String>> {
        let mut conn = self.pool.acquire().await?;
        Ok(embeddings::unembedded(&mut conn, &self.embedder.model).await?)
    }

    async fn run(&self, sha256: &String, _: Attempt) -> Result<()> {
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
