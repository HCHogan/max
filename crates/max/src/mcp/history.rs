//! `history`: the conversation's history beyond the context, by content,
//! sender and time. With a query it searches (see `search`); without, it
//! reads rows in order (see `read`): around a row, or a stretch of the
//! timeline, a sender's rows in it if asked. A stretch runs from or to a
//! day, a moment or a row, worked out as row ids once, so that a search
//! and a read keep to the same rows. See "Recall".

mod read;
mod search;

use chrono::{DateTime, FixedOffset, NaiveDate, NaiveDateTime, NaiveTime, TimeZone, Utc};
use max_core::ids::{ConversationId, MessageId};
use max_db::{PgConnection, ledger};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::tool::Tool;
use super::{Context, Failure};
use read::{AROUND, MOST_AROUND, Next, Page};
use search::{Hit, MOST_TERMS};

pub struct History;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Args {
    #[schemars(
        length(min = 1),
        description = format!("keywords separated by spaces, at most {MOST_TERMS}; given, it searches")
    )]
    query: Option<String>,
    #[schemars(
        length(min = 1),
        description = "a few characters of the speaker's name"
    )]
    who: Option<String>,
    #[schemars(description = "YYYY-MM-DD, YYYY-MM-DD HH:MM or #number: from here on")]
    from: Option<String>,
    #[schemars(description = "YYYY-MM-DD, YYYY-MM-DD HH:MM or #number: up to here")]
    to: Option<String>,
    #[schemars(description = "read around this message: 123 for #123")]
    around: Option<i64>,
    #[schemars(
        range(min = 0, max = MOST_AROUND),
        description = format!("how many before around, {AROUND} by default")
    )]
    before: Option<u8>,
    #[schemars(
        range(min = 0, max = MOST_AROUND),
        description = format!("how many after around, {AROUND} by default")
    )]
    after: Option<u8>,
    #[schemars(
        range(min = 1, max = read::MOST),
        description = format!(
            "a search's is {} by default and at most {}; a read's is {} by default and at most {}",
            search::DEFAULT, search::MOST, read::DEFAULT, read::MOST
        )
    )]
    limit: Option<usize>,
    #[schemars(range(min = 1), description = "which page of a read, 1 by default")]
    page: Option<usize>,
}

/// What a search found, or a page read.
#[derive(Serialize, JsonSchema)]
#[serde(untagged)]
pub enum Found {
    Search { results: Vec<Hit> },
    Read(Page),
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

impl Tool for History {
    const NAME: &'static str = "history";
    const DESCRIPTION: &'static str = "Looks through this conversation's chat records, with the descriptions of pictures and stickers: by content, speaker or time, or around one message. With query it returns the passages that match; without, the messages themselves in order of time.";
    const JOB: bool = true;

    type Args = Args;
    type Output = Found;

    fn guide() -> String {
        format!(
            "Looks through this conversation's chat records, with the descriptions of pictures and stickers. For things from before the context, who said what, or what was talked about on a day, look before answering. The filters go together:\n  \
            who is a few characters of the speaker's name (the group card at the time); from and to are YYYY-MM-DD (a whole day, the day itself included both ways), YYYY-MM-DD HH:MM, or #number (from includes that message, to doesn't).\n  \
            With query it searches, and returns results: query is keywords separated by spaces, at most {MOST_TERMS}, each looked for as written, whatever its case; keep a Chinese keyword short, two or three characters. The whole query is also matched by meaning. Messages with more of the keywords, and nearer in meaning, come first, and of equals the newer; limit is {} by default and at most {}. text is a passage around the match; read, passed back as it is, reads that message with {AROUND} on each side. Recalled messages aren't searched.\n  \
            Without query it reads the messages themselves, a line each in order of time, as in the context, the long ones only their beginning: with from, forward from there; without, the newest (up to to); limit is {} by default and at most {}. When there is more, next holds the arguments to go on with, passed back as they are: forward from a read with from, backward from a read of the newest. Give at least one of who, from and to.\n  \
            around reads that message with before and after messages on each side ({AROUND} by default, at most {MOST_AROUND}), and goes with no other filter; with before and after both 0 it reads that one message alone, whole however long.\n  \
            A read comes in pages, none longer than one message may be in the context: pages is how many there are, and page picks one. What /clear --all cleared is only out of the context, and is found all the same.",
            search::DEFAULT,
            search::MOST,
            read::DEFAULT,
            read::MOST,
        )
    }

    async fn run(context: &Context, args: Args) -> Result<Found, Failure> {
        history(context, args).await
    }
}

async fn history(context: &Context, args: Args) -> Result<Found, Failure> {
    let wrong = |message: &str| Err(Failure::new("bad_arguments", message));
    let filtered = args.who.is_some() || args.from.is_some() || args.to.is_some();
    if let Some(id) = args.around {
        if filtered || args.query.is_some() || args.limit.is_some() {
            return wrong("around doesn't go with query, who, from, to or limit");
        }
        let page = read::around(context, id, (args.before, args.after), args.page).await?;
        return Ok(Found::Read(page));
    }
    if args.before.is_some() || args.after.is_some() {
        return wrong("before and after go only with around");
    }
    let filters = filters(context, &args).await?;
    match &args.query {
        Some(_) if args.page.is_some() => wrong("a search has no pages: page is for a read"),
        Some(query) => {
            let results = search::found(context, query, &filters, args.limit).await?;
            Ok(Found::Search { results })
        }
        None if !filtered => wrong("history needs at least one of query, who, from, to and around"),
        None => {
            let limit = args.limit.unwrap_or(read::DEFAULT);
            let newest = args.from.is_none();
            let (pages, next) = read::stretch(context, &filters, newest, limit).await?;
            let mut read = read::paged(pages, args.page)?;
            read.next = next.map(|next| next_args(&args, &next));
            Ok(Found::Read(read))
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
            format!(
                "from and to are written YYYY-MM-DD, YYYY-MM-DD HH:MM or #number, not {text:?}"
            ),
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
fn next_args(args: &Args, next: &Next) -> Map<String, Value> {
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
    more
}

#[cfg(test)]
mod tests;
