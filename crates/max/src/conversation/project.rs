//! Projecting a new core's base context from the ledger, and rendering
//! what comes in later for a running core. max-core lays the blocks out;
//! this reads the rows and summaries they are made of.

use std::collections::{BTreeMap, BTreeSet};

use chrono::{DateTime, FixedOffset, Utc};
use max_core::ids::{IdentityId, MessageId, PrincipalId, SummaryId};
use max_core::intent::Reason;
use max_core::item::{Item, ItemKind};
use max_core::message::{Content, MentionTarget, Message, Node, Role};
use max_core::project::decay::Costs;
use max_core::project::{self, Budgets, Summary, Volatile};
use max_core::render::{Mark, Render};
use max_core::run::{Context, Input, Wake};
use max_db::ledger::{self, Delivery, Row};
use max_db::platform::{self, ConversationKind};
use max_db::summaries;
use sqlx::PgConnection;

use super::Place;
use crate::tokens;

/// What a projection reads besides the ledger.
pub struct Projection<'a> {
    pub place: &'a Place,
    pub system: String,
    pub window: u32,
    /// `/clear --all`'s mark: nothing before it is shown.
    pub cleared_upto: Option<MessageId>,
    pub now: DateTime<Utc>,
    pub offset: FixedOffset,
}

impl Projection<'_> {
    /// The base context as of `from`, the wakes that start the core
    /// rendered in it as its first inputs.
    pub async fn base(
        &self,
        conn: &mut PgConnection,
        from: MessageId,
        wakes: &[Wake],
    ) -> sqlx::Result<(Context, Vec<Input>)> {
        let budgets = Budgets::for_window(self.window);
        let conversation = self.place.conversation;

        let active = summaries::active(conn, conversation, self.cleared_upto).await?;
        let cursor = active
            .last()
            .map(|(_, summary)| summary.last)
            .max(self.cleared_upto);
        let summaries: Vec<Summary> = active.into_iter().map(summary).collect();
        let summary_block = project::summary_block(&summaries, budgets.summaries, self.offset);

        let trigger_ids: BTreeSet<MessageId> = wakes
            .iter()
            .flat_map(|wake| wake.ids.iter().copied())
            .collect();
        let rows = ledger::rows(conn, conversation, cursor, from).await?;
        let (triggers, tail): (Vec<Row>, Vec<Row>) = rows
            .into_iter()
            .partition(|row| trigger_ids.contains(&row.message.id));

        let mut quoted_ids = BTreeSet::new();
        let shown: BTreeSet<MessageId> = tail
            .iter()
            .chain(&triggers)
            .map(|row| row.message.id)
            .collect();
        for row in tail.iter().chain(&triggers) {
            if let Content::Message {
                reply_to: Some(id), ..
            } = row.message.content
                && !shown.contains(&id)
            {
                quoted_ids.insert(id);
            }
        }
        let mut quoted = Vec::new();
        for id in quoted_ids {
            if let Some(row) = ledger::row(conn, conversation, id).await? {
                quoted.push(row);
            }
        }

        let messages = tail.iter().chain(&triggers).chain(&quoted);
        let people = people(conn, messages.map(|row| &row.message), self.place).await?;
        let render = Render {
            people: &people,
            offset: self.offset,
        };

        let lines: Vec<(&Message, String)> = tail
            .iter()
            .map(|row| {
                let line = shown_line(&render, &row.message, delivery_mark(row), budgets.single);
                (&row.message, line)
            })
            .collect();
        let costs: Vec<u32> = lines.iter().map(|(_, line)| tokens::count(line)).collect();
        let start = project::tail_start(&costs, &budgets);
        let tail_text = joined(&render, &lines[start..], None);

        let mut first_lines = Vec::new();
        for row in &triggers {
            let mark = self.trigger_mark(conn, &row.message).await?;
            let line = shown_line(&render, &row.message, mark, budgets.single);
            first_lines.push((&row.message, line));
        }
        let last_shown = lines[start..].last().map(|(message, _)| message.at);
        let mut first_text = joined(&render, &first_lines, last_shown);
        for wake in wakes {
            if let Some(Item {
                kind: ItemKind::User { text, .. },
                ..
            }) = &wake.item
            {
                first_text.push_str(text);
                first_text.push('\n');
            }
        }

        let quoted_lines: Vec<(&Message, String)> = quoted
            .iter()
            .map(|row| {
                let line = shown_line(&render, &row.message, Mark::None, budgets.single);
                (&row.message, line)
            })
            .collect();
        let quoted_text = joined(&render, &quoted_lines, None);

        let mut roster: BTreeSet<PrincipalId> = people.values().copied().collect();
        roster.extend(project::mentioned(&summary_block));
        roster.insert(self.place.me.principal);
        let volatile = Volatile {
            now: self.now,
            roster: roster_lines(conn, self.place, &roster, project::roster_line).await?,
            quoted: quoted_text,
            first: first_text,
        };
        let context = project::context(
            self.system.clone(),
            [summary_block, tail_text, volatile.render(self.offset)],
            roster,
            tokens::count,
        );
        let first = wakes.iter().cloned().map(Input::Wake).collect();
        Ok((context, first))
    }

    /// How a trigger row is marked: an @ of Max or a reply to Max. Rows in
    /// a private chat aren't marked; everything there is for Max.
    async fn trigger_mark(&self, conn: &mut PgConnection, message: &Message) -> sqlx::Result<Mark> {
        if self.place.kind == ConversationKind::Direct {
            return Ok(Mark::None);
        }
        direct_mark(conn, self.place, message).await
    }
}

/// An @ of Max or a reply to one of Max's rows.
pub async fn direct_mark(
    conn: &mut PgConnection,
    place: &Place,
    message: &Message,
) -> sqlx::Result<Mark> {
    let Content::Message { reply_to, nodes } = &message.content else {
        return Ok(Mark::None);
    };
    let me = place.me.identity;
    if nodes.iter().any(|node| {
        matches!(node, Node::Mention { target: MentionTarget::Identity(id), .. } if *id == me)
    }) {
        return Ok(Mark::MentionsYou);
    }
    if let Some(target) = reply_to
        && let Some(row) = ledger::row(conn, place.conversation, *target).await?
        && row.message.sender.identity == me
    {
        return Ok(Mark::RepliesToYou);
    }
    Ok(Mark::None)
}

/// Rows a running core hasn't seen, as one input: their lines, after a
/// roster line for each person it hasn't seen yet. `after` is when the
/// last row it saw was sent.
pub async fn follow_up(
    conn: &mut PgConnection,
    place: &Place,
    rows: &[(Message, Mark)],
    seen: &BTreeSet<PrincipalId>,
    after: Option<DateTime<Utc>>,
    window: u32,
    offset: FixedOffset,
) -> sqlx::Result<Input> {
    let single = Budgets::for_window(window).single;
    let people = people(conn, rows.iter().map(|(message, _)| message), place).await?;
    let render = Render {
        people: &people,
        offset,
    };
    let new: BTreeSet<PrincipalId> = people
        .values()
        .copied()
        .filter(|principal| !seen.contains(principal))
        .collect();
    let mut text = String::new();
    for line in roster_lines(conn, place, &new, project::roster_line).await? {
        text.push_str("[上下文里的人] ");
        text.push_str(&line);
        text.push('\n');
    }
    let lines: Vec<(&Message, String)> = rows
        .iter()
        .map(|(message, mark)| (message, shown_line(&render, message, *mark, single)))
        .collect();
    text.push_str(&joined(&render, &lines, after));
    let text = text.trim_end().to_owned();
    let tokens = tokens::count(&text);
    Ok(Input::Messages {
        ids: rows.iter().map(|(message, _)| message.id).collect(),
        item: Item::new(ItemKind::user(text), tokens),
        people: new.into_iter().collect(),
    })
}

/// The line the model is shown for a judged wake.
pub fn judged(reason: &Reason) -> Option<Item> {
    let Reason::Judged { note } = reason else {
        return None;
    };
    let text = format!("[判定：{note}]");
    let tokens = tokens::count(&text);
    Some(Item::new(ItemKind::user(text), tokens))
}

/// A summary as the database has it, as the projection renders it.
pub(crate) fn summary((id, summary): (SummaryId, summaries::Summary)) -> Summary {
    Summary {
        id,
        started_at: summary.started_at,
        ended_at: summary.ended_at,
        costs: Costs {
            importance: summary.importance,
            full: tokens::count(&summary.full),
            brief: summary.brief.as_deref().map(tokens::count),
            line: summary.line.as_deref().map(tokens::count),
        },
        title: summary.title,
        full: summary.full,
        brief: summary.brief,
        line: summary.line,
    }
}

/// What became of Max's row, if it didn't reach the platform.
pub fn delivery_mark(row: &Row) -> Mark {
    match row.delivery {
        Some(Delivery::Failed) => Mark::NotSent,
        Some(Delivery::Unknown) => Mark::MaybeNotSent,
        Some(Delivery::Sent) | None => Mark::None,
    }
}

pub(crate) fn shown_line<P: max_core::render::People>(
    render: &Render<'_, P>,
    message: &Message,
    mark: Mark,
    single: u32,
) -> String {
    let line = render.line(message, mark);
    if tokens::count(&line) > single {
        render.excerpt(message, mark)
    } else {
        line
    }
}

/// Lines in order, with a date line where the day changes and a gap line
/// after a long silence, as [`Render::lines`] does.
pub(crate) fn joined<P: max_core::render::People>(
    render: &Render<'_, P>,
    lines: &[(&Message, String)],
    mut after: Option<DateTime<Utc>>,
) -> String {
    let mut out = String::new();
    for (message, line) in lines {
        if let Some(separator) = render.separator(after, message.at) {
            out.push_str(&separator);
            out.push('\n');
        }
        out.push_str(line);
        out.push('\n');
        after = Some(message.at);
    }
    out
}

/// The person behind every account the messages show: senders and the
/// people they mention.
pub(crate) async fn people<'m>(
    conn: &mut PgConnection,
    messages: impl Iterator<Item = &'m Message>,
    place: &Place,
) -> sqlx::Result<BTreeMap<IdentityId, PrincipalId>> {
    let mut identities = BTreeSet::from([place.me.identity]);
    for message in messages {
        identities.insert(message.sender.identity);
        let nodes = match &message.content {
            Content::Message { nodes, .. } | Content::Edit { nodes, .. } => &nodes[..],
            Content::Unsend { .. } => &[],
        };
        for node in nodes {
            if let Node::Mention {
                target: MentionTarget::Identity(identity),
                ..
            } = node
            {
                identities.insert(*identity);
            }
        }
    }
    let identities: Vec<IdentityId> = identities.into_iter().collect();
    platform::principals(conn, &identities).await
}

/// A line for each of `people`, written by `line(principal, name, role,
/// is_max)`.
pub(crate) async fn roster_lines(
    conn: &mut PgConnection,
    place: &Place,
    people: &BTreeSet<PrincipalId>,
    line: fn(PrincipalId, &str, Option<Role>, bool) -> String,
) -> sqlx::Result<Vec<String>> {
    if people.is_empty() {
        return Ok(Vec::new());
    }
    let people: Vec<PrincipalId> = people.iter().copied().collect();
    let known = platform::roster(conn, place.endpoint, &people).await?;
    Ok(known
        .iter()
        .map(|known| {
            let is_max = known.principal == place.me.principal;
            line(known.principal, &known.name, known.role, is_max)
        })
        .collect())
}

#[cfg(test)]
mod tests;
