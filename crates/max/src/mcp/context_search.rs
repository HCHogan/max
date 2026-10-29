//! `context_search`: where in this conversation's history the query's
//! terms are, among its rows (with their pictures' and stickers' captions)
//! and its summaries, and what there is near it by meaning; each result
//! says how `context_read` reads it. A term is found as written, ignoring
//! case. See "召回".

use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::hash::Hash;
use std::time::Duration;

use chrono::{DateTime, FixedOffset, NaiveDate, NaiveTime, TimeZone, Utc};
use max_core::ids::{MessageId, SummaryId};
use max_core::project::span;
use max_core::render::{Render, moment};
use max_db::recall::{self, Near, Query};
use max_db::{PgConnection, ledger, summaries};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::Semaphore;
use tokio::time::timeout;
use tracing::debug;

use super::{Context, Failure, arguments};
use crate::conversation::project::people;

const DEFAULT: usize = 10;
const MOST: usize = 30;
const MOST_TERMS: usize = 8;
const TERM_CHARS: usize = 50;
/// Rows a message's result reads on each side of it.
const AROUND: u8 = 10;
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

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Args {
    query: String,
    limit: Option<usize>,
    from: Option<String>,
    to: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
enum Kind {
    Message,
    Summary,
}

/// A result, as the program gets it, and what it is ranked by.
#[derive(Debug, Serialize)]
struct Hit {
    kind: Kind,
    #[serde(rename = "ref")]
    handle: String,
    time: String,
    text: String,
    /// `context_read`'s arguments.
    read: Value,
    /// From 0 to 1: the share of the terms it has, or how near it is by
    /// meaning, whichever is higher.
    #[serde(skip)]
    score: f32,
    #[serde(skip)]
    at: DateTime<Utc>,
    /// Hits with the same key are one: a row's content, so a message
    /// repeated down the chat shows once; a summary's handle.
    #[serde(skip)]
    key: String,
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

pub async fn run(context: &Context, args: Value) -> Result<Value, Failure> {
    let Args {
        query,
        limit,
        from,
        to,
    } = arguments("context_search", args)?;
    let terms = terms(&query)?;
    let limit = limit.unwrap_or(DEFAULT).clamp(1, MOST);
    let (from, until) = window(from.as_deref(), to.as_deref(), context.services.offset)?;
    let patterns: Vec<String> = terms.iter().map(|term| pattern(term)).collect();
    let meaning = meaning(context, &query).await;

    let _slot = SLOTS.acquire().await;
    let mut conn = context.services.pool.acquire().await?;
    // All of the conversation: /clear --all hides rows from the context,
    // not from a search.
    let query = Query {
        conversation: context.place.conversation,
        patterns: &patterns,
        from,
        until,
        // Room for the copies of one message that count as one.
        limit: i64::try_from(limit * 3).unwrap_or(i64::MAX),
    };
    let meaning = meaning.as_ref();
    let mut hits = row_hits(&mut conn, context, &query, &terms, meaning).await?;
    let query = Query {
        limit: i64::try_from(limit).unwrap_or(i64::MAX),
        ..query
    };
    hits.extend(summary_hits(&mut conn, context, &query, &terms, meaning).await?);
    Ok(json!({ "results": choose(hits, limit) }))
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
            debug!("context_search goes by the words alone: {error}");
            None
        }
        Err(_) => {
            debug!("context_search goes by the words alone: no vector in time");
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
            kind: Kind::Message,
            handle: format!("#{}", message.id),
            time: moment(message.at, context.services.offset),
            text: format!("{name}：{}", snippet(&body, &chosen(terms, &found.has))),
            read: json!({ "id": message.id.0, "before": AROUND, "after": AROUND }),
            score: found.score,
            at: message.at,
            key: body,
        });
    }
    Ok(hits)
}

/// The summaries the terms are in, or near the query by meaning: the
/// title, and a stretch of the fullest level the terms are in, or of the
/// full one.
async fn summary_hits(
    conn: &mut PgConnection,
    context: &Context,
    query: &Query<'_>,
    terms: &[String],
    meaning: Option<&Meaning<'_>>,
) -> Result<Vec<Hit>, Failure> {
    let words = recall::summaries(conn, query).await?;
    let near = match meaning {
        Some(meaning) => {
            recall::near_summaries(conn, query, meaning.model, &meaning.vector).await?
        }
        None => Vec::new(),
    };
    let found = merged(words, near, terms);
    let ids: Vec<SummaryId> = found.keys().copied().collect();
    let mut hits = Vec::new();
    for (id, summary) in summaries::picked(conn, query.conversation, &ids).await? {
        let Some(found) = found.get(&id) else {
            continue;
        };
        let words = chosen(terms, &found.has);
        let levels = [
            Some(&summary.full),
            summary.brief.as_ref(),
            summary.line.as_ref(),
        ];
        let level = levels
            .into_iter()
            .flatten()
            .find(|level| words.iter().any(|word| find(&fold(level), word).is_some()))
            .unwrap_or(&summary.full);
        let text = match summary.title.as_str() {
            "" => snippet(level, &words),
            title => format!("{title}：{}", snippet(level, &words)),
        };
        let handle = format!("summary#{id}");
        hits.push(Hit {
            kind: Kind::Summary,
            time: span(
                summary.started_at,
                summary.ended_at,
                context.services.offset,
            ),
            text,
            read: json!({ "summary": id.0 }),
            score: found.score,
            at: summary.ended_at,
            key: handle.clone(),
            handle,
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
        return Err(Failure::new(
            "bad_arguments",
            "context_search 的 query 是空的",
        ));
    }
    if terms.len() > MOST_TERMS {
        return Err(Failure::new(
            "bad_arguments",
            format!("关键词最多 {MOST_TERMS} 个"),
        ));
    }
    Ok(terms)
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

/// From when, and until when, either open.
type Span = (Option<DateTime<Utc>>, Option<DateTime<Utc>>);

/// The days `from` to `to`, local and both whole, as instants: from the
/// first's midnight to the midnight after the last.
fn window(from: Option<&str>, to: Option<&str>, offset: FixedOffset) -> Result<Span, Failure> {
    let day = |text: &str| {
        NaiveDate::parse_from_str(text.trim(), "%Y-%m-%d").map_err(|_| {
            Failure::new(
                "bad_arguments",
                format!("日期要写成 YYYY-MM-DD，不是 {text:?}"),
            )
        })
    };
    let midnight = |date: NaiveDate| {
        offset
            .from_local_datetime(&date.and_time(NaiveTime::MIN))
            .single()
            .map(|at| at.to_utc())
    };
    let from = from.map(day).transpose()?;
    let to = to.map(day).transpose()?;
    if let (Some(from), Some(to)) = (from, to)
        && from > to
    {
        return Err(Failure::new("bad_arguments", "from 在 to 之后"));
    }
    Ok((
        from.and_then(midnight),
        to.and_then(|to| to.succ_opt()).and_then(midnight),
    ))
}

/// Best first: the larger share of the terms, then the newer.
fn rank(a: &Hit, b: &Hit) -> Ordering {
    b.score.total_cmp(&a.score).then(b.at.cmp(&a.at))
}

/// The best `limit` hits, one for each key. No kind takes more than two
/// thirds of them while another has hits left; then the rest by rank.
fn choose(mut hits: Vec<Hit>, limit: usize) -> Vec<Hit> {
    hits.sort_by(rank);
    let mut keys = HashSet::new();
    hits.retain(|hit| keys.insert(hit.key.clone()));
    let quota = (limit * 2).div_ceil(3);
    let mut taken: HashMap<Kind, usize> = HashMap::new();
    let mut chosen = Vec::new();
    let mut rest = Vec::new();
    for hit in hits {
        let count = taken.entry(hit.kind).or_default();
        if chosen.len() < limit && *count < quota {
            *count += 1;
            chosen.push(hit);
        } else {
            rest.push(hit);
        }
    }
    let room = limit - chosen.len();
    chosen.extend(rest.into_iter().take(room));
    chosen.sort_by(rank);
    chosen
}

#[cfg(test)]
mod tests;
