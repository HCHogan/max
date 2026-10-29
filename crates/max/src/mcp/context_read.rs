//! `context_read`: a row's whole line, a page at a time. The context shows
//! an over-long row's start only; see "后续输入".

use max_core::ids::MessageId;
use max_core::render::Render;
use max_db::ledger;
use serde::Deserialize;
use serde_json::{Value, json};

use super::{Context, Failure, arguments};
use crate::conversation::project::{delivery_mark, people};
use crate::tokens;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Args {
    id: i64,
    page: Option<usize>,
}

pub async fn run(context: &Context, args: Value) -> Result<Value, Failure> {
    let Args { id, page } = arguments("context_read", args)?;
    let mut conn = context.pool.acquire().await?;
    let Some(row) = ledger::row(&mut conn, context.place.conversation, MessageId(id)).await? else {
        return Err(Failure::new(
            "not_found",
            format!("这里没有 #{id} 这条消息"),
        ));
    };
    let people = people(&mut conn, std::iter::once(&row.message), &context.place).await?;
    let render = Render {
        people: &people,
        offset: context.offset,
    };
    let pages = pages(
        &render.line(&row.message, delivery_mark(&row)),
        context.page_tokens,
    );
    let page = page.unwrap_or(1);
    let Some(text) = page.checked_sub(1).and_then(|index| pages.get(index)) else {
        return Err(Failure::new(
            "no_page",
            format!("#{id} 只有 {} 页", pages.len()),
        ));
    };
    Ok(json!({ "text": text, "page": page, "pages": pages.len() }))
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

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use chrono::Utc;
    use sqlx::PgPool;

    use super::*;
    use crate::conversation::ingest;
    use crate::conversation::testing::{from_xiaoming, group, offset, text};

    #[test]
    fn pages_hold_the_text_in_order_and_under_the_cap() {
        let text: String = (0..3000).map(|n| format!("第{n}句。")).collect();
        let pages = pages(&text, 500);
        assert!(pages.len() > 1);
        assert!(pages.iter().all(|page| tokens::count(page) <= 500));
        assert_eq!(pages.concat(), text);
        assert_eq!(super::pages("短", 500), ["短"]);
        assert_eq!(super::pages("", 500), [""]);
    }

    #[sqlx::test(migrator = "max_db::MIGRATOR")]
    async fn a_long_row_reads_page_by_page(pool: PgPool) {
        let mut conn = pool.acquire().await.unwrap();
        let place = Arc::new(group(&mut conn).await);
        let long = "长".repeat(6000);
        let committed = ingest::inbound(
            &mut conn,
            &place,
            &from_xiaoming(1, vec![text(&long)]),
            Utc::now(),
            offset(),
        )
        .await
        .unwrap();
        drop(conn);
        let id = committed.message.id.0;
        let context = Context {
            pool,
            place,
            offset: offset(),
            page_tokens: 2000,
            search: None,
        };

        let first = run(&context, json!({ "id": id })).await.unwrap();
        let pages = first["pages"].as_u64().unwrap();
        assert!(pages > 1, "{first}");
        let mut whole = String::new();
        for page in 1..=pages {
            let read = run(&context, json!({ "id": id, "page": page }))
                .await
                .unwrap();
            assert_eq!(read["page"], page);
            whole.push_str(read["text"].as_str().unwrap());
        }
        assert!(
            whole.starts_with(&format!("[12:01 小明 #{id}]: 长")),
            "{whole}"
        );
        assert_eq!(whole.matches('长').count(), 6000);

        let past = run(&context, json!({ "id": id, "page": pages + 1 })).await;
        assert_eq!(past.unwrap_err().code, "no_page");
        let other = run(&context, json!({ "id": id + 100 })).await;
        assert_eq!(other.unwrap_err().code, "not_found");
        let wrong = run(&context, json!({ "id": "x" })).await;
        assert_eq!(wrong.unwrap_err().code, "bad_arguments");
        let typo = super::super::call("context_reed", &context, json!({})).await;
        assert_eq!(typo.unwrap_err().code, "unknown_tool");
    }
}
