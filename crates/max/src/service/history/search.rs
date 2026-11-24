//! `history` with a query: where in this conversation's history its terms
//! are, among its rows (with their pictures' and stickers' captions), or
//! with `tools: true` among its turns' tool calls, under the read's
//! filters; each result says how `history` reads it. See "Recall".

use std::cmp::Ordering;
use std::collections::HashMap;

use chrono::{DateTime, Utc};
use max_core::ids::MessageId;
use max_core::render::{Render, moment};
use max_db::recall::{self, Query};
use max_db::{PgConnection, ledger, tool_calls};
use schemars::JsonSchema;
use serde::Serialize;
use tokio::sync::Semaphore;

use super::Filters;
use crate::conversation::project::people;
use crate::service::keywords::{self, TERM_CHARS, fold, pattern};
use crate::service::{Context, Failure};

pub(super) const DEFAULT: usize = 10;
pub(super) const MOST: usize = 30;
/// Characters of a result's text, around its first hit when longer.
const SNIPPET: usize = 160;
/// Of those, how many come before the hit.
const LEAD: usize = 40;

/// Searches at once, from every conversation: one with a short term reads
/// the whole conversation.
static SLOTS: Semaphore = Semaphore::const_new(4);

/// A result, as the program gets it, and what it is ranked by.
#[derive(Debug, Serialize, JsonSchema)]
pub(crate) struct Hit {
    #[serde(rename = "ref")]
    handle: String,
    time: String,
    /// A tool call's tool.
    #[serde(skip_serializing_if = "Option::is_none")]
    tool: Option<String>,
    text: String,
    read: Read,
    /// From 0 to 1: the share of the terms it has.
    #[serde(skip)]
    score: f32,
    #[serde(skip)]
    at: DateTime<Utc>,
    /// Hits with the same key are one: a row's content, so a message
    /// repeated down the chat shows once.
    #[serde(skip)]
    key: String,
}

/// `history`'s arguments that read a result: a row in context, or a tool
/// call whole.
#[derive(Debug, Serialize, JsonSchema)]
#[serde(untagged)]
pub(super) enum Read {
    Around { around: i64 },
    Call { call: String },
}

/// The best `limit` results for `query`, ten by default.
pub(super) async fn found(
    context: &Context,
    query: &str,
    filters: &Filters,
    limit: Option<usize>,
) -> Result<Vec<Hit>, Failure> {
    let terms = keywords::terms("history", query)?;
    let limit = limit.unwrap_or(DEFAULT).min(MOST);
    let patterns: Vec<String> = terms.iter().map(|term| pattern(term)).collect();

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
    let hits = row_hits(&mut conn, context, &query, &terms).await?;
    Ok(choose(hits, limit))
}

/// The best `limit` of the conversation's tool calls for `query`, ten by
/// default.
pub(super) async fn calls(
    context: &Context,
    query: &str,
    filters: &Filters,
    limit: Option<usize>,
) -> Result<Vec<Hit>, Failure> {
    let terms = keywords::terms("history", query)?;
    let limit = limit.unwrap_or(DEFAULT).min(MOST);
    let patterns: Vec<String> = terms.iter().map(|term| pattern(term)).collect();

    let _slot = SLOTS.acquire().await;
    let mut conn = context.services.pool.acquire().await?;
    let query = Query {
        conversation: context.place.conversation,
        patterns: &patterns,
        from: filters.from,
        until: filters.until,
        sender: None,
        limit: i64::try_from(limit).unwrap_or(i64::MAX),
    };
    let found = tool_calls::matching(&mut conn, &query).await?;
    let hits = found
        .into_iter()
        .map(|(call, has)| {
            let handle = format!("t#{}.{}", call.turn, call.n);
            let body = format!("{}\n→ {}", call.arguments, call.output);
            Hit {
                time: moment(call.started, context.services.offset),
                tool: Some(call.name),
                text: snippet(&body, &chosen(&terms, &has)),
                read: Read::Call {
                    call: handle.clone(),
                },
                score: has.len() as f32 / terms.len() as f32,
                at: call.started,
                key: handle.clone(),
                handle,
            }
        })
        .collect();
    Ok(choose(hits, limit))
}

/// The rows the terms are in, as their lines show them, captions and
/// all.
async fn row_hits(
    conn: &mut PgConnection,
    context: &Context,
    query: &Query<'_>,
    terms: &[String],
) -> Result<Vec<Hit>, Failure> {
    let found: HashMap<MessageId, Vec<usize>> =
        recall::messages(conn, query).await?.into_iter().collect();
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
        let Some(has) = found.get(&message.id) else {
            continue;
        };
        let body = render.body(message);
        let name = message.sender.name.replace(['\n', '\r'], " ");
        hits.push(Hit {
            handle: format!("#{}", message.id),
            time: moment(message.at, context.services.offset),
            tool: None,
            text: format!("{name}：{}", snippet(&body, &chosen(terms, has))),
            read: Read::Around {
                around: message.id.get(),
            },
            score: has.len() as f32 / terms.len() as f32,
            at: message.at,
            key: body,
        });
    }
    Ok(hits)
}

/// The pattern for a sender's name that has `who` in it.
pub(super) fn sender(who: &str) -> Result<String, Failure> {
    let who: String = fold(who.trim()).into_iter().collect();
    if who.is_empty() || who.chars().count() > TERM_CHARS {
        return Err(Failure::new(
            "bad_arguments",
            format!("who is a few characters of a name, at most {TERM_CHARS}"),
        ));
    }
    Ok(pattern(&who))
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

/// The best `limit` hits, one for each key. There are a few dozen at
/// most, so the ones kept are looked through rather than keyed by copies
/// of their text.
fn choose(mut hits: Vec<Hit>, limit: usize) -> Vec<Hit> {
    hits.sort_by(rank);
    let mut chosen: Vec<Hit> = Vec::with_capacity(limit.min(hits.len()));
    for hit in hits {
        if chosen.len() == limit {
            break;
        }
        if chosen.iter().all(|kept| kept.key != hit.key) {
            chosen.push(hit);
        }
    }
    chosen
}
