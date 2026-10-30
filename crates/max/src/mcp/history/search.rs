//! `history` with a query: where in this conversation's history its terms
//! are, among its rows (with their pictures' and stickers' captions), and
//! what there is near it by meaning, under the read's filters; each result
//! says how `history` reads it in context. A term is found as written,
//! ignoring case. See "召回".

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::hash::Hash;
use std::time::Duration;

use chrono::{DateTime, Utc};
use max_core::ids::MessageId;
use max_core::render::{Render, moment};
use max_db::recall::{self, Near, Query};
use max_db::{PgConnection, ledger};
use schemars::JsonSchema;
use serde::Serialize;
use tokio::sync::Semaphore;
use tokio::time::timeout;
use tracing::debug;

use super::Filters;
use crate::conversation::project::people;
use crate::mcp::{Context, Failure};

pub(super) const DEFAULT: usize = 10;
pub(super) const MOST: usize = 30;
pub(super) const MOST_TERMS: usize = 8;
const TERM_CHARS: usize = 50;
/// Characters of a result's text, around its first hit when longer.
const SNIPPET: usize = 160;
/// Of those, how many come before the hit.
const LEAD: usize = 40;
/// How long the query's vector is waited for; without it, the search goes
/// by the words alone.
const MEANING_WAIT: Duration = Duration::from_secs(5);
/// The least cosine similarity of what is found by meaning alone: a
/// guess, still to be tuned on real searches.
const NEAR: f32 = 0.5;

/// Searches at once, from every conversation: one with a short term reads
/// the whole conversation.
static SLOTS: Semaphore = Semaphore::const_new(4);

/// A result, as the program gets it, and what it is ranked by.
#[derive(Debug, Serialize, JsonSchema)]
pub struct Hit {
    #[serde(rename = "ref")]
    handle: String,
    time: String,
    text: String,
    read: Around,
    /// From 0 to 1: the share of the terms it has, or how near it is by
    /// meaning, whichever is higher.
    #[serde(skip)]
    score: f32,
    #[serde(skip)]
    at: DateTime<Utc>,
    /// Hits with the same key are one: a row's content, so a message
    /// repeated down the chat shows once.
    #[serde(skip)]
    key: String,
}

/// `history`'s arguments that read a row in context.
#[derive(Debug, Serialize, JsonSchema)]
pub struct Around {
    around: i64,
}

/// The query's vector, and the model whose vectors it is compared with.
struct Meaning<'a> {
    model: &'a str,
    vector: Vec<f32>,
}

/// A candidate by the words, by meaning, or both: the terms it has, and
/// the higher of its two scores.
#[derive(Default)]
struct Candidate {
    has: Vec<usize>,
    score: f32,
}

/// The best `limit` results for `query`, ten by default.
pub(super) async fn found(
    context: &Context,
    query: &str,
    filters: &Filters,
    limit: Option<usize>,
) -> Result<Vec<Hit>, Failure> {
    let terms = terms(query)?;
    let limit = limit.unwrap_or(DEFAULT).min(MOST);
    let patterns: Vec<String> = terms.iter().map(|term| pattern(term)).collect();
    let meaning = meaning(context, query).await;

    let _slot = SLOTS.acquire().await;
    let mut conn = context.services.pool.acquire().await?;
    // All of the conversation: /clear --all hides rows from the context,
    // not from a search.
    let query = Query {
        conversation: context.place.conversation,
        patterns: &patterns,
        from: filters.from,
        until: filters.until,
        sender: filters.sender.as_deref(),
        // Room for the copies of one message that count as one.
        limit: i64::try_from(limit * 3).unwrap_or(i64::MAX),
    };
    let meaning = meaning.as_ref();
    let hits = row_hits(&mut conn, context, &query, &terms, meaning).await?;
    Ok(choose(hits, limit))
}

/// The query's vector, when there is an embedding model and it answers in
/// time.
async fn meaning<'a>(context: &'a Context, query: &str) -> Option<Meaning<'a>> {
    let embedder = context.services.embedder.as_ref()?;
    match timeout(MEANING_WAIT, embedder.one(query)).await {
        Ok(Ok(vector)) => Some(Meaning {
            model: &embedder.model,
            vector,
        }),
        Ok(Err(error)) => {
            debug!("history searches by the words alone: {error}");
            None
        }
        Err(_) => {
            debug!("history searches by the words alone: no vector in time");
            None
        }
    }
}

/// The candidates by the words and by meaning as one. By the words, a
/// candidate scores the share of the terms it has; by meaning, its
/// similarity, if it is near enough.
fn merged<T: Eq + Hash>(
    words: Vec<(T, Vec<usize>)>,
    near: Vec<Near<T>>,
    terms: &[String],
) -> HashMap<T, Candidate> {
    let mut candidates = HashMap::new();
    for (id, has) in words {
        let score = has.len() as f32 / terms.len().max(1) as f32;
        candidates.insert(id, Candidate { has, score });
    }
    for (id, similarity) in near {
        if similarity >= NEAR {
            let candidate = candidates.entry(id).or_insert_with(Candidate::default);
            candidate.score = candidate.score.max(similarity);
        }
    }
    candidates
}

/// The rows the terms are in, or near the query by meaning, as their lines
/// show them, captions and all.
async fn row_hits(
    conn: &mut PgConnection,
    context: &Context,
    query: &Query<'_>,
    terms: &[String],
    meaning: Option<&Meaning<'_>>,
) -> Result<Vec<Hit>, Failure> {
    let words = recall::messages(conn, query).await?;
    let near = match meaning {
        Some(meaning) => recall::near_messages(conn, query, meaning.model, &meaning.vector).await?,
        None => Vec::new(),
    };
    let found = merged(words, near, terms);
    let ids: Vec<MessageId> = found.keys().copied().collect();
    let rows = ledger::picked(conn, query.conversation, &ids).await?;
    let people = people(conn, rows.iter().map(|row| &row.message), &context.place).await?;
    let render = Render {
        people: &people,
        offset: context.services.offset,
    };
    let mut hits = Vec::new();
    for row in &rows {
        let message = &row.message;
        let Some(found) = found.get(&message.id) else {
            continue;
        };
        let body = render.body(message);
        let name = message.sender.name.replace(['\n', '\r'], " ");
        hits.push(Hit {
            handle: format!("#{}", message.id),
            time: moment(message.at, context.services.offset),
            text: format!("{name}：{}", snippet(&body, &chosen(terms, &found.has))),
            read: Around {
                around: message.id.0,
            },
            score: found.score,
            at: message.at,
            key: body,
        });
    }
    Ok(hits)
}

/// The query's terms, lowercased as the database does: words between
/// spaces, each once.
fn terms(query: &str) -> Result<Vec<String>, Failure> {
    let mut terms: Vec<String> = Vec::new();
    for word in query.split_whitespace() {
        let word: String = fold(word).into_iter().collect();
        if word.chars().count() > TERM_CHARS {
            return Err(Failure::new(
                "bad_arguments",
                format!("关键词太长了，一个最多 {TERM_CHARS} 个字"),
            ));
        }
        if !terms.contains(&word) {
            terms.push(word);
        }
    }
    if terms.is_empty() {
        return Err(Failure::new("bad_arguments", "history 的 query 是空的"));
    }
    if terms.len() > MOST_TERMS {
        return Err(Failure::new(
            "bad_arguments",
            format!("关键词最多 {MOST_TERMS} 个"),
        ));
    }
    Ok(terms)
}

/// The pattern for a sender's name that has `who` in it.
pub(super) fn sender(who: &str) -> Result<String, Failure> {
    let who: String = fold(who.trim()).into_iter().collect();
    if who.is_empty() || who.chars().count() > TERM_CHARS {
        return Err(Failure::new(
            "bad_arguments",
            format!("who 是名字里的几个字，最多 {TERM_CHARS} 个"),
        ));
    }
    Ok(pattern(&who))
}

/// `text` lowercased a character at a time, as Postgres's `lower` does, so
/// positions stay put.
fn fold(text: &str) -> Vec<char> {
    text.chars()
        .map(|c| c.to_lowercase().next().unwrap_or(c))
        .collect()
}

/// A LIKE pattern that finds `term` anywhere.
fn pattern(term: &str) -> String {
    let mut out = String::from("%");
    for c in term.chars() {
        if matches!(c, '%' | '_' | '\\') {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('%');
    out
}

/// The terms at `indexes`.
fn chosen<'t>(terms: &'t [String], indexes: &[usize]) -> Vec<&'t str> {
    indexes
        .iter()
        .filter_map(|&index| terms.get(index).map(String::as_str))
        .collect()
}

/// Where `word` (folded) first is in `text` (folded), in characters.
fn find(text: &[char], word: &str) -> Option<usize> {
    let word: Vec<char> = word.chars().collect();
    if word.is_empty() || word.len() > text.len() {
        return None;
    }
    text.windows(word.len())
        .position(|window| window == word.as_slice())
}

/// `text`, or when it is long, [`SNIPPET`] characters of it around the
/// first of `words` in it, with … where it is cut.
fn snippet(text: &str, words: &[&str]) -> String {
    let chars: Vec<char> = text.chars().collect();
    if chars.len() <= SNIPPET {
        return text.to_owned();
    }
    let folded = fold(text);
    let hit = words
        .iter()
        .filter_map(|word| find(&folded, word))
        .min()
        .unwrap_or(0);
    let start = hit.saturating_sub(LEAD).min(chars.len() - SNIPPET);
    let end = start + SNIPPET;
    let mut out = String::new();
    if start > 0 {
        out.push('…');
    }
    out.extend(&chars[start..end]);
    if end < chars.len() {
        out.push('…');
    }
    out
}

/// Best first: the larger share of the terms, then the newer.
fn rank(a: &Hit, b: &Hit) -> Ordering {
    b.score.total_cmp(&a.score).then(b.at.cmp(&a.at))
}

/// The best `limit` hits, one for each key.
fn choose(mut hits: Vec<Hit>, limit: usize) -> Vec<Hit> {
    hits.sort_by(rank);
    let mut keys = HashSet::new();
    hits.retain(|hit| keys.insert(hit.key.clone()));
    hits.truncate(limit);
    hits
}

#[cfg(test)]
mod tests;
