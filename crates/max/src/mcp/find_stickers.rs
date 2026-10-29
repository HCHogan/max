//! `find_stickers`: the stickers whose captions are nearest in meaning to
//! what the program asks for, by their handles; the reply sends one by
//! writing its handle. See "发图".

use max_core::item::Image;
use max_core::message::MediaKind;
use max_db::embeddings;
use serde::Deserialize;
use serde_json::{Value, json};
use tracing::warn;

use super::{Context, Failure, arguments};

const DEFAULT: u8 = 5;
const MOST: u8 = 10;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Args {
    query: String,
    limit: Option<u8>,
}

pub async fn run(context: &Context, args: Value) -> Result<Value, Failure> {
    let Args { query, limit } = arguments("find_stickers", args)?;
    let Some(embedder) = &context.services.embedder else {
        return Err(Failure::new("unavailable", "这里没有表情包库。"));
    };
    let query = query.trim();
    if query.is_empty() {
        return Err(Failure::new(
            "bad_arguments",
            "find_stickers 的 query 是空的",
        ));
    }
    let limit = limit.unwrap_or(DEFAULT).clamp(1, MOST);
    let vector = embedder.one(query).await.map_err(|error| {
        warn!(%error, "find_stickers couldn't embed its query");
        Failure::new("unavailable", "表情包库暂时用不了，稍后再试。")
    })?;
    let mut conn = context.services.pool.acquire().await?;
    let found = embeddings::nearest(&mut conn, &embedder.model, &vector, limit).await?;
    let stickers: Vec<Value> = found
        .into_iter()
        .map(|sticker| {
            let image = Image {
                kind: MediaKind::Sticker,
                message: sticker.message,
                ordinal: sticker.ordinal,
            };
            json!({ "handle": image.handle(), "description": sticker.caption })
        })
        .collect();
    Ok(json!({ "stickers": stickers }))
}

#[cfg(test)]
mod tests;
