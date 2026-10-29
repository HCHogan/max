//! The caption worker: says in words what each new picture or sticker
//! shows, once per file. Rows show it where their node came without a
//! description, and the sticker library searches it. See "媒体".

use std::collections::BTreeSet;
use std::fmt;
use std::hash::{Hash, Hasher};
use std::sync::Arc;
use std::time::Duration;

use chrono::{TimeDelta, Utc};
use color_eyre::eyre::{Result, bail, eyre};
use max_core::item::{Image, Item, ItemKind};
use max_core::run::Request;
use max_db::captions::{self, Caption, Kind};
use max_db::{PgPool, usage};
use tokio::sync::mpsc::UnboundedSender;
use tracing::warn;

use super::pictures::Pictures;
use crate::llm::Chosen;
use crate::worker::{Attempt, Derivation, Policy, Wait};

/// How long one call to the model may take.
const CALL: Duration = Duration::from_secs(120);

pub const POLICY: Policy = Policy {
    name: "caption",
    concurrent: 2,
    timeout: CALL.saturating_add(Duration::from_secs(30)),
    // Two tries; after the second, an empty caption, not tried again.
    retries: &[Duration::from_secs(60)],
    rescan: None,
};

/// How far back the scan at the start looks: what came in while the
/// worker was down. Older pictures stay without.
const SCAN: TimeDelta = TimeDelta::days(14);
/// The most of a caption that is kept, in characters.
const MOST: usize = 300;

const IMAGE: &str = "你在给群聊记录里的图片写简介，给之后读记录、看不到原图的人用。看图写一到两句中文：\
画面主要是什么；是截图的话说明是什么内容（报错、代码、网页、聊天记录等），关键文字原样摘录。\
直接写简介，不要开场白，也不要加引号。";

const STICKER: &str = "你在给群聊里的表情包写简介，用来在表情包库里按意思搜，也给之后读记录、看不到图的人用。\
看图写一到两句中文：画面内容、图里的文字（原样引用）、表达的情绪，以及适合什么时候用\
（比如嘲讽、幸灾乐祸、无语、赞同、开心、贴贴、催促）。直接写简介，不要开场白，也不要加引号。\
这张图要是不适合拿来当表情包发（真人生活照、带个人信息的聊天截图、普通照片），在简介前面加上“SKIP：”。";

pub struct Captioner {
    pub pool: PgPool,
    pub chosen: Chosen,
    pub pictures: Arc<Pictures>,
    /// The embedding worker, which is handed the files of the sticker
    /// captions written; None when there is none.
    pub stickers: Option<UnboundedSender<String>>,
}

/// A file to caption, and a row's medium that has it: what the model is
/// shown.
#[derive(Clone)]
pub struct Picture {
    pub image: Image,
    pub sha256: String,
}

// A file is captioned once, whichever row brought it.
impl PartialEq for Picture {
    fn eq(&self, other: &Self) -> bool {
        self.sha256 == other.sha256
    }
}

impl Eq for Picture {}

impl Hash for Picture {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.sha256.hash(state);
    }
}

impl fmt::Debug for Picture {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} {}", self.image.handle(), self.sha256)
    }
}

impl Derivation for Captioner {
    /// A picture the download worker just stored.
    type Input = Picture;
    type Unit = Picture;

    fn on_input(&self, picture: Picture) -> Vec<(Picture, Wait)> {
        vec![(picture, Wait::Now)]
    }

    async fn scan(&self) -> Result<Vec<Picture>> {
        let mut conn = self.pool.acquire().await?;
        let missed = captions::uncaptioned(&mut conn, Utc::now() - SCAN).await?;
        Ok(missed
            .into_iter()
            .map(|missed| Picture {
                image: Image {
                    kind: missed.kind,
                    message: missed.message,
                    ordinal: missed.ordinal,
                },
                sha256: missed.sha256,
            })
            .collect())
    }

    async fn run(&self, picture: &Picture, attempt: Attempt) -> Result<()> {
        let Some(kind) = Kind::of(picture.image.kind) else {
            return Ok(());
        };
        let mut conn = self.pool.acquire().await?;
        if captions::exists(&mut conn, &picture.sha256).await? {
            return Ok(());
        }
        drop(conn);
        let (text, skip) = match self.caption(picture, kind).await {
            Ok(said) => said,
            Err(error) if attempt.last => {
                warn!(worker = POLICY.name, unit = ?picture, "gave up: {error:#}");
                (String::new(), false)
            }
            Err(error) => return Err(error),
        };
        let model = self.chosen.reference();
        let caption = Caption {
            sha256: &picture.sha256,
            kind,
            text: &text,
            skip,
            model: Some(&model),
            at: Utc::now(),
        };
        let mut conn = self.pool.acquire().await?;
        let written = captions::write(&mut conn, &caption).await?;
        if let Some(stickers) = &self.stickers
            && written
            && kind == Kind::Sticker
            && !skip
            && !text.is_empty()
        {
            let _ = stickers.send(picture.sha256.clone());
        }
        Ok(())
    }
}

impl Captioner {
    /// What the model says the picture shows, and whether a sticker isn't
    /// one to send.
    async fn caption(&self, picture: &Picture, kind: Kind) -> Result<(String, bool)> {
        let (system, lead) = match kind {
            Kind::Image => (IMAGE, "这张图："),
            Kind::Sticker => (STICKER, "这个表情包："),
        };
        let chosen = &self.chosen;
        let request = Request {
            model: chosen.tag.clone(),
            items: vec![
                Item::new(
                    ItemKind::System {
                        text: system.into(),
                    },
                    0,
                ),
                Item::new(
                    ItemKind::User {
                        text: lead.into(),
                        images: vec![picture.image],
                    },
                    0,
                ),
            ],
            tools: &[],
            max_output: chosen.max_output,
            roster: BTreeSet::default(),
        };
        let pictures = self.pictures.read(&request).await;
        if pictures.0.is_empty() {
            bail!("the picture can't be read");
        }
        let out = tokio::time::timeout(CALL, async {
            let mut call = chosen
                .caller
                .call(&request, &chosen.options, &pictures)
                .await?;
            while call.next().await?.is_some() {}
            call.finish()
        })
        .await
        .map_err(|_| eyre!("no answer in {CALL:?}"))??;

        let mut conn = self.pool.acquire().await?;
        let record = usage::Call {
            conversation: None,
            turn: None,
            purpose: usage::Purpose::Caption,
            provider: &chosen.provider,
            model: &chosen.tag.model,
            effort: chosen.options.effort.as_deref(),
            usage: out.usage,
            cost_micros: None,
            at: Utc::now(),
        };
        usage::record(&mut conn, &record).await?;
        let said: String = out
            .items
            .iter()
            .filter_map(|item| match &item.kind {
                ItemKind::Assistant { text } => Some(text.as_str()),
                _ => None,
            })
            .collect();
        parse(&said, kind)
    }
}

/// The caption in what the model wrote: on one line, without quotes, at
/// most [`MOST`] characters; and whether a sticker's began with SKIP.
fn parse(said: &str, kind: Kind) -> Result<(String, bool)> {
    let mut text = said.trim();
    let mut skip = false;
    if kind == Kind::Sticker
        && let Some(rest) = text
            .get(..4)
            .filter(|word| word.eq_ignore_ascii_case("SKIP"))
            .and_then(|_| text.get(4..))
    {
        skip = true;
        text = rest.trim_start_matches([':', '：', ',', '，', ' ', '\n']);
    }
    let text = text.trim().trim_matches(['"', '“', '”', '「', '」']).trim();
    let text: String = text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(MOST)
        .collect();
    if text.is_empty() && !skip {
        bail!("the model wrote no caption");
    }
    Ok((text, skip))
}

#[cfg(test)]
mod tests;
