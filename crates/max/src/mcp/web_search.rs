//! `web_search`: what the configured search finds.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::tool::Tool;
use super::{Context, Failure};
use crate::search::{Error, Found};

const DEFAULT: u8 = 5;
const MOST: u8 = 10;

pub struct WebSearch;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Args {
    #[schemars(length(min = 1))]
    query: String,
    #[schemars(range(min = 1, max = MOST), description = format!("how many, {DEFAULT} by default"))]
    limit: Option<u8>,
}

#[derive(Serialize, JsonSchema)]
pub struct Results {
    results: Vec<Found>,
}

impl Tool for WebSearch {
    const NAME: &'static str = "web_search";
    const DESCRIPTION: &'static str = "Searches the web: the first results' titles, links, summaries and publication dates. What you know ends with your training: search first for anything that may have changed since.";

    type Args = Args;
    type Output = Results;

    // Always shown: when the Haskell version kept it in a skill, the model
    // answered from memory instead, and got plots and prices wrong.
    fn guide() -> String {
        format!(
            "Searches the web: the first results' titles, links, summaries and publication dates, where known. For facts, prices, news, plots and whatever else you aren't sure of or may be out of date, search before answering, and don't go by memory. What you know ends with your training, often months or years before [现在]: versions, releases, prices, schedules, who holds which post and recent events may have changed since, so search first even when you feel sure, and go by the results dated nearest [现在].\n  \
            limit is 1 to {MOST}, {DEFAULT} by default. For several searches use Promise.all. To read a page in full, run webread <url> with shell."
        )
    }

    async fn run(context: &Context, Args { query, limit }: Args) -> Result<Results, Failure> {
        let Some(search) = &context.services.search else {
            return Err(Failure::new(
                "unavailable",
                "web search isn't configured here",
            ));
        };
        let query = query.trim();
        if query.is_empty() {
            return Err(Failure::new("bad_arguments", "web_search: query is empty"));
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
