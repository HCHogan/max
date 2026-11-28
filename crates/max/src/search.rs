//! Web search, for the `web_search` tool: Exa's REST API, with the key on
//! the host. See "Web search" in docs/design/tools.md.

use std::fmt;
use std::time::Duration;

use reqwest::{Client, StatusCode};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::sync::Semaphore;
use tracing::warn;

/// Exa's search endpoint.
pub const EXA: &str = "https://api.exa.ai/search";
/// Searches at once, from every conversation.
const AT_ONCE: usize = 4;
/// What the model sees of a result, in characters. Most summaries are as
/// long as they may be, and a program that searches several things at
/// once gets them all in one result, of which `run_code` shows
/// [`SHOWN_BYTES`](max_core::limits::SHOWN_BYTES).
const TITLE: usize = 200;
pub(crate) const SNIPPET: usize = 400;

pub struct Search {
    http: Client,
    url: String,
    key: String,
    slots: Semaphore,
}

/// Without the key.
impl fmt::Debug for Search {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Search")
            .field("url", &self.url)
            .finish_non_exhaustive()
    }
}

/// A result, as the program gets it.
#[derive(Debug, PartialEq, Eq, Serialize, JsonSchema)]
pub struct Found {
    /// The page's title.
    pub title: String,
    /// Its address.
    pub url: String,
    /// An excerpt of it.
    pub snippet: String,
    /// The day it was published, if Exa knows.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub published: Option<String>,
}

/// Why a search gave nothing.
#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum Error {
    /// Exa says too many, too fast.
    #[error("searching too fast: wait a while and search again")]
    RateLimited,
    /// Exa turned the query down.
    #[error("the search service doesn't take this query: {0}")]
    BadQuery(String),
    /// Exa is down or out of reach, or the key is wrong.
    #[error("the search service can't be used right now: {0}")]
    Unavailable(String),
}

#[derive(Deserialize)]
struct Answer {
    results: Vec<Exa>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Exa {
    #[serde(default)]
    title: Option<String>,
    url: String,
    #[serde(default)]
    published_date: Option<String>,
    #[serde(default)]
    highlights: Vec<String>,
    #[serde(default)]
    text: Option<String>,
}

impl Search {
    /// Searches through `url`: Exa's, or a test's.
    ///
    /// # Errors
    ///
    /// If the HTTP client can't be made.
    pub fn new(url: &str, key: String) -> reqwest::Result<Self> {
        let http = Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .build()?;
        Ok(Self {
            http,
            url: url.to_owned(),
            key,
            slots: Semaphore::new(AT_ONCE),
        })
    }

    /// The first `limit` results for `query`.
    ///
    /// # Errors
    ///
    /// [`Error`], which says why Exa gave nothing.
    pub async fn search(&self, query: &str, limit: u8) -> Result<Vec<Found>, Error> {
        let _slot = self.slots.acquire().await;
        let body = json!({
            "query": query,
            "numResults": limit,
            "type": "auto",
            "contents": { "highlights": true },
        });
        let unavailable = |error: reqwest::Error| Error::Unavailable(error.to_string());
        let response = self
            .http
            .post(&self.url)
            .header("x-api-key", &self.key)
            .json(&body)
            .send()
            .await
            .map_err(unavailable)?;
        let status = response.status();
        if !status.is_success() {
            let why: String = response
                .text()
                .await
                .unwrap_or_default()
                .chars()
                .take(200)
                .collect();
            return Err(match status {
                StatusCode::TOO_MANY_REQUESTS => Error::RateLimited,
                StatusCode::BAD_REQUEST | StatusCode::UNPROCESSABLE_ENTITY => Error::BadQuery(why),
                _ => {
                    warn!(%status, "Exa refused a search: {why}");
                    Error::Unavailable(format!("HTTP {}", status.as_u16()))
                }
            });
        }
        let answer: Answer = response.json().await.map_err(unavailable)?;
        Ok(answer
            .results
            .into_iter()
            .take(usize::from(limit))
            .map(found)
            .collect())
    }
}

fn found(exa: Exa) -> Found {
    let snippet = if exa.highlights.is_empty() {
        exa.text.unwrap_or_default()
    } else {
        exa.highlights.join("\n")
    };
    Found {
        title: cut(exa.title.unwrap_or_default().trim(), TITLE),
        url: exa.url,
        snippet: cut(snippet.trim(), SNIPPET),
        published: exa
            .published_date
            .and_then(|date| date.get(..10).map(str::to_owned)),
    }
}

fn cut(text: &str, most: usize) -> String {
    match text.char_indices().nth(most) {
        Some((end, _)) => format!("{}…", &text[..end]),
        None => text.to_owned(),
    }
}
