//! The caption worker: says in words what each new picture or sticker
//! shows, once per file. Rows show it where their node came without a
//! description, and the sticker library searches it. See "媒体".

use std::collections::{BTreeSet, HashSet};
use std::fmt;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use chrono::{TimeDelta, Utc};
use color_eyre::eyre::{Result, bail, eyre};
use max_core::item::{Image, Item, ItemKind};
use max_core::run::Request;
use max_db::captions::{self, Caption, Kind};
use max_db::{PgPool, usage};
use tokio::sync::Semaphore;
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};
use tokio::time::sleep;
use tokio_util::sync::CancellationToken;
use tracing::{debug, warn};

use super::pictures::Pictures;
use crate::llm::Chosen;
use crate::scope::Scope;

/// How long one call to the model may take.
const CALL: Duration = Duration::from_secs(120);
/// Pictures captioned at a time.
const AT_ONCE: usize = 2;
/// How long to wait before the second try. After it, the picture gets an
/// empty caption and isn't tried again.
const RETRY: Duration = Duration::from_secs(60);

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

impl fmt::Debug for Picture {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} {}", self.image.handle(), self.sha256)
    }
}

impl Captioner {
    /// Until `stop`: each picture the download worker stores, and at the
    /// start those of the last two weeks that have no caption. Captions
    /// still being written then are dropped; the next start's scan finds
    /// them.
    pub async fn run(self, mut stored: UnboundedReceiver<Picture>, stop: CancellationToken) {
        let captioner = Arc::new(self);
        let slots = Arc::new(Semaphore::new(AT_ONCE));
        // The files being captioned: a sticker sent again meanwhile isn't
        // shown to the model twice.
        let busy = Arc::new(Mutex::new(HashSet::new()));
        let mut captioning = Scope::new();
        let mut start = |picture: Picture| {
            let mut files = busy.lock().unwrap_or_else(PoisonError::into_inner);
            if !files.insert(picture.sha256.clone()) {
                return;
            }
            let (captioner, slots, busy) = (
                Arc::clone(&captioner),
                Arc::clone(&slots),
                Arc::clone(&busy),
            );
            captioning.spawn(move |_| async move {
                if let Err(error) = captioner.tries(&picture, &slots, RETRY).await {
                    warn!(unit = ?picture, "couldn't caption: {error:#}");
                }
                let mut files = busy.lock().unwrap_or_else(PoisonError::into_inner);
                files.remove(&picture.sha256);
            });
        };
        match captioner.scan().await {
            Ok(missed) => missed.into_iter().for_each(&mut start),
            Err(error) => warn!("the caption scan failed: {error:#}"),
        }
        loop {
            tokio::select! {
                () = stop.cancelled() => break,
                picture = stored.recv() => match picture {
                    Some(picture) => start(picture),
                    None => break,
                },
            }
        }
        captioning.close(Duration::ZERO).await;
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

    /// Captions `picture`'s file if it has none: the model gets two
    /// tries, `retry` apart, and after the second failure the file gets
    /// an empty caption. A slot is held only while the model is asked.
    async fn tries(&self, picture: &Picture, slots: &Semaphore, retry: Duration) -> Result<()> {
        let Some(kind) = Kind::of(picture.image.kind) else {
            return Ok(());
        };
        let mut conn = self.pool.acquire().await?;
        if captions::exists(&mut conn, &picture.sha256).await? {
            return Ok(());
        }
        drop(conn);
        let mut retry = Some(retry);
        let (text, skip) = loop {
            let said = {
                let _slot = slots.acquire().await?;
                self.caption(picture, kind).await
            };
            match (said, retry.take()) {
                (Ok(said), _) => break said,
                (Err(error), Some(wait)) => {
                    debug!(unit = ?picture, "a caption failed: {error:#}");
                    sleep(wait).await;
                }
                (Err(error), None) => {
                    warn!(unit = ?picture, "gave up a caption: {error:#}");
                    break (String::new(), false);
                }
            }
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
