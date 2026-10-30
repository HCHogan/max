//! Projection: what a new core sees before its first input. The
//! conversation actor reads the rows, renders them with this, and hands
//! the result to the core as its base context, which never changes
//! afterwards.
//!
//! Blocks go from the least to the most changeable, so a request shares
//! the longest prefix with the one before: the system prompt, the summary
//! block where the historian is on, the raw tail, then the volatile block
//! (time, roster, memory, quoted rows, the first inputs). Only a cut of
//! the tail or a historian publish changes the first three. What is older
//! than the tail, Max searches and reads with its tools.

use std::collections::BTreeSet;
use std::fmt::Write;

use chrono::{DateTime, FixedOffset, Utc};

use crate::ids::{PrincipalId, SummaryId};
use crate::item::{Image, Item, ItemKind};
use crate::message::{Content, MediaKind, Message, Node, Role};
use crate::render::moment;
use crate::run::Context;

pub mod decay;

use decay::{Costs, Level};

/// Token budgets for the blocks, from the model's window `C`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Budgets {
    /// The tail grows to this before it is cut, back to `tail_low` or a
    /// little more.
    pub tail_high: u32,
    pub tail_low: u32,
    pub summaries: u32,
    /// One message, job result or tool result; longer ones show an excerpt.
    pub single: u32,
}

impl Budgets {
    pub fn for_window(window: u32) -> Self {
        let tail_high = (window / 8).min(64_000);
        Self {
            tail_high,
            tail_low: tail_high / 2,
            summaries: (window / 32).min(8_000),
            single: (u64::from(window) * 15 / 100).clamp(2_000, 25_000) as u32,
        }
    }
}

/// Where the tail starts, given each row's tokens from the tail's mark
/// on: at the mark, until the rows pass the high watermark; then whole
/// stretches are dropped at once, leaving the low watermark or a little
/// more, and the caller moves the mark there. The cut points are counted
/// from the mark, not from the end, so the start stays put while rows
/// arrive, until the next stretch is due. Where the historian is on, the
/// mark is the newest summary's end and the historian keeps the tail in
/// check; the tail is cut only past twice the high watermark, when the
/// historian has been failing.
pub fn tail_start(tokens: &[u32], budgets: &Budgets, summarized: bool) -> usize {
    let limit = u64::from(budgets.tail_high) * if summarized { 2 } else { 1 };
    let total: u64 = tokens.iter().map(|&t| u64::from(t)).sum();
    if total <= limit {
        return 0;
    }
    let stretch = (limit - u64::from(budgets.tail_low)).max(1);
    let cut = (total - limit).div_ceil(stretch) * stretch;
    let mut dropped = 0;
    for (index, &t) in tokens.iter().enumerate() {
        if dropped >= cut {
            return index;
        }
        dropped += u64::from(t);
    }
    tokens.len()
}

/// A summary, as the historian wrote it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Summary {
    pub id: SummaryId,
    pub started_at: DateTime<Utc>,
    pub ended_at: DateTime<Utc>,
    pub title: String,
    pub full: String,
    pub brief: Option<String>,
    pub line: Option<String>,
    pub costs: Costs,
}

/// The summary block, oldest first; empty when every summary is archived.
pub fn summary_block(summaries: &[Summary], budget: u32, offset: FixedOffset) -> String {
    let costs: Vec<Costs> = summaries.iter().map(|summary| summary.costs).collect();
    let mut out = String::new();
    for (summary, level) in summaries.iter().zip(decay::levels(&costs, budget)) {
        let Some(level) = level else { continue };
        if out.is_empty() {
            out.push_str("[早先的聊天，摘要]\n");
        } else {
            out.push('\n');
        }
        let span = span(summary.started_at, summary.ended_at, offset);
        let header = format!("[summary#{} {span}]", summary.id);
        let _ = match (level, &summary.brief, &summary.line) {
            (Level::Line, _, Some(line)) => writeln!(out, "{header} {}", line.trim()),
            (Level::Brief, Some(text), _) => {
                writeln!(out, "{header} {}\n{}", summary.title, text.trim())
            }
            _ => writeln!(out, "{header} {}\n{}", summary.title, summary.full.trim()),
        };
    }
    out
}

/// `2026-10-03 周六 14:02–16:30`, or with the end's date when it differs.
pub fn span(started_at: DateTime<Utc>, ended_at: DateTime<Utc>, offset: FixedOffset) -> String {
    let head = moment(started_at, offset);
    let start = started_at.with_timezone(&offset);
    let end = ended_at.with_timezone(&offset);
    if end.date_naive() == start.date_naive() {
        format!("{head}–{}", end.format("%H:%M"))
    } else {
        format!("{head} – {}", end.format("%m-%d %H:%M"))
    }
}

/// `[mention#12] 小明（管理员）`.
pub fn roster_line(principal: PrincipalId, name: &str, role: Option<Role>, is_max: bool) -> String {
    let name = name.replace(['\n', '\r'], " ");
    let note = match (is_max, role) {
        (true, _) => "（你）",
        (false, Some(Role::Owner)) => "（群主）",
        (false, Some(Role::Admin)) => "（管理员）",
        (false, _) => "",
    };
    format!("[mention#{principal}] {name}{note}")
}

/// The people a text names with `[mention#N]`, such as in a summary.
pub fn mentioned(text: &str) -> BTreeSet<PrincipalId> {
    text.match_indices("[mention#")
        .filter_map(|(at, token)| {
            let rest = &text[at + token.len()..];
            let digits = rest
                .find(|c: char| !c.is_ascii_digit())
                .unwrap_or(rest.len());
            rest[..digits].parse().ok().map(PrincipalId)
        })
        .collect()
}

/// The volatile block: what changes from one core to the next.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Volatile {
    pub now: DateTime<Utc>,
    /// Roster lines, one per person in the context.
    pub roster: Vec<String>,
    /// Max's memory file, as [`memory`] shows it; empty without one.
    pub memory: String,
    /// Rendered rows the context refers to but doesn't show, such as the
    /// target of a reply from before the tail.
    pub quoted: String,
    /// The first inputs, rendered: trigger rows with their marks, and
    /// judged lines.
    pub first: String,
}

impl Volatile {
    pub fn render(&self, offset: FixedOffset) -> String {
        let mut out = now_line(self.now, offset);
        if !self.roster.is_empty() {
            out.push_str("\n[上下文里的人]\n");
            for line in &self.roster {
                out.push_str(line);
                out.push('\n');
            }
        }
        let blocks = [
            ("[记忆]", &self.memory),
            ("[引用的消息]", &self.quoted),
            ("[新消息]", &self.first),
        ];
        for (label, text) in blocks {
            if !text.trim().is_empty() {
                let _ = writeln!(out, "\n{label}\n{}", text.trim_end());
            }
        }
        out
    }
}

/// Max's memory: a file in its VM that it writes itself, shown to every
/// core. See "记忆" in docs/rust-rewrite.md.
pub const MEMORY_FILE: &str = "/work/.max/memory.md";

/// The most tokens of the memory file a core is shown.
pub const MEMORY: u32 = 3_000;

const TIDY: &str =
    "一行一条，细节挪进 /work/.max/memory/ 下的别的文件、这里留一行指过去，过时的合并或删掉";

/// The memory file as a core is shown it: whole, with a reminder to tidy
/// it once it nears [`MEMORY`] tokens; past that, the lines that fit and a
/// note that the rest wasn't loaded. Claude Code treats its MEMORY.md the
/// same way.
pub fn memory(text: &str, count: impl Fn(&str) -> u32) -> String {
    let text = text.trim_end();
    let total = count(text);
    if total <= MEMORY * 4 / 5 {
        return text.to_owned();
    }
    if total <= MEMORY {
        return format!("{text}\n（记忆快到上限了，约 {total}/{MEMORY} token：{TIDY}。）");
    }
    let mut shown = String::new();
    let mut used = 0;
    for line in text.lines() {
        let cost = count(line) + 1;
        if used + cost > MEMORY {
            break;
        }
        used += cost;
        shown.push_str(line);
        shown.push('\n');
    }
    format!("{shown}（记忆超过上限，约 {total}/{MEMORY} token，从这里往后没加载：{TIDY}。）")
}

/// `[现在] 2026-10-29 周四 12:10`, on its own line.
pub fn now_line(now: DateTime<Utc>, offset: FixedOffset) -> String {
    format!("[现在] {}\n", moment(now, offset))
}

/// Most pictures one run is shown; past these, rows show only their text.
pub const MOST_PICTURES: usize = 8;

/// What a picture is reckoned to cost until the provider says: about what
/// Claude, Gemini and GPT charge for one 1568 pixels on its long side.
pub const PICTURE_TOKENS: u32 = 1200;

/// Shows the model the pictures and stickers among `messages`, after
/// `item`'s text, in order, while `left` lasts. Those without a reference
/// to download are left out.
pub fn attach<'m>(
    item: &mut Item,
    messages: impl IntoIterator<Item = &'m Message>,
    left: &mut usize,
) {
    let ItemKind::User { images, .. } = &mut item.kind else {
        return;
    };
    for message in messages {
        let nodes = match &message.content {
            Content::Message { nodes, .. } | Content::Edit { nodes, .. } => nodes,
            Content::Unsend { .. } => continue,
        };
        // Ordinals count every medium, as handles do.
        let media = nodes.iter().filter_map(|node| match node {
            Node::Media { media, meta } => Some((media.is_some(), meta.kind)),
            _ => None,
        });
        for (ordinal, (stored, kind)) in (0..).zip(media) {
            if *left == 0 {
                return;
            }
            if stored && matches!(kind, MediaKind::Image | MediaKind::Sticker) {
                images.push(Image {
                    kind,
                    message: message.id,
                    ordinal,
                });
                item.tokens += PICTURE_TOKENS;
                *left -= 1;
            }
        }
    }
}

/// The base context: the system prompt, then each non-empty block as its
/// own item, in this order. `count` is `max`'s token estimate.
pub fn context(
    system: String,
    blocks: [String; 3],
    roster: BTreeSet<PrincipalId>,
    count: impl Fn(&str) -> u32,
) -> Context {
    let tokens = count(&system);
    let mut items = vec![Item::new(ItemKind::System { text: system }, tokens)];
    for text in blocks {
        if !text.trim().is_empty() {
            let tokens = count(&text);
            items.push(Item::new(ItemKind::user(text), tokens));
        }
    }
    Context { items, roster }
}

#[cfg(test)]
mod tests;
