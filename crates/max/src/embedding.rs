//! Embeddings, for search by meaning: an OpenAI-compatible
//! `/v1/embeddings`, such as Ollama's with bge-m3. The sticker library's
//! vectors and `find_stickers`' queries come from here. See "发图".

use std::fmt;
use std::time::Duration;

use max_db::embeddings::DIMENSIONS;
use reqwest::Client;
use serde::Deserialize;
use serde_json::json;

/// For one request, answer included: the vectors are small.
const TIMEOUT: Duration = Duration::from_secs(30);

pub struct Embedder {
    http: Client,
    url: String,
    key: Option<String>,
    /// Sent with each request, and kept with each vector.
    pub model: String,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    /// The service is down, out of reach, too slow, or said no.
    Unavailable(String),
    /// It answered with something that isn't a vector of the model's
    /// length for each text.
    Malformed(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unavailable(why) => write!(f, "embedding service unavailable: {why}"),
            Self::Malformed(why) => write!(f, "embedding service answered wrong: {why}"),
        }
    }
}

impl std::error::Error for Error {}

#[derive(Deserialize)]
struct Answer {
    data: Vec<Datum>,
}

#[derive(Deserialize)]
struct Datum {
    index: usize,
    embedding: Vec<f32>,
}

impl Embedder {
    /// Embeds with `model` at `base_url`, which ends in `/v1`.
    pub fn new(base_url: &str, model: String, key: Option<String>) -> reqwest::Result<Self> {
        let http = Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(TIMEOUT)
            .build()?;
        Ok(Self {
            http,
            url: format!("{}/embeddings", base_url.trim_end_matches('/')),
            key,
            model,
        })
    }

    /// A vector of [`DIMENSIONS`] numbers for each text, in order.
    pub async fn embed(&self, texts: &[&str]) -> Result<Vec<Vec<f32>>, Error> {
        let body = json!({ "model": self.model, "input": texts });
        let mut request = self.http.post(&self.url).json(&body);
        if let Some(key) = &self.key {
            request = request.bearer_auth(key);
        }
        let unavailable = |error: reqwest::Error| Error::Unavailable(error.to_string());
        let response = request.send().await.map_err(unavailable)?;
        let status = response.status();
        if !status.is_success() {
            let why: String = response
                .text()
                .await
                .unwrap_or_default()
                .chars()
                .take(200)
                .collect();
            return Err(Error::Unavailable(format!(
                "HTTP {}: {why}",
                status.as_u16()
            )));
        }
        let mut answer: Answer = response
            .json()
            .await
            .map_err(|error| Error::Malformed(error.to_string()))?;
        answer.data.sort_by_key(|datum| datum.index);
        let indices: Vec<usize> = answer.data.iter().map(|datum| datum.index).collect();
        if !indices.iter().copied().eq(0..texts.len()) {
            return Err(Error::Malformed(format!(
                "{} texts, vectors for {indices:?}",
                texts.len()
            )));
        }
        answer
            .data
            .into_iter()
            .map(|datum| {
                let vector = datum.embedding;
                if vector.len() != DIMENSIONS {
                    return Err(Error::Malformed(format!(
                        "{} numbers, not {DIMENSIONS}",
                        vector.len()
                    )));
                }
                if !vector.iter().all(|x| x.is_finite()) {
                    return Err(Error::Malformed("a number that isn't finite".into()));
                }
                Ok(vector)
            })
            .collect()
    }

    /// One text's vector.
    pub async fn one(&self, text: &str) -> Result<Vec<f32>, Error> {
        let mut vectors = self.embed(&[text]).await?;
        vectors
            .pop()
            .ok_or_else(|| Error::Malformed("no vector".into()))
    }
}

#[cfg(test)]
pub mod testing;
#[cfg(test)]
mod tests;
