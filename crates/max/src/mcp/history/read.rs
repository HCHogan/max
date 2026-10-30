//! `history` without a query: rows in order, as the tail shows them, a
//! page at a time. Around a row, or the row alone in full: the context
//! shows an over-long row's start only (see "后续输入"). Or a stretch of
//! the timeline, a sender's rows in it if asked, from its start on or back
//! from its end, and where to go on.

use max_core::ids::MessageId;
use max_core::message::Message;
use max_core::render::Render;
use max_db::{PgConnection, ledger};
use serde_json::{Value, json};

use super::Filters;
use crate::conversation::project::{delivery_mark, joined, people, shown_line};
use crate::mcp::{Context, Failure};
use crate::tokens;

/// Rows read on each side of the one asked for, unless asked otherwise.
const AROUND: u8 = 10;
/// The most rows read before, and after, the one asked for.
const MOST_AROUND: u8 = 50;
/// Rows of a stretch read at once, unless asked otherwise, and the most.
pub(super) const DEFAULT: usize = 50;
pub(super) const MOST: usize = 100;

/// Where a stretch goes on: after its last row, or before its first.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Next {
    After(MessageId),
    Before(MessageId),
}

/// The row and those around it; or when neither side is asked for, the
/// row alone in full.
pub(super) async fn around(
    context: &Context,
    id: i64,
    (before, after): (Option<u8>, Option<u8>),
    page: Option<usize>,
) -> Result<Value, Failure> {
    let (before, after) = (before.unwrap_or(AROUND), after.unwrap_or(AROUND));
    let pages = if (before, after) == (0, 0) {
        row(context, id).await?
    } else {
        rows(context, id, before.min(MOST_AROUND), after.min(MOST_AROUND)).await?
    };
    paged(&pages, page)
}

/// Up to `limit` rows of the stretch: its first, or with `newest` its
/// last, in order either way; and where to go on, if there are more.
pub(super) async fn stretch(
    context: &Context,
    filters: &Filters,
    newest: bool,
    limit: usize,
) -> Result<(Vec<String>, Option<Next>), Failure> {
    let mut conn = context.services.pool.acquire().await?;
    let mut ids = ledger::stretch(
        &mut conn,
        context.place.conversation,
        (filters.from, filters.until),
        filters.sender.as_deref(),
        newest,
        i64::try_from(limit + 1).unwrap_or(i64::MAX),
    )
    .await?;
    let more = ids.len() > limit;
    ids.truncate(limit);
    if newest {
        ids.reverse();
    }
    let (Some(&first), Some(&last)) = (ids.first(), ids.last()) else {
        return Ok((vec!["（没有这样的消息）".to_owned()], None));
    };
    let next = more.then_some(if newest {
        Next::Before(first)
    } else {
        Next::After(last)
    });
    Ok((lines(&mut conn, context, &ids).await?, next))
}

/// The page asked for, the first by default, and how many there are.
pub(super) fn paged(pages: &[String], page: Option<usize>) -> Result<Value, Failure> {
    let page = page.unwrap_or(1);
    let Some(text) = page.checked_sub(1).and_then(|index| pages.get(index)) else {
        return Err(Failure::new("no_page", format!("只有 {} 页", pages.len())));
    };
    Ok(json!({ "text": text, "page": page, "pages": pages.len() }))
}

fn not_found(id: i64) -> Failure {
    Failure::new("not_found", format!("这里没有 #{id} 这条消息"))
}

/// One row's whole line, cut evenly into pages.
async fn row(context: &Context, id: i64) -> Result<Vec<String>, Failure> {
    let mut conn = context.services.pool.acquire().await?;
    let Some(row) = ledger::row(&mut conn, context.place.conversation, MessageId(id)).await? else {
        return Err(not_found(id));
    };
    let people = people(&mut conn, std::iter::once(&row.message), &context.place).await?;
    let render = Render {
        people: &people,
        offset: context.services.offset,
    };
    let line = render.line(&row.message, delivery_mark(&row));
    Ok(pages(&line, context.page_tokens))
}

/// The row and those around it, as the tail shows them.
async fn rows(context: &Context, id: i64, before: u8, after: u8) -> Result<Vec<String>, Failure> {
    let mut conn = context.services.pool.acquire().await?;
    let ids = ledger::around(
        &mut conn,
        context.place.conversation,
        MessageId(id),
        before.into(),
        after.into(),
    )
    .await?;
    if !ids.contains(&MessageId(id)) {
        return Err(not_found(id));
    }
    Ok(lines(&mut conn, context, &ids).await?)
}

/// The rows, as the tail shows them: a line each, over-long ones cut
/// short, a date line first. Pages end between lines.
async fn lines(
    conn: &mut PgConnection,
    context: &Context,
    ids: &[MessageId],
) -> sqlx::Result<Vec<String>> {
    let rows = ledger::picked(conn, context.place.conversation, ids).await?;
    let people = people(conn, rows.iter().map(|row| &row.message), &context.place).await?;
    let render = Render {
        people: &people,
        offset: context.services.offset,
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
