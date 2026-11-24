//! `find_stickers`: the stickers whose captions have the keywords the
//! program asks for, by their handles; the reply sends one by writing its
//! handle. See "Sending images".

use max_core::item::Image;
use max_core::message::MediaKind;
use max_db::stickers;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::keywords::{self, MOST_TERMS};
use super::tool::Tool;
use super::{Context, Failure};

const DEFAULT: u8 = 5;
const MOST: u8 = 10;

pub(super) struct FindStickers;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub(super) struct Args {
    #[schemars(
        length(min = 1),
        description = format!("keywords separated by spaces, at most {MOST_TERMS}, such as “无语 翻白眼 猫”")
    )]
    query: String,
    #[schemars(range(min = 1, max = MOST), description = format!("how many, {DEFAULT} by default"))]
    limit: Option<u8>,
}

#[derive(Serialize, JsonSchema)]
pub(super) struct Found {
    stickers: Vec<Sticker>,
}

#[derive(Serialize, JsonSchema)]
pub(super) struct Sticker {
    handle: String,
    description: String,
}

impl Tool for FindStickers {
    const NAME: &'static str = "find_stickers";
    const DESCRIPTION: &'static str = "Finds stickers in the library by keywords in their descriptions: their handles and descriptions. It finds, and doesn't send.";

    type Args = Args;
    type Output = Found;

    fn guide() -> String {
        format!(
            "Finds stickers in the library by keywords: the library holds the stickers seen in every chat, each with a description of what it shows and when it fits. query is keywords separated by spaces, at most {MOST_TERMS}, each looked for as written in the descriptions: a feeling, what is in the picture, words written on it. Keep each short, two or three characters for Chinese, and give a few that say the same thing in different words (无语 无奈 翻白眼). Stickers with more of the keywords come first, and of equals those seen last.\n  \
            It finds and doesn't send: pick one that fits and copy its handle into your reply as [sticker#…], and it goes out; if none fits, send none. limit is 1 to {MOST}, {DEFAULT} by default."
        )
    }

    async fn run(context: &Context, Args { query, limit }: Args) -> Result<Found, Failure> {
        let terms = keywords::terms(Self::NAME, &query)?;
        let patterns: Vec<String> = terms.iter().map(|term| keywords::pattern(term)).collect();
        let limit = limit.unwrap_or(DEFAULT);
        let mut conn = context.services.pool.acquire().await?;
        let found = stickers::matching(&mut conn, &patterns, limit).await?;
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
