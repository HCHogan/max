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
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::tool::Tool;
use super::{Context, Failure};
use read::{AROUND, MOST_AROUND, Next, Page};
use search::{Hit, MOST_TERMS};

const PER_RUN: u32 = 60;

pub struct History;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Args {
    #[schemars(
        length(min = 1),
        description = format!("空格隔开的关键词，最多 {MOST_TERMS} 个；给了就是搜")
    )]
    query: Option<String>,
    #[schemars(length(min = 1), description = "发言人名字里的几个字")]
    who: Option<String>,
    #[schemars(description = "YYYY-MM-DD、YYYY-MM-DD HH:MM 或 #编号，从这里起")]
    from: Option<String>,
    #[schemars(description = "YYYY-MM-DD、YYYY-MM-DD HH:MM 或 #编号，到这里为止")]
    to: Option<String>,
    #[schemars(description = "读这条消息前后，#123 就是 123")]
    around: Option<i64>,
    #[schemars(
        range(min = 0, max = MOST_AROUND),
        description = format!("around 前面几条，默认 {AROUND}")
    )]
    before: Option<u8>,
    #[schemars(
        range(min = 0, max = MOST_AROUND),
        description = format!("around 后面几条，默认 {AROUND}")
    )]
    after: Option<u8>,
    #[schemars(
        range(min = 1, max = read::MOST),
        description = format!(
            "搜的默认 {} 条、最多 {}；读的默认 {} 条、最多 {}",
            search::DEFAULT, search::MOST, read::DEFAULT, read::MOST
        )
    )]
    limit: Option<usize>,
    #[schemars(range(min = 1), description = "读的第几页，默认 1")]
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
    const DESCRIPTION: &'static str = "查本会话的聊天记录（连同图片和表情包的描述）：按内容、发言人、时间筛，或者看某条消息前后。给了 query 返回命中的片段，没给就按时间顺序返回原文。";
    const PER_RUN: Option<u32> = Some(PER_RUN);
    const JOB: bool = true;

    type Args = Args;
    type Output = Found;

    fn guide() -> String {
        format!(
            "查本会话的聊天记录，连同图片和表情包的描述。上下文里没有的旧事、谁以前说过什么、哪天聊了什么，先查再答。筛选可以一起用：\n  \
            who 是发言人名字里的几个字（当时的群名片）；from、to 是 YYYY-MM-DD（整天，都含当天）、YYYY-MM-DD HH:MM 或 #编号（from 含这条，to 不含）。\n  \
            给了 query 就是搜，返回 results：query 是空格隔开的关键词，最多 {MOST_TERMS} 个，每个词按原文找，不分大小写，中文词写短点（两三个字）；整个 query 也按意思找相近的说法。命中的词多的、意思近的在前，一样的新的在前；limit 默认 {}，最多 {}。text 是命中处附近的一段；read 原样传回来，就是读这条连同前后各 {AROUND} 条。撤回的消息不搜。\n  \
            没给 query 就是读原文，按时间顺序一行一条，和上下文里一样，太长的只有开头：有 from 从 from 往后读，没有就读最新的（到 to 为止）；limit 默认 {}，最多 {}。还有更多时 next 是接着读的参数，原样传回来：从 from 读的往后接，读最新的往前接。who、from、to 至少给一个。\n  \
            around 读这条消息连同前后各 before、after 条（默认 {AROUND}，最多 {MOST_AROUND}），不和别的筛选一起用；before、after 都是 0 就只读这一条，太长的也是全文。\n  \
            读的结果按页给，一页不超过上下文里一条消息的上限，pages 是总页数，page 选第几页。/clear --all 清掉的只是不在上下文里，照样查得到。",
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
            return wrong("around 不能和 query、who、from、to、limit 一起用");
        }
        let page = read::around(context, id, (args.before, args.after), args.page).await?;
        return Ok(Found::Read(page));
    }
    if args.before.is_some() || args.after.is_some() {
        return wrong("before、after 只能和 around 一起用");
    }
    let filters = filters(context, &args).await?;
    match &args.query {
        Some(_) if args.page.is_some() => wrong("搜的结果不分页，page 只用于读"),
        Some(query) => {
            let results = search::found(context, query, &filters, args.limit).await?;
            Ok(Found::Search { results })
        }
        None if !filtered => wrong("history 要 query、who、from、to、around 里至少一个"),
        None => {
            let limit = args.limit.unwrap_or(read::DEFAULT);
            let newest = args.from.is_none();
            let (pages, next) = read::stretch(context, &filters, newest, limit).await?;
            let mut read = read::paged(&pages, args.page)?;
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
