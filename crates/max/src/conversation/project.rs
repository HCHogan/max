//! Projecting a new core's base context from the ledger, and rendering
//! what comes in later for a running core. max-core lays the blocks out;
//! this reads the rows they are made of, and moves the tail's mark on
//! when the tail is cut.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use chrono::{DateTime, FixedOffset, Utc};
use max_core::ids::{IdentityId, MessageId, PrincipalId};
use max_core::item::{Item, ItemKind};
use max_core::message::{Content, MentionTarget, Message, Node, Role};
use max_core::project::{self, Budgets, Volatile};
use max_core::render::{Mark, Render};
use max_core::run::{Context, Input, Wake};
use max_db::ledger::{self, Delivery, Row};
use max_db::links::{self, Peer};
use max_db::platform::{self, ConversationKind};
use max_db::turns::{self, TailEnd};
use sqlx::PgConnection;

use super::Place;
use super::ingest::{self, By};
use crate::tokens;

/// What a projection reads besides the ledger.
#[derive(Clone)]
pub struct Projection<'a> {
    pub place: &'a Place,
    pub system: String,
    pub window: u32,
    /// `/clear --all`'s mark: nothing before it is shown.
    pub cleared_upto: Option<MessageId>,
    /// Max's memory file, as the core is shown it.
    pub memory: String,
    pub now: DateTime<Utc>,
    pub offset: FixedOffset,
}

impl Projection<'_> {
    /// The base context as of `from`, the wakes that start the core
    /// rendered in it as its first inputs. When the tail has grown past
    /// its high watermark, it is cut and its mark saved. The system
    /// prompt and the memory go into the context as they are.
    pub async fn base(
        self,
        conn: &mut PgConnection,
        from: MessageId,
        wakes: Vec<Wake>,
    ) -> sqlx::Result<(Context, Vec<Input>)> {
        let budgets = Budgets::for_window(self.window);
        let conversation = self.place.conversation;

        let cursor = platform::tail_after(conn, conversation)
            .await?
            .max(self.cleared_upto);

        let trigger_ids: BTreeSet<MessageId> = wakes
            .iter()
            .flat_map(|wake| wake.ids.iter().copied())
            .collect();
        let rows = ledger::rows(conn, conversation, cursor, from).await?;
        let (triggers, mut tail): (Vec<Row>, Vec<Row>) = rows
            .into_iter()
            .partition(|row| trigger_ids.contains(&row.message.id));

        // The tail is cut first: what it drops is not shown, its people
        // are not in the roster, and a row that quotes it quotes it.
        let tail_people = people(conn, tail.iter().map(|row| &row.message), self.place).await?;
        let render = Render {
            people: &tail_people,
            offset: self.offset,
        };
        let mut tail_lines: Vec<(String, u32)> = tail
            .iter()
            .map(|row| counted_line(&render, &row.message, own_mark(row), budgets.single))
            .collect();
        let costs: Vec<u32> = tail_lines.iter().map(|(_, tokens)| *tokens).collect();
        let start = project::tail_start(&costs, &budgets);
        if let Some(last_cut) = start.checked_sub(1).and_then(|last| tail.get(last)) {
            platform::set_tail_after(conn, conversation, last_cut.message.id).await?;
        }
        tail.drain(..start);
        tail_lines.drain(..start);

        let mut quoted_ids = BTreeSet::new();
        let shown: BTreeSet<MessageId> = tail
            .iter()
            .chain(&triggers)
            .map(|row| row.message.id)
            .collect();
        for row in tail.iter().chain(&triggers) {
            if let Some(id) = quotes(&row.message)
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

        // The tail's lines as they were rendered to cut it: a line names
        // only the people of its row, who are in both maps.
        let lines: Vec<(&Message, String)> = tail
            .iter()
            .zip(tail_lines)
            .map(|(row, (line, _))| (&row.message, line))
            .collect();
        let ends = turns::tail_ends(conn, conversation, cursor, from).await?;
        let pieces = pieces(&render, &lines, &ends);

        let mut first_lines = Vec::new();
        for row in &triggers {
            let mark = self.trigger_mark(conn, &row.message).await?;
            let line = shown_line(&render, &row.message, mark, budgets.single);
            first_lines.push((&row.message, line));
        }
        let last_shown = lines.last().map(|(message, _)| message.at);
        let mut first_text = render.joined(&first_lines, last_shown);
        for wake in &wakes {
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
        let quoted_text = render.joined(&quoted_lines, None);

        let mut roster: BTreeSet<PrincipalId> = people.values().copied().collect();
        roster.insert(self.place.me.principal);
        let askable = links::asked(conn, conversation).await?;
        let volatile = Volatile {
            now: self.now,
            roster: roster_lines(conn, self.place, &roster, project::roster_line).await?,
            askable: askable.iter().map(Peer::to_string).collect(),
            memory: self.memory,
            quoted: quoted_text,
            first: first_text,
        };
        let blocks = pieces.into_iter().chain([volatile.render(self.offset)]);
        let mut context = project::context(self.system, blocks, roster, tokens::count);
        // The pictures of the first inputs and of the rows they quote, in
        // the volatile block, each after its row: one the tail shows is
        // there only by its caption, so it comes at the end.
        if let Some(volatile) = context.items.last_mut() {
            let wanted: BTreeSet<MessageId> = triggers
                .iter()
                .filter_map(|row| quotes(&row.message))
                .collect();
            let quoted_in_tail = tail.iter().filter(|row| wanted.contains(&row.message.id));
            let messages = triggers
                .iter()
                .chain(&quoted)
                .chain(quoted_in_tail)
                .map(|row| &row.message);
            // Not shared yet, so this doesn't copy it.
            project::attach(Arc::make_mut(volatile), messages);
        }
        let first = wakes.into_iter().map(Input::Wake).collect();
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

/// The row `message` quotes, if any.
pub fn quotes(message: &Message) -> Option<MessageId> {
    match message.content {
        Content::Message { reply_to, .. } => reply_to,
        _ => None,
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
    rows: &[(&Message, Mark)],
    seen: &BTreeSet<PrincipalId>,
    after: Option<DateTime<Utc>>,
    window: u32,
    offset: FixedOffset,
) -> sqlx::Result<Input> {
    let single = Budgets::for_window(window).single;
    let people = people(conn, rows.iter().map(|(message, _)| *message), place).await?;
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
        .map(|(message, mark)| (*message, shown_line(&render, message, *mark, single)))
        .collect();
    text.push_str(&render.joined(&lines, after));
    let text = text.trim_end().to_owned();
    let tokens = tokens::count(&text);
    Ok(Input::Messages {
        ids: rows.iter().map(|(message, _)| message.id).collect(),
        item: Item::new(ItemKind::user(text), tokens),
        people: new.into_iter().collect(),
    })
}

/// What became of Max's row, if it didn't reach the platform; else who
/// said it, if not Max.
pub fn own_mark(row: &Row) -> Mark {
    match row.delivery {
        Some(Delivery::Failed) => Mark::NotSent,
        Some(Delivery::Unknown) => Mark::MaybeNotSent,
        Some(Delivery::Sent) | None => match ingest::by(&row.message) {
            By::Max => Mark::None,
            By::Program => Mark::Program,
            By::Host => Mark::Host,
        },
    }
}

pub(crate) fn shown_line<P: max_core::render::People>(
    render: &Render<'_, P>,
    message: &Message,
    mark: Mark,
    single: u32,
) -> String {
    counted_line(render, message, mark, single).0
}

/// [`shown_line`], and its tokens.
fn counted_line<P: max_core::render::People>(
    render: &Render<'_, P>,
    message: &Message,
    mark: Mark,
    single: u32,
) -> (String, u32) {
    let line = render.line(message, mark);
    let tokens = tokens::count(&line);
    if tokens > single {
        let excerpt = render.excerpt(message, mark);
        let tokens = tokens::count(&excerpt);
        (excerpt, tokens)
    } else {
        (line, tokens)
    }
}

/// The tail as messages of their own, split where the tails of earlier
/// turns ended, so that a turn's first call starts with the first call of
/// the turn before, all of it but the volatile block. Gemini keeps that
/// much of a call for later calls, as whole messages; a tail that grows
/// inside one message isn't reused once a few minutes have passed, and a
/// new turn comes at least an idle window after the last call. See
/// "Rules for a stable prefix" in docs/rust-rewrite.md.
fn pieces<P: max_core::render::People>(
    render: &Render<'_, P>,
    lines: &[(&Message, String)],
    ends: &[TailEnd],
) -> Vec<String> {
    // A turn's tail held the rows up to its snapshot but those it woke
    // for, which its volatile block showed: the rows before the first of
    // them, when they were the newest, as they mostly are.
    let cuts: BTreeSet<usize> = ends
        .iter()
        .map(|end| {
            lines
                .iter()
                .take_while(|(message, _)| {
                    message.id <= end.from && end.woken.is_none_or(|woken| message.id < woken)
                })
                .count()
        })
        .filter(|&cut| 0 < cut && cut < lines.len())
        .collect();
    let mut pieces = Vec::new();
    let mut start: usize = 0;
    for end in cuts.into_iter().chain([lines.len()]) {
        let after = start.checked_sub(1).map(|last| lines[last].0.at);
        pieces.push(render.joined(&lines[start..end], after));
        start = end;
    }
    pieces
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
