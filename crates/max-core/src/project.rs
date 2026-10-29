//! Projection: what a new core sees before its first input. The
//! conversation actor reads the summaries and rows, renders them with this,
//! and hands the result to the core as its base context, which never
//! changes afterwards.
//!
//! Blocks go from the least to the most changeable, so a request shares
//! the longest prefix with the one before: the system prompt, the summary
//! block, the raw tail, then the volatile block (time, roster, quoted rows,
//! the first inputs). Only a historian publish changes the first three.

use std::collections::BTreeSet;
use std::fmt::Write;

use chrono::{DateTime, Datelike, FixedOffset, Utc};

use crate::ids::{PrincipalId, SummaryId};
use crate::item::{Item, ItemKind};
use crate::message::Role;
use crate::render::weekday;
use crate::run::Context;

pub mod decay;

use decay::{Costs, Level};

/// Token budgets for the blocks, from the model's window `C`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Budgets {
    /// The tail grows to twice this before it is cut, back to `tail_low`.
    pub tail_high: u32,
    pub tail_low: u32,
    pub summaries: u32,
    /// One message, job result or tool result; longer ones show an excerpt.
    pub single: u32,
}

impl Budgets {
    pub fn for_window(window: u32) -> Self {
        let tail_high = (window / 8).min(32_000);
        Self {
            tail_high,
            tail_low: tail_high / 2,
            summaries: (window / 32).min(8_000),
            single: (u64::from(window) * 15 / 100).clamp(2_000, 25_000) as u32,
        }
    }
}

/// Where the tail starts, given each row's tokens from the newest summary
/// on. Normally there: the historian keeps the tail in check. Past twice
/// the high watermark, when the historian has been failing, whole stretches
/// are dropped at once, leaving the low watermark or a little more. The
/// cut points are counted from the summary, not from the end, so the start
/// stays put while rows arrive, until the next stretch is due.
pub fn tail_start(tokens: &[u32], budgets: &Budgets) -> usize {
    let limit = u64::from(budgets.tail_high) * 2;
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
        let header = format!("[summary#{} {}]", summary.id, span(summary, offset));
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

/// `2026-10-03 周五 14:02–16:30`, or with the end's date when it differs.
pub(crate) fn span(summary: &Summary, offset: FixedOffset) -> String {
    let start = summary.started_at.with_timezone(&offset);
    let end = summary.ended_at.with_timezone(&offset);
    let date = start.date_naive();
    let head = format!(
        "{date} {} {}",
        weekday(date.weekday()),
        start.format("%H:%M")
    );
    if end.date_naive() == date {
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
        for (label, text) in [("[引用的消息]", &self.quoted), ("[新消息]", &self.first)] {
            if !text.trim().is_empty() {
                let _ = writeln!(out, "\n{label}\n{}", text.trim_end());
            }
        }
        out
    }
}

/// `[现在] 2026-10-29 周四 12:10`, on its own line.
pub fn now_line(now: DateTime<Utc>, offset: FixedOffset) -> String {
    let now = now.with_timezone(&offset);
    let date = now.date_naive();
    format!(
        "[现在] {date} {} {}\n",
        weekday(date.weekday()),
        now.format("%H:%M")
    )
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
