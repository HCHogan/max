//! `context_read`: in full, a page at a time, what the context shows only
//! in part: a row's whole line, the rows around one, or a summary. The
//! context shows an over-long row's start only (see "后续输入"), and old
//! summaries a line or nothing (see "衰减"); `context_search` points here.

use std::collections::BTreeSet;

use max_core::ids::{MessageId, SummaryId};
use max_core::message::Message;
use max_core::project::{self, span};
use max_core::render::Render;
use max_db::{ledger, summaries};
use serde::Deserialize;
use serde_json::{Value, json};

use super::{Context, Failure, arguments};
use crate::conversation::project::{delivery_mark, joined, people, roster_lines, shown_line};
use crate::tokens;

/// The most rows read before, and after, the one asked for.
const MOST_AROUND: u8 = 50;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Args {
    id: Option<i64>,
    summary: Option<i64>,
    before: Option<u8>,
    after: Option<u8>,
    page: Option<usize>,
}

pub async fn run(context: &Context, args: Value) -> Result<Value, Failure> {
    let args: Args = arguments("context_read", args)?;
    let around = (args.before.unwrap_or(0), args.after.unwrap_or(0));
    let (what, pages) = match (args.id, args.summary) {
        (Some(id), None) if around == (0, 0) => (format!("#{id}"), row(context, id).await?),
        (Some(id), None) => {
            let (before, after) = (around.0.min(MOST_AROUND), around.1.min(MOST_AROUND));
            let pages = rows(context, id, before, after).await?;
            (format!("#{id} 前后"), pages)
        }
        (None, Some(id)) if around == (0, 0) => {
            (format!("summary#{id}"), summary(context, id).await?)
        }
        (None, Some(_)) => {
            return Err(Failure::new(
                "bad_arguments",
                "before、after 只能和 id 一起用",
            ));
        }
        _ => {
            return Err(Failure::new(
                "bad_arguments",
                "context_read 要 id 或者 summary，二选一",
            ));
        }
    };
    let page = args.page.unwrap_or(1);
    let Some(text) = page.checked_sub(1).and_then(|index| pages.get(index)) else {
        return Err(Failure::new(
            "no_page",
            format!("{what} 只有 {} 页", pages.len()),
        ));
    };
    Ok(json!({ "text": text, "page": page, "pages": pages.len() }))
}

fn not_found(id: i64) -> Failure {
    Failure::new("not_found", format!("这里没有 #{id} 这条消息"))
}

/// One row's whole line, cut evenly into pages.
async fn row(context: &Context, id: i64) -> Result<Vec<String>, Failure> {
    let mut conn = context.pool.acquire().await?;
    let Some(row) = ledger::row(&mut conn, context.place.conversation, MessageId(id)).await? else {
        return Err(not_found(id));
    };
    let people = people(&mut conn, std::iter::once(&row.message), &context.place).await?;
    let render = Render {
        people: &people,
        offset: context.offset,
    };
    let line = render.line(&row.message, delivery_mark(&row));
    Ok(pages(&line, context.page_tokens))
}

/// The row and those around it, as the tail shows them: a line each,
/// over-long ones cut short, a date line first. Pages end between lines.
async fn rows(context: &Context, id: i64, before: u8, after: u8) -> Result<Vec<String>, Failure> {
    let mut conn = context.pool.acquire().await?;
    let conversation = context.place.conversation;
    let ids = ledger::around(
        &mut conn,
        conversation,
        MessageId(id),
        before.into(),
        after.into(),
    )
    .await?;
    if !ids.contains(&MessageId(id)) {
        return Err(not_found(id));
    }
    let rows = ledger::picked(&mut conn, conversation, &ids).await?;
    let people = people(
        &mut conn,
        rows.iter().map(|row| &row.message),
        &context.place,
    )
    .await?;
    let render = Render {
        people: &people,
        offset: context.offset,
    };
    let lines: Vec<(&Message, String)> = rows
        .iter()
        .map(|row| {
            let mark = delivery_mark(row);
            let line = shown_line(&render, &row.message, mark, context.page_tokens);
            (&row.message, line)
        })
        .collect();
    Ok(packed(&joined(&render, &lines, None), context.page_tokens))
}

/// A summary in full, the stretch of the timeline it covers, and who the
/// people it mentions are.
async fn summary(context: &Context, id: i64) -> Result<Vec<String>, Failure> {
    let mut conn = context.pool.acquire().await?;
    let conversation = context.place.conversation;
    let found = summaries::picked(&mut conn, conversation, &[SummaryId(id)]).await?;
    let Some((id, summary)) = found.into_iter().next() else {
        return Err(Failure::new("not_found", format!("这里没有 summary#{id}")));
    };
    let span = span(summary.started_at, summary.ended_at, context.offset);
    let mut text = format!("[summary#{id} {span}]");
    if !summary.title.is_empty() {
        text = format!("{text} {}", summary.title);
    }
    text = format!(
        "{text}\n{}\n（总结的是 #{} 到 #{}）",
        summary.full.trim(),
        summary.first,
        summary.last
    );
    let named: BTreeSet<_> = project::mentioned(&text);
    let roster = roster_lines(&mut conn, &context.place, &named, project::roster_line).await?;
    if !roster.is_empty() {
        text = format!("{text}\n\n[上下文里的人]\n{}", roster.join("\n"));
    }
    Ok(pages(&text, context.page_tokens))
}

/// `text` in pages of at most `most` tokens, cut evenly by characters.
fn pages(text: &str, most: u32) -> Vec<String> {
    let chars: Vec<char> = text.chars().collect();
    if chars.is_empty() {
        return vec![String::new()];
    }
    let most = most.max(1);
    let mut count = tokens::count(text).div_ceil(most).max(1) as usize;
    loop {
        let size = chars.len().div_ceil(count);
        let pages: Vec<String> = chars.chunks(size).map(String::from_iter).collect();
        if size == 1 || pages.iter().all(|page| tokens::count(page) <= most) {
            return pages;
        }
        count += count.div_ceil(10);
    }
}

/// `text` in pages of whole lines, at most `most` tokens each unless a
/// line alone is more.
fn packed(text: &str, most: u32) -> Vec<String> {
    let mut pages = Vec::new();
    let mut page = String::new();
    let mut size = 0;
    for line in text.lines() {
        let cost = tokens::count(line) + 1;
        if !page.is_empty() && size + cost > most {
            pages.push(std::mem::take(&mut page).trim_end().to_owned());
            size = 0;
        }
        page.push_str(line);
        page.push('\n');
        size += cost;
    }
    pages.push(page.trim_end().to_owned());
    pages
}

#[cfg(test)]
mod tests;
