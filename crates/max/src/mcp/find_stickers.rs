//! `find_stickers`: the stickers whose captions are nearest in meaning to
//! what the program asks for, by their handles; the reply sends one by
//! writing its handle. See "Sending images".

use max_core::item::Image;
use max_core::message::MediaKind;
use max_db::embeddings;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use tracing::warn;

use super::tool::Tool;
use super::{Context, Failure};

const DEFAULT: u8 = 5;
const MOST: u8 = 10;

pub struct FindStickers;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Args {
    #[schemars(
        length(min = 1),
        description = "what to express, such as “无语”, “幸灾乐祸” or “翻白眼的猫”"
    )]
    query: String,
    #[schemars(range(min = 1, max = MOST), description = format!("how many, {DEFAULT} by default"))]
    limit: Option<u8>,
}

#[derive(Serialize, JsonSchema)]
pub struct Found {
    stickers: Vec<Sticker>,
}

#[derive(Serialize, JsonSchema)]
pub struct Sticker {
    handle: String,
    description: String,
}

impl Tool for FindStickers {
    const NAME: &'static str = "find_stickers";
    const DESCRIPTION: &'static str = "Finds stickers in the library by meaning: their handles and descriptions. It finds, and doesn't send.";
    const JOB: bool = false;

    type Args = Args;
    type Output = Found;

    fn guide() -> String {
        format!(
            "Finds stickers in the library by meaning: the library holds the stickers seen in every chat, ranked by how near each description is to what query means, nearest first.\n  \
            It finds and doesn't send: pick one that fits and copy its handle into your reply as [sticker#…], and it goes out; if none fits, send none. limit is 1 to {MOST}, {DEFAULT} by default."
        )
    }

    async fn run(context: &Context, Args { query, limit }: Args) -> Result<Found, Failure> {
        let Some(embedder) = &context.services.embedder else {
            return Err(Failure::new(
                "unavailable",
                "there is no sticker library here",
            ));
        };
        let query = query.trim();
        if query.is_empty() {
            return Err(Failure::new(
                "bad_arguments",
                "find_stickers: query is empty",
            ));
        }
        let limit = limit.unwrap_or(DEFAULT);
        let vector = embedder.one(query).await.map_err(|error| {
            warn!(%error, "find_stickers couldn't embed its query");
            Failure::new(
                "unavailable",
                "the sticker library can't be used right now; try again later",
            )
        })?;
        let mut conn = context.services.pool.acquire().await?;
        let found = embeddings::nearest(&mut conn, &embedder.model, &vector, limit).await?;
        let stickers = found
            .into_iter()
            .map(|sticker| {
                let image = Image {
                    kind: MediaKind::Sticker,
                    message: sticker.message,
                    ordinal: sticker.ordinal,
                };
                Sticker {
                    handle: image.handle(),
                    description: sticker.caption,
                }
            })
            .collect();
        Ok(Found { stickers })
    }
}

#[cfg(test)]
mod tests;
