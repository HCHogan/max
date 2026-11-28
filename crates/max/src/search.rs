//! Web search, for the `web_search` tool: Exa's, by the endpoint that
//! takes no key while it answers, then by each key in turn, all on the
//! host. See "Web search" in docs/design/tools.md.

use std::fmt;
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

use reqwest::header::{ACCEPT, RETRY_AFTER};
use reqwest::{Client, Response, StatusCode};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::sync::Semaphore;
use tokio::time::Instant;
use tracing::{debug, warn};

/// Exa's search endpoint, which takes a key.
pub const EXA: &str = "https://api.exa.ai/search";
/// Exa's MCP server, which searches without a key: so many a second and
/// a day from one address, and it doesn't say how many.
pub const EXA_FREE: &str = "https://mcp.exa.ai/mcp";
/// Searches at once, from every conversation.
const AT_ONCE: usize = 4;
/// And of those, without a key: Exa's server allows two a second, and
/// one answers in half a second.
const FREE_AT_ONCE: usize = 1;
/// How long a key that has no credit left, or that Exa doesn't know, is
/// left out before it is tried again: credit comes back when the month
/// turns or it is bought.
const SPENT: Duration = Duration::from_secs(3600);
/// How long a source that says "too many" is left out when it doesn't
/// say for how long: the endpoint without a key, and a key.
const FREE_REST: Duration = Duration::from_secs(60);
const KEY_REST: Duration = Duration::from_secs(1);
/// The longest a source is left out on its own word.
const LONGEST_REST: Duration = Duration::from_secs(24 * 3600);
/// A rest from this long on is worth a line in the log.
const LOGGED_REST: Duration = Duration::from_secs(60);
/// What the model sees of a result, in characters. Most summaries are as
/// long as they may be, and a program that searches several things at
/// once gets them all in one result, of which `run_code` shows
/// [`SHOWN_BYTES`](max_core::limits::SHOWN_BYTES).
const TITLE: usize = 200;
pub(crate) const SNIPPET: usize = 400;
/// What is kept of what a source said when it failed.
const SAID: usize = 200;

/// The ways to search, in the order they are tried.
pub struct Search {
    http: Client,
    sources: Vec<Source>,
    slots: Semaphore,
}

/// One way to search: the endpoint without a key, or a key.
struct Source {
    /// What the log calls it: `free`, `key 1`. Never the key.
    name: String,
    how: How,
    /// Its own searches at once.
    slots: Semaphore,
    /// Until when it is left out: used up, or asked too fast.
    out: Mutex<Option<Instant>>,
}

enum How {
    /// The MCP server at this address, without a key.
    Free(String),
    /// The search endpoint at this address, with this key.
    Key(String, String),
}

/// Why a source didn't answer a search.
enum Failed {
    /// The query's own fault: no other source would take it either.
    Query(String),
    /// Used up, or asked too fast: it is left out this long.
    Out(Duration, Error),
    /// Down, out of reach, or what it said can't be read.
    Down(String),
}

/// Without the keys.
impl fmt::Debug for Search {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let sources: Vec<&str> = self.sources.iter().map(|source| &*source.name).collect();
        f.debug_struct("Search")
            .field("sources", &sources)
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
    /// Exa says too many, too fast, and no other source answered.
    #[error("searching too fast: wait a while and search again")]
    RateLimited,
    /// Exa turned the query down.
    #[error("the search service doesn't take this query: {0}")]
    BadQuery(String),
    /// Exa is down or out of reach, or every source is used up or
    /// refused.
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

/// What Exa's MCP server answers a call with, as much as is read of it.
#[derive(Deserialize)]
struct Rpc {
    result: Option<Called>,
    error: Option<RpcError>,
}

#[derive(Deserialize)]
struct RpcError {
    message: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Called {
    #[serde(default)]
    content: Vec<Content>,
    #[serde(default)]
    is_error: bool,
}

#[derive(Deserialize)]
struct Content {
    #[serde(default)]
    text: String,
}

impl Search {
    /// Searches without a key through `free`, if given, and then with
    /// each of `keys` in order through `keyed`: Exa's addresses, or a
    /// test's.
    ///
    /// # Errors
    ///
    /// If the HTTP client can't be made.
    pub fn new(free: Option<&str>, keyed: &str, keys: Vec<String>) -> reqwest::Result<Self> {
        let http = Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .build()?;
        let source = |name: String, how, at_once| Source {
            name,
            how,
            slots: Semaphore::new(at_once),
            out: Mutex::new(None),
        };
        let free =
            free.map(|url| source("free".to_owned(), How::Free(url.to_owned()), FREE_AT_ONCE));
        let keys = keys.into_iter().enumerate().map(|(n, key)| {
            let how = How::Key(keyed.to_owned(), key);
            source(format!("key {}", n + 1), how, AT_ONCE)
        });
        Ok(Self {
            http,
            sources: free.into_iter().chain(keys).collect(),
            slots: Semaphore::new(AT_ONCE),
        })
    }

    /// The first `limit` results for `query`, from the first source that
    /// has them: one that is used up or fails passes the search on to the
    /// next, and one that said it is used up isn't asked again until it
    /// may have more.
    ///
    /// # Errors
    ///
    /// [`Error`], which says why the last source asked gave nothing.
    pub async fn search(&self, query: &str, limit: u8) -> Result<Vec<Found>, Error> {
        let _slot = self.slots.acquire().await;
        let mut last = None;
        for source in &self.sources {
            // Waited for rather than passed over: a search without a key
            // costs nothing.
            let _own = source.slots.acquire().await;
            if source.is_out() {
                continue;
            }
            let name = &*source.name;
            match source.ask(&self.http, query, limit).await {
                Ok(found) => return Ok(found),
                Err(Failed::Query(why)) => return Err(Error::BadQuery(why)),
                Err(Failed::Out(rest, error)) => {
                    source.rest(rest);
                    if rest >= LOGGED_REST {
                        warn!(
                            source = name,
                            secs = rest.as_secs(),
                            "a search source is out: {error}"
                        );
                    } else {
                        debug!(source = name, "a search source is asked too fast");
                    }
                    last = Some(error);
                }
                Err(Failed::Down(why)) => {
                    warn!(source = name, "a search source failed: {why}");
                    last = Some(Error::Unavailable(why));
                }
            }
        }
        Err(last.unwrap_or_else(|| {
            Error::Unavailable("every way to search is used up for now".to_owned())
        }))
    }
}

impl Source {
    fn is_out(&self) -> bool {
        let out = self.out.lock().unwrap_or_else(PoisonError::into_inner);
        out.is_some_and(|until| Instant::now() < until)
    }

    /// Leaves it out for `rest` from now.
    fn rest(&self, rest: Duration) {
        let mut out = self.out.lock().unwrap_or_else(PoisonError::into_inner);
        *out = Some(Instant::now() + rest);
    }

    async fn ask(&self, http: &Client, query: &str, limit: u8) -> Result<Vec<Found>, Failed> {
        let down = |error: reqwest::Error| Failed::Down(error.to_string());
        match &self.how {
            How::Key(url, key) => {
                let body = json!({
                    "query": query,
                    "numResults": limit,
                    "type": "auto",
                    "contents": { "highlights": true },
                });
                let asked = http.post(url).header("x-api-key", key).json(&body);
                let response = asked.send().await.map_err(down)?;
                let status = response.status();
                if !status.is_success() {
                    let rest = retry_after(&response);
                    let why = said(&response.text().await.unwrap_or_default());
                    let code = format!("HTTP {}", status.as_u16());
                    return Err(match status {
                        StatusCode::TOO_MANY_REQUESTS => {
                            Failed::Out(rest.unwrap_or(KEY_REST), Error::RateLimited)
                        }
                        StatusCode::BAD_REQUEST | StatusCode::UNPROCESSABLE_ENTITY => {
                            Failed::Query(why)
                        }
                        // No credit left, or no such key.
                        StatusCode::PAYMENT_REQUIRED
                        | StatusCode::UNAUTHORIZED
                        | StatusCode::FORBIDDEN => Failed::Out(SPENT, Error::Unavailable(code)),
                        _ => Failed::Down(format!("{code}: {why}")),
                    });
                }
                let answer: Answer = response.json().await.map_err(down)?;
                let results = answer.results.into_iter().take(usize::from(limit));
                Ok(results.map(found).collect())
            }
            How::Free(url) => {
                let body = json!({
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "tools/call",
                    "params": {
                        "name": "web_search_exa",
                        "arguments": { "query": query, "numResults": limit },
                    },
                });
                let asked = http
                    .post(url)
                    .header(ACCEPT, "application/json, text/event-stream")
                    .json(&body);
                let response = asked.send().await.map_err(down)?;
                let status = response.status();
                if status == StatusCode::TOO_MANY_REQUESTS {
                    let rest = retry_after(&response).unwrap_or(FREE_REST);
                    return Err(Failed::Out(rest, Error::RateLimited));
                }
                let text = response.text().await.map_err(down)?;
                if !status.is_success() {
                    return Err(Failed::Down(format!(
                        "HTTP {}: {}",
                        status.as_u16(),
                        said(&text)
                    )));
                }
                // The answer as it is, or as the last event of a stream.
                let mut events = text.lines().filter_map(|line| line.strip_prefix("data:"));
                let answer = events.next_back().unwrap_or(&text);
                let rpc: Rpc = serde_json::from_str(answer)
                    .map_err(|error| Failed::Down(format!("{error}: {}", said(&text))))?;
                let Some(called) = rpc.result else {
                    let why = rpc.error.map(|error| error.message).unwrap_or_default();
                    return Err(Failed::Down(said(&why)));
                };
                let texts: Vec<String> = called.content.into_iter().map(|part| part.text).collect();
                let text = texts.join("\n");
                if called.is_error {
                    return Err(Failed::Down(said(&text)));
                }
                Ok(listed(&text).into_iter().take(usize::from(limit)).collect())
            }
        }
    }
}

/// How long a source asks to be left alone, if it says.
fn retry_after(response: &Response) -> Option<Duration> {
    let seconds = response.headers().get(RETRY_AFTER)?.to_str().ok()?;
    let rest = Duration::from_secs(seconds.trim().parse().ok()?);
    Some(rest.clamp(Duration::from_secs(1), LONGEST_REST))
}

/// The start of what a source said, for an error.
fn said(text: &str) -> String {
    text.trim().chars().take(SAID).collect()
}

/// A field of a result, unless Exa's server wrote that it has none.
fn known(value: &str) -> Option<&str> {
    (value != "N/A").then_some(value)
}

/// The results in what Exa's MCP server says of a search, which is text:
/// for each, a line each of `Title:`, `URL:`, `Published:` and `Author:`,
/// then `Highlights:` and its excerpts, or `Text:`; a line `---` between
/// two. A result starts where those four lines do, since an excerpt may
/// have a `---` of its own. Text without any, as when nothing was found,
/// has no results.
fn listed(text: &str) -> Vec<Found> {
    const HEAD: [&str; 4] = ["Title: ", "URL: ", "Published: ", "Author: "];
    let lines: Vec<&str> = text.lines().collect();
    let starts_at = |at: usize| {
        let mut head = HEAD.iter().enumerate();
        head.all(|(n, key)| lines.get(at + n).is_some_and(|line| line.starts_with(key)))
    };
    let starts: Vec<usize> = (0..lines.len()).filter(|&at| starts_at(at)).collect();
    let result = |(n, &start): (usize, &usize)| {
        let end = starts.get(n + 1).copied().unwrap_or(lines.len());
        let field = |n: usize| lines[start + n][HEAD[n].len()..].trim();
        let excerpt = lines[start + HEAD.len()..end].join("\n");
        let excerpt = excerpt.trim();
        let excerpt = excerpt.strip_suffix("---").unwrap_or(excerpt);
        let excerpt = ["Highlights:", "Text:"]
            .iter()
            .find_map(|label| excerpt.strip_prefix(label))
            .unwrap_or(excerpt);
        Found {
            title: cut(known(field(0)).unwrap_or_default(), TITLE),
            url: field(1).to_owned(),
            snippet: cut(excerpt.trim(), SNIPPET),
            published: known(field(2)).and_then(|date| date.get(..10).map(str::to_owned)),
        }
    };
    starts.iter().enumerate().map(result).collect()
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
