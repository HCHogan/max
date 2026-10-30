//! `web_search`: what the configured search finds.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::tool::Tool;
use super::{Context, Failure};
use crate::search::{Error, Found};

const DEFAULT: u8 = 5;
const MOST: u8 = 10;
const PER_RUN: u32 = 20;

pub struct WebSearch;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Args {
    #[schemars(length(min = 1))]
    query: String,
    #[schemars(range(min = 1, max = MOST), description = format!("几条，默认 {DEFAULT}"))]
    limit: Option<u8>,
}

#[derive(Serialize, JsonSchema)]
pub struct Results {
    results: Vec<Found>,
}

impl Tool for WebSearch {
    const NAME: &'static str = "web_search";
    const DESCRIPTION: &'static str = "搜索网页，返回前几条结果的标题、链接、摘要和发布日期。";
    const PER_RUN: Option<u32> = Some(PER_RUN);
    const JOB: bool = true;

    type Args = Args;
    type Output = Results;

    // Always shown: when the Haskell version kept it in a skill, the model
    // answered from memory instead, and got plots and prices wrong.
    fn guide() -> String {
        format!(
            "搜索网页，返回前几条结果的标题、链接、摘要和发布日期（知道的话）。事实、价格、新闻、剧情这类拿不准或可能过时的，先搜再答，别凭记忆。\n  \
            limit 1 到 {MOST}，默认 {DEFAULT}。一次运行最多搜 {PER_RUN} 次，要搜好几样就 Promise.all。要读全文，用 shell 跑 webread <url>。"
        )
    }

    async fn run(context: &Context, Args { query, limit }: Args) -> Result<Results, Failure> {
        let Some(search) = &context.services.search else {
            return Err(Failure::new("unavailable", "这里没有配网页搜索。"));
        };
        let query = query.trim();
        if query.is_empty() {
            return Err(Failure::new("bad_arguments", "web_search 的 query 是空的"));
        }
        match search.search(query, limit.unwrap_or(DEFAULT)).await {
            Ok(results) => Ok(Results { results }),
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
}
