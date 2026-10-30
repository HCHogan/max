//! `find_stickers`: the stickers whose captions are nearest in meaning to
//! what the program asks for, by their handles; the reply sends one by
//! writing its handle. See "发图".

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
const PER_RUN: u32 = 5;

pub struct FindStickers;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Args {
    #[schemars(
        length(min = 1),
        description = "想表达什么，比如“无语”“幸灾乐祸”“翻白眼的猫”"
    )]
    query: String,
    #[schemars(range(min = 1, max = MOST), description = format!("几条，默认 {DEFAULT}"))]
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
    const DESCRIPTION: &'static str = "在表情包库里按意思找表情包，返回句柄和描述，只找不发。";
    const PER_RUN: Option<u32> = Some(PER_RUN);
    const JOB: bool = false;

    type Args = Args;
    type Output = Found;

    fn guide() -> String {
        format!(
            "在表情包库里按意思找表情包：库里是各个群里见过的表情包，按描述和 query 的意思远近排，近的在前。\n  \
            只找不发：挑一个合适的，把 handle 照抄进回复，写成 [sticker#…]，就发出去了；都不合适就不发。limit 1 到 {MOST}，默认 {DEFAULT}。一次运行最多找 {PER_RUN} 次。"
        )
    }

    async fn run(context: &Context, Args { query, limit }: Args) -> Result<Found, Failure> {
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
        let limit = limit.unwrap_or(DEFAULT);
        let vector = embedder.one(query).await.map_err(|error| {
            warn!(%error, "find_stickers couldn't embed its query");
            Failure::new("unavailable", "表情包库暂时用不了，稍后再试。")
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
