//! The dreamer: once a night, a model tidies each memory file Max wrote
//! in the day before. Max adds lines and seldom goes back over them; the
//! dreamer merges what says the same thing, drops what has expired, and
//! keeps the file under its cap. See "记忆" in docs/rust-rewrite.md.

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use chrono::{DateTime, FixedOffset, NaiveTime, TimeDelta, TimeZone, Utc};
use color_eyre::eyre::{Result, bail, eyre};
use max_core::ids::ConversationId;
use max_core::item::{Item, ItemKind};
use max_core::project::{MEMORY_FILE, now_line};
use max_core::run::Request;
use max_db::{PgPool, usage};
use max_llm::Pictures;
use tokio::time::sleep;
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};

use crate::llm::Chosen;
use crate::mcp::work;
use crate::vm;

/// When, local time.
const NIGHT: NaiveTime = NaiveTime::from_hms_opt(5, 0, 0).expect("a time");
/// A file written longer ago than this is left alone: the night before
/// tidied it.
const SINCE: TimeDelta = TimeDelta::days(1);
const CALL: Duration = Duration::from_secs(300);
/// Far past the cap; the actor doesn't load one this big either.
const LARGEST: u64 = 256 << 10;
/// What the file was before its last tidy, next to it.
const BEFORE: &str = "memory.prev.md";

const TIDY: &str = "你在整理一个群聊 AI（Max）给自己记的笔记 memory.md。它每次说话前都会读这份笔记，平时只往里加，不整理。把整份文件整理一遍，只输出整理后的完整文件，不加别的话，也不放进代码块。
- 格式照旧：「## 群里」「## 人」两节，人按「### 名字」分，一行一条，结尾是（日期 #消息编号）。别的标题，和指向 /work/.max/memory/ 下别的文件的行，原样留着。
- Max 白天把新的一条直接追加在文件末尾，开头可能写着「名字：」。把这些归进该去的节：说某个人的放到那个人的「### 名字」下面，去掉开头的名字。
- 说同一件事的几条合成一条：留最新的说法，日期取最新的，编号合在一起，最多三个。前后矛盾的留日期新的。同一个人分在几处的并到一处。
- 写明了到哪天为止、已经过了的删掉，日期看 [现在]。
- 只挪位置、合并、删重复和过期的；不改写意思，不新增内容，拿不准的留着。
- 整个文件不超过 3000 token，超了删最不要紧的。";

pub struct Dreamer {
    pub pool: PgPool,
    pub chosen: Chosen,
    /// The VMs' directory, where each conversation's /work is.
    pub dir: PathBuf,
    pub offset: FixedOffset,
}

impl Dreamer {
    pub async fn run(self, stop: CancellationToken) {
        loop {
            let wait = until_night(Utc::now(), self.offset);
            tokio::select! {
                () = stop.cancelled() => return,
                () = sleep(wait) => {}
            }
            let since = SystemTime::from(Utc::now() - SINCE);
            for conversation in conversations(&self.dir) {
                tokio::select! {
                    () = stop.cancelled() => return,
                    tidied = self.tidy(conversation, since) => match tidied {
                        Ok(Some((before, after))) => {
                            info!(%conversation, before, after, "memory tidied");
                        }
                        Ok(None) => {}
                        Err(error) => {
                            warn!(%conversation, "memory not tidied: {error:#}");
                        }
                    },
                }
            }
        }
    }

    /// Tidies the conversation's memory file if Max wrote it since
    /// `since`: its lines before and after. The tidied file keeps the
    /// time Max wrote it, so the next night leaves it alone unless Max
    /// writes it again; one Max changed meanwhile is left for then.
    async fn tidy(
        &self,
        conversation: ConversationId,
        since: SystemTime,
    ) -> Result<Option<(usize, usize)>> {
        let work = vm::work(&self.dir, conversation);
        let Some((old, modified)) = read(&work).await? else {
            return Ok(None);
        };
        if modified < since {
            return Ok(None);
        }
        let text = format!("{}\n{old}", now_line(Utc::now(), self.offset));
        let request = Request {
            model: self.chosen.tag.clone(),
            items: vec![
                Item::new(ItemKind::System { text: TIDY.into() }, 0),
                Item::new(
                    ItemKind::User {
                        text,
                        images: Vec::new(),
                    },
                    0,
                ),
            ],
            tools: &[],
            max_output: self.chosen.max_output,
            roster: Default::default(),
        };
        let purpose = usage::Purpose::Dreamer;
        let said = self
            .chosen
            .complete(
                &self.pool,
                purpose,
                Some(conversation),
                &request,
                &Pictures::default(),
                CALL,
            )
            .await?;
        let new = tidied(&said, &old)?;
        let lines = (old.lines().count(), new.lines().count());
        if new == old {
            return Ok(Some(lines));
        }
        if read(&work).await?.map(|(now, _)| now) != Some(old.clone()) {
            info!(%conversation, "memory changed while it was tidied; left for the next night");
            return Ok(None);
        }
        let file = Path::new(MEMORY_FILE)
            .strip_prefix("/work")
            .unwrap_or(Path::new(MEMORY_FILE));
        let dir = file
            .parent()
            .and_then(Path::to_str)
            .ok_or_else(|| eyre!("no directory in {MEMORY_FILE}"))?
            .to_owned();
        let name = file
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| eyre!("no name in {MEMORY_FILE}"))?
            .to_owned();
        tokio::task::spawn_blocking(move || {
            work::write(&work, &dir, BEFORE, old.as_bytes(), None)?;
            work::write(&work, &dir, &name, new.as_bytes(), Some(modified))
        })
        .await?
        .map_err(|failure| eyre!(failure.message))?;
        Ok(Some(lines))
    }
}

/// The memory file under `work` and when it was written; None without
/// one.
async fn read(work: &Path) -> Result<Option<(String, SystemTime)>> {
    let work = work.to_owned();
    let file = Path::new(MEMORY_FILE)
        .strip_prefix("/work")
        .unwrap_or(Path::new(MEMORY_FILE))
        .to_path_buf();
    let read = tokio::task::spawn_blocking(move || work::read_stamped(&work, &file, LARGEST));
    match read.await? {
        Ok((bytes, modified)) => Ok(Some((String::from_utf8_lossy(&bytes).into(), modified))),
        Err(failure) if failure.code == "not_found" => Ok(None),
        Err(failure) => Err(eyre!(failure.message)),
    }
}

/// The conversations with a directory under the VMs' `dir`.
fn conversations(dir: &Path) -> Vec<ConversationId> {
    let mut found: Vec<ConversationId> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| entry.file_name().to_str()?.parse().ok())
        .map(ConversationId)
        .collect();
    found.sort();
    found
}

/// How long until the next [`NIGHT`], local time.
fn until_night(now: DateTime<Utc>, offset: FixedOffset) -> Duration {
    let local = now.with_timezone(&offset);
    let mut next = local.date_naive().and_time(NIGHT);
    if next <= local.naive_local() {
        next += TimeDelta::days(1);
    }
    let next = offset.from_local_datetime(&next).single();
    next.and_then(|next| (next - local).to_std().ok())
        .unwrap_or_default()
}

/// The tidied file in what the model wrote, out of a code block if it
/// put it in one; refused when it looks like something else, or like a
/// file cut short.
fn tidied(said: &str, old: &str) -> Result<String> {
    let mut text = said.trim();
    if let Some(fenced) = text.strip_prefix("```") {
        let body = fenced.split_once('\n').map_or("", |(_, body)| body);
        text = body.trim_end().strip_suffix("```").unwrap_or(body).trim();
    }
    if !text.contains("## ") {
        bail!("no headings in what the model wrote");
    }
    let (new, was) = (text.chars().count(), old.trim().chars().count());
    if was >= 300 && new < was / 3 {
        bail!("the model wrote {new} characters of {was}");
    }
    Ok(format!("{text}\n"))
}

#[cfg(test)]
mod tests;
