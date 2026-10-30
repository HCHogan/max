//! `history`: the conversation's history beyond the context, by content,
//! sender and time. With a query it searches (see `search`); without, it
//! reads rows in order (see `read`): around a row, or a stretch of the
//! timeline, a sender's rows in it if asked. A stretch runs from or to a
//! day, a moment or a row, worked out as row ids once, so that a search
//! and a read keep to the same rows. See "召回".

mod read;
mod search;

use chrono::{DateTime, FixedOffset, NaiveDate, NaiveDateTime, NaiveTime, TimeZone, Utc};
use max_core::ids::{ConversationId, MessageId};
use max_db::{PgConnection, ledger};
use serde::Deserialize;
use serde_json::{Map, Value, json};

use super::{Context, Failure, arguments};
use read::Next;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Args {
    query: Option<String>,
    who: Option<String>,
    from: Option<String>,
    to: Option<String>,
    around: Option<i64>,
    before: Option<u8>,
    after: Option<u8>,
    limit: Option<usize>,
    page: Option<usize>,
}

/// What a search or a read of a stretch keeps to.
struct Filters {
    /// A LIKE pattern for the sender's name, lowercased.
    sender: Option<String>,
    /// Rows from `from` and before `until`, by id.
    from: Option<MessageId>,
    until: Option<MessageId>,
}

/// A `from` or a `to`: a row, a moment, or a whole local day, from its
/// midnight to the next.
#[derive(Debug, PartialEq, Eq)]
enum Bound {
    Row(MessageId),
    At(DateTime<Utc>),
    Day(DateTime<Utc>, DateTime<Utc>),
}

pub async fn run(context: &Context, args: Value) -> Result<Value, Failure> {
    let args: Args = arguments("history", args)?;
    let wrong = |message: &str| Err(Failure::new("bad_arguments", message));
    let filtered = args.who.is_some() || args.from.is_some() || args.to.is_some();
    if let Some(id) = args.around {
        if filtered || args.query.is_some() || args.limit.is_some() {
            return wrong("around 不能和 query、who、from、to、limit 一起用");
        }
        return read::around(context, id, (args.before, args.after), args.page).await;
    }
    if args.before.is_some() || args.after.is_some() {
        return wrong("before、after 只能和 around 一起用");
    }
    let filters = filters(context, &args).await?;
    match &args.query {
        Some(_) if args.page.is_some() => wrong("搜的结果不分页，page 只用于读"),
        Some(query) => search::found(context, query, &filters, args.limit).await,
        None if !filtered => wrong("history 要 query、who、from、to、around 里至少一个"),
        None => {
            let limit = args.limit.unwrap_or(read::DEFAULT).clamp(1, read::MOST);
            let newest = args.from.is_none();
            let (pages, next) = read::stretch(context, &filters, newest, limit).await?;
            let mut read = read::paged(&pages, args.page)?;
            if let Some(next) = next {
                read["next"] = next_args(&args, &next);
            }
            Ok(read)
        }
    }
}

/// The filters, with `from` and `to` as rows: a day or a moment starts at
/// its first row; a `to` ends before the first row after it.
async fn filters(context: &Context, args: &Args) -> Result<Filters, Failure> {
    let offset = context.services.offset;
    let from = args.from.as_deref().map(|text| bound(text, offset));
    let to = args.to.as_deref().map(|text| bound(text, offset));
    let sender = args.who.as_deref().map(search::sender).transpose()?;
    let (from, to) = (from.transpose()?, to.transpose()?);
    let mut conn = context.services.pool.acquire().await?;
    let conversation = context.place.conversation;
    let from = match from {
        // Nothing then or after: a stretch with nothing in it.
        Some(bound) => Some(
            first(&mut conn, conversation, bound, false)
                .await?
                .unwrap_or(MessageId(i64::MAX)),
        ),
        None => None,
    };
    let until = match to {
        Some(bound) => first(&mut conn, conversation, bound, true).await?,
        None => None,
    };
    Ok(Filters {
        sender,
        from,
        until,
    })
}

/// `#123`, `YYYY-MM-DD HH:MM` or `YYYY-MM-DD`, local.
fn bound(text: &str, offset: FixedOffset) -> Result<Bound, Failure> {
    let text = text.trim();
    let wrong = || {
        Failure::new(
            "bad_arguments",
            format!("from、to 要写成 YYYY-MM-DD、YYYY-MM-DD HH:MM 或者 #编号，不是 {text:?}"),
        )
    };
    if let Some(id) = text.strip_prefix('#') {
        return id
            .parse()
            .map(|id| Bound::Row(MessageId(id)))
            .map_err(|_| wrong());
    }
    let local = |at: NaiveDateTime| {
        offset
            .from_local_datetime(&at)
            .single()
            .map(|at| at.to_utc())
            .ok_or_else(wrong)
    };
    if let Ok(at) = NaiveDateTime::parse_from_str(text, "%Y-%m-%d %H:%M") {
        return local(at).map(Bound::At);
    }
    let day = NaiveDate::parse_from_str(text, "%Y-%m-%d").map_err(|_| wrong())?;
    let next = day.succ_opt().ok_or_else(wrong)?;
    Ok(Bound::Day(
        local(day.and_time(NaiveTime::MIN))?,
        local(next.and_time(NaiveTime::MIN))?,
    ))
}

/// The first row at the bound; with `end`, past it, so a day's end is the
/// next midnight. None when there is no such row.
async fn first(
    conn: &mut PgConnection,
    conversation: ConversationId,
    bound: Bound,
    end: bool,
) -> sqlx::Result<Option<MessageId>> {
    let at = match bound {
        Bound::Row(id) => return Ok(Some(id)),
        Bound::At(at) => at,
        Bound::Day(start, next) => {
            if end {
                next
            } else {
                start
            }
        }
    };
    ledger::first_since(conn, conversation, at).await
}

/// The arguments that read on: the same, from after the last row read, or
/// to before the first.
fn next_args(args: &Args, next: &Next) -> Value {
    let mut more = Map::new();
    if let Some(who) = &args.who {
        more.insert("who".into(), json!(who));
    }
    match next {
        Next::After(last) => {
            more.insert("from".into(), json!(format!("#{}", last.0 + 1)));
            if let Some(to) = &args.to {
                more.insert("to".into(), json!(to));
            }
        }
        Next::Before(first) => {
            more.insert("to".into(), json!(format!("#{first}")));
        }
    }
    if let Some(limit) = args.limit {
        more.insert("limit".into(), json!(limit));
    }
    Value::Object(more)
}

#[cfg(test)]
mod tests;
