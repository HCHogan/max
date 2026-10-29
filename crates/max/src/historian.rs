//! The historian: it summarizes what the conversations said, so that a
//! core's context holds summaries of the past and only a short raw tail.
//! See "historian" in docs/rust-rewrite.md.
//!
//! A capture reads the rows no summary covers yet, up to the first trigger
//! of a turn still running, and asks the historian's model to cut them
//! into compartments and summarize each. What passes the checks is
//! published; every call is recorded in `summary_runs`. No summary reaches
//! across `/clear --all`'s mark, and what came before it is summarized as
//! well, so that `/unclear` finds the history whole.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, FixedOffset, Utc};
use color_eyre::eyre::{Result, eyre};
use max_core::historian::{self, Compartment};
use max_core::ids::{ConversationId, MessageId};
use max_core::item::{Item, ItemKind};
use max_core::message::Message;
use max_core::project::{self, Budgets};
use max_core::render::Render;
use max_core::run::Request;
use max_db::summaries::{self, Reason, Run};
use max_db::vectors::Key;
use max_db::{PgPool, ledger, platform, turns, usage};
use tokio::sync::mpsc::UnboundedSender;
use tracing::{info, warn};

use crate::conversation::Place;
use crate::conversation::project::{
    delivery_mark, joined, people, roster_lines, shown_line, summary,
};
use crate::llm::{Chosen, Models};
use crate::tokens;

mod service;
pub use service::{Compact, Compacted, Notice, run};

/// The most one capture reads, in tokens of rendered rows. A longer
/// stretch takes several captures.
const BATCH: u64 = 24_000;
/// How long one call to the historian's model may take.
const CALL_TIMEOUT: Duration = Duration::from_secs(300);
/// Calls per capture: the first, and one more when it fails or its answer
/// doesn't pass the checks.
const ATTEMPTS: usize = 2;

pub struct Historian {
    pub pool: PgPool,
    pub models: Arc<Models>,
    /// The historian's model.
    pub chosen: Chosen,
    pub offset: FixedOffset,
    /// Where each summary published goes next: the recall vector worker.
    pub published: Option<UnboundedSender<Key>>,
}

/// What a capture came to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Captured {
    /// Too little is uncovered to be worth a call.
    Nothing,
    /// This many summaries were published.
    Published(usize),
}

impl Historian {
    /// Summarizes, for `reason`, the rows after `/clear --all`'s mark; and
    /// first what came before it and isn't summarized yet, all of it, as
    /// `/compact` would. That failing doesn't hold up the rest.
    pub async fn capture(&self, place: &Place, reason: Reason) -> Result<Captured> {
        let before = match self.pass(place, Reason::Compact, true).await {
            Ok(Captured::Published(count)) => count,
            Ok(Captured::Nothing) => 0,
            Err(error) => {
                let conversation = place.conversation;
                warn!(%conversation, "summarizing what came before /clear --all failed: {error:#}");
                0
            }
        };
        Ok(match self.pass(place, reason, false).await? {
            Captured::Published(count) => Captured::Published(before + count),
            Captured::Nothing if before > 0 => Captured::Published(before),
            Captured::Nothing => Captured::Nothing,
        })
    }

    /// One capture: of the rows up to the mark when `before_mark`, else of
    /// those after it.
    async fn pass(&self, place: &Place, reason: Reason, before_mark: bool) -> Result<Captured> {
        let conversation = place.conversation;
        let mut conn = self.pool.acquire().await?;
        let settings = platform::settings(&mut conn, conversation).await?;
        // The tail is kept to the budgets of the model the turns use.
        let turn = self.models.turn(settings.model.as_deref(), None);
        let window = turn.or_else(|_| self.models.turn(None, None))?.window;
        let budgets = Budgets::for_window(window);

        let mark = settings.cleared_upto;
        // The summaries on this pass's side of the mark. One across it, as
        // the Haskell version's clears left some, is on both: what comes
        // before the mark is summarized up to it.
        let mut active = summaries::active(&mut conn, conversation, None).await?;
        active.retain(|(_, summary)| match mark {
            Some(mark) if before_mark => summary.first <= mark,
            Some(mark) => summary.last > mark,
            None => !before_mark,
        });
        let last = active.last().map(|(_, summary)| summary.last);
        let (cursor, upto) = if before_mark {
            match mark {
                Some(mark) if last < Some(mark) => (last, mark),
                _ => return Ok(Captured::Nothing),
            }
        } else {
            let Some(head) = ledger::head(&mut conn, conversation).await? else {
                return Ok(Captured::Nothing);
            };
            // A running turn's trigger and what follows it aren't settled.
            let upto = match turns::running_since(&mut conn, conversation).await? {
                Some(trigger) => MessageId(trigger.0 - 1),
                None => head,
            };
            (last.max(mark), upto)
        };
        let rows = ledger::rows(&mut conn, conversation, cursor, upto).await?;
        let everyone = people(&mut conn, rows.iter().map(|row| &row.message), place).await?;
        let render = Render {
            people: &everyone,
            offset: self.offset,
        };
        let lines: Vec<(&Message, String)> = rows
            .iter()
            .map(|row| {
                let line = shown_line(&render, &row.message, delivery_mark(row), budgets.single);
                (&row.message, line)
            })
            .collect();
        let costs: Vec<u32> = lines.iter().map(|(_, line)| tokens::count(line)).collect();
        let lines = &lines[..stretch(&costs, reason, &budgets)];
        let (Some((first, _)), Some((last, _))) = (lines.first(), lines.last()) else {
            return Ok(Captured::Nothing);
        };

        let shown = people(&mut conn, lines.iter().map(|(message, _)| *message), place).await?;
        let shown: BTreeSet<_> = shown.values().copied().collect();
        let roster = roster_lines(&mut conn, place, &shown, historian::person).await?;
        drop(conn);
        let skip = active.len().saturating_sub(historian::EARLIER);
        let earlier: Vec<project::Summary> = active.into_iter().skip(skip).map(summary).collect();
        let user = historian::user(
            &project::now_line(Utc::now(), self.offset),
            &historian::earlier(&earlier, self.offset),
            &roster.join("\n"),
            &joined(&render, lines, None),
        );
        let ids: Vec<MessageId> = lines.iter().map(|(message, _)| message.id).collect();
        let times: BTreeMap<MessageId, DateTime<Utc>> = lines
            .iter()
            .map(|(message, _)| (message.id, message.at))
            .collect();

        let mut items = vec![
            item(ItemKind::System {
                text: historian::system(),
            }),
            item(ItemKind::user(user)),
        ];
        let model = self.chosen.reference();
        let mut error = String::new();
        for attempt in 1..=ATTEMPTS {
            let started_at = Utc::now();
            let answer = self.call(conversation, &items).await;
            let checked = match &answer {
                Ok(text) => historian::parse(text, &ids).map_err(|invalid| invalid.to_string()),
                Err(failed) => Err(format!("{failed:#}")),
            };
            let mut run = Run {
                conversation,
                first: first.id,
                last: last.id,
                reason,
                model: &model,
                output: answer.as_deref().ok(),
                error: None,
                started_at,
                finished_at: Utc::now(),
            };
            let mut conn = self.pool.acquire().await?;
            match checked {
                Ok(compartments) => {
                    // Only a quiet capture guesses where the stretch ends.
                    let settled = historian::settled(compartments, reason != Reason::Quiet);
                    let written: Vec<summaries::Summary> = settled
                        .into_iter()
                        .map(|compartment| written(compartment, &times))
                        .collect();
                    let ids = summaries::publish(&mut conn, &run, &written).await?;
                    info!(%conversation, ?reason, published = ids.len(), "summarized");
                    if let Some(next) = &self.published {
                        for id in &ids {
                            let _ = next.send(Key::Summary(*id));
                        }
                    }
                    return Ok(Captured::Published(written.len()));
                }
                Err(failed) => {
                    run.error = Some(&failed);
                    summaries::failed(&mut conn, &run).await?;
                    warn!(%conversation, attempt, error = %failed, "the historian's call didn't do");
                    // A wrong answer is shown back with what is wrong
                    // with it; a failed call is simply made again.
                    if let Ok(text) = answer {
                        items.push(item(ItemKind::Assistant { text }));
                        items.push(item(ItemKind::user(format!(
                            "这个答案不对：{failed}。请重新输出完整的 JSON。"
                        ))));
                    }
                    error = failed;
                }
            }
        }
        Err(eyre!("the historian gave up: {error}"))
    }

    /// One call to the historian's model: what it wrote.
    async fn call(&self, conversation: ConversationId, items: &[Item]) -> Result<String> {
        let chosen = &self.chosen;
        let request = Request {
            model: chosen.tag.clone(),
            items: items.to_vec(),
            tools: &[],
            max_output: chosen.max_output,
            roster: BTreeSet::default(),
        };
        let purpose = usage::Purpose::Historian;
        let pictures = max_llm::Pictures::default();
        chosen
            .complete(
                &self.pool,
                purpose,
                Some(conversation),
                &request,
                &pictures,
                CALL_TIMEOUT,
            )
            .await
    }
}

/// How many of the uncovered rows, oldest first, a capture summarizes,
/// given each row's tokens; none when it isn't worth a call. The newest
/// rows up to the low watermark stay raw, except for `/compact`.
fn stretch(costs: &[u32], reason: Reason, budgets: &Budgets) -> usize {
    let total: u64 = costs.iter().map(|&cost| u64::from(cost)).sum();
    let keep = match reason {
        Reason::Compact => 0,
        Reason::Quiet | Reason::Pressure => u64::from(budgets.tail_low),
    };
    let mut kept = 0;
    let mut end = costs.len();
    while let Some(&cost) = end.checked_sub(1).and_then(|index| costs.get(index))
        && kept + u64::from(cost) <= keep
    {
        kept += u64::from(cost);
        end -= 1;
    }
    let worth = match reason {
        // Half the low watermark: less isn't worth a summary of its own.
        Reason::Quiet => total - kept >= u64::from(budgets.tail_low / 2),
        Reason::Pressure => total > u64::from(budgets.tail_high),
        Reason::Compact => true,
    };
    if !worth {
        return 0;
    }
    let mut taken = 0;
    let mut count = 0;
    for &cost in &costs[..end] {
        if count > 0 && taken + u64::from(cost) > BATCH {
            break;
        }
        taken += u64::from(cost);
        count += 1;
    }
    count
}

fn item(kind: ItemKind) -> Item {
    Item::new(kind, 0)
}

/// A compartment as it is published, with the times of its rows.
fn written(
    compartment: Compartment,
    times: &BTreeMap<MessageId, DateTime<Utc>>,
) -> summaries::Summary {
    let time = |id| times.get(&id).copied().unwrap_or_default();
    summaries::Summary {
        first: compartment.first,
        last: compartment.last,
        started_at: time(compartment.first),
        ended_at: time(compartment.last),
        title: compartment.title,
        kind: compartment.kind,
        importance: compartment.importance,
        full: compartment.full,
        brief: Some(compartment.brief),
        line: Some(compartment.line),
    }
}

#[cfg(test)]
mod tests;
