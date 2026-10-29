//! Web search, for the `web_search` tool: Exa's REST API, with the key on
//! the host. See "网页搜索" in docs/rust-rewrite.md.

use std::fmt;
use std::time::Duration;

use reqwest::{Client, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::sync::Semaphore;
use tracing::warn;

pub const EXA: &str = "https://api.exa.ai/search";
/// Searches at once, from every conversation.
const AT_ONCE: usize = 4;
/// What the model sees of a result, in characters.
const TITLE: usize = 200;
const SNIPPET: usize = 800;

pub struct Search {
    http: Client,
    url: String,
    key: String,
    slots: Semaphore,
}

/// A result, as the program gets it.
#[derive(Debug, PartialEq, Eq, Serialize)]
pub struct Found {
    pub title: String,
    pub url: String,
    pub snippet: String,
    /// The day it was published, if Exa knows.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub published: Option<String>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    /// Exa says too many, too fast.
    RateLimited,
    /// Exa turned the query down.
    BadQuery(String),
    /// Exa is down or out of reach, or the key is wrong.
    Unavailable(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::RateLimited => write!(f, "搜得太快了，等一会儿再搜。"),
            Self::BadQuery(why) => write!(f, "搜索服务不收这个查询：{why}"),
            Self::Unavailable(why) => write!(f, "搜索服务暂时用不了：{why}"),
        }
    }
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

#[cfg(test)]
mod tests;
