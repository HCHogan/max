//! `web_search`: what the configured search finds.

use serde::Deserialize;
use serde_json::{Value, json};

use super::{Context, Failure, arguments};
use crate::search::Error;

const DEFAULT: u8 = 5;
const MOST: u8 = 10;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Args {
    query: String,
    limit: Option<u8>,
}

pub async fn run(context: &Context, args: Value) -> Result<Value, Failure> {
    let Args { query, limit } = arguments("web_search", args)?;
    let Some(search) = &context.search else {
        return Err(Failure::new("unavailable", "这里没有配网页搜索。"));
    };
    let query = query.trim();
    if query.is_empty() {
        return Err(Failure::new("bad_arguments", "web_search 的 query 是空的"));
    }
    let limit = limit.unwrap_or(DEFAULT).clamp(1, MOST);
    match search.search(query, limit).await {
        Ok(results) => Ok(json!({ "results": results })),
        Err(error) => {
            let code = match error {
                Error::RateLimited => "rate_limited",
                Error::BadQuery(_) => "bad_query",
                Error::Unavailable(_) => "unavailable",
            };
            Err(Failure::new(code, error.to_string()))
        }
    }
}
