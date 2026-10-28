//! intent decides when to wake the core. Every row the conversation actor
//! commits goes through it: direct triggers wake the core at once, after a
//! short wait if the sender seems to be mid-sentence.
//!
//! Like the core it is a pure state machine: the actor passes the time in.
//! Its state lives only in memory; a restart forgets it, including a held
//! trigger, which then goes unanswered.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::ids::{IdentityId, MessageId};

/// Why the core was woken.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Reason {
    /// An @, a reply to Max, a poke, or a private message from someone on
    /// the list.
    Direct,
    /// The classifier judged that Max should join in.
    Judged { kind: Kind, note: String },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    /// Someone called Max without an @, such as by name.
    Called,
    /// A follow-up to what Max just said.
    Followup,
    /// A topic Max can help with.
    Topic,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Config {
    /// A held trigger wakes once its sender has been quiet this long...
    pub quiet: Duration,
    /// ...or this long after it came, whichever is first.
    pub hold_at_most: Duration,
    /// Three messages from one sender this close together look like a
    /// sentence typed in pieces.
    pub burst: Duration,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            quiet: Duration::from_secs(10),
            hold_at_most: Duration::from_secs(20),
            burst: Duration::from_secs(5),
        }
    }
}

/// A committed row, as intent sees it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub id: MessageId,
    pub sender: IdentityId,
    pub kind: EntryKind,
    /// What the sender wrote, without the mention of Max.
    pub text: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EntryKind {
    /// An @ of Max, a reply to Max, a poke, or a private message from
    /// someone on the list.
    Direct,
    /// Max said it.
    Max,
    /// A command, which the actor runs.
    Command,
    /// Seen, never a trigger, never classified: a private message from
    /// someone not on the list.
    Quiet,
    /// Anything else, events included.
    Chatter,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decision {
    /// Wake the core: feed it an `Input::Wake`, or start one.
    Wake { ids: Vec<MessageId>, reason: Reason },
}

#[derive(Debug)]
pub struct Intent {
    config: Config,
    holds: Vec<Hold>,
    /// Recent messages by sender, for spotting bursts.
    recent: VecDeque<(IdentityId, Instant)>,
}

#[derive(Debug)]
struct Hold {
    sender: IdentityId,
    ids: Vec<MessageId>,
    since: Instant,
    last: Instant,
}

impl Intent {
    pub fn new(config: Config) -> Self {
        Self {
            config,
            holds: Vec::new(),
            recent: VecDeque::new(),
        }
    }

    pub fn observe(&mut self, entry: &Entry, now: Instant) -> Vec<Decision> {
        let burst = self.burst(entry.sender, now);
        if let Some(hold) = self
            .holds
            .iter_mut()
            .find(|hold| hold.sender == entry.sender)
            && matches!(entry.kind, EntryKind::Direct | EntryKind::Chatter)
        {
            hold.ids.push(entry.id);
            hold.last = now;
            return Vec::new();
        }
        if entry.kind != EntryKind::Direct {
            return Vec::new();
        }
        if burst || unfinished(&entry.text) {
            self.holds.push(Hold {
                sender: entry.sender,
                ids: vec![entry.id],
                since: now,
                last: now,
            });
            return Vec::new();
        }
        vec![Decision::Wake {
            ids: vec![entry.id],
            reason: Reason::Direct,
        }]
    }

    /// Held triggers whose wait is over.
    pub fn tick(&mut self, now: Instant) -> Vec<Decision> {
        let (due, held): (Vec<Hold>, Vec<Hold>) = std::mem::take(&mut self.holds)
            .into_iter()
            .partition(|hold| now >= self.release_at(hold));
        self.holds = held;
        due.into_iter()
            .map(|hold| Decision::Wake {
                ids: hold.ids,
                reason: Reason::Direct,
            })
            .collect()
    }

    /// When `tick` next has something to do.
    pub fn deadline(&self) -> Option<Instant> {
        self.holds.iter().map(|hold| self.release_at(hold)).min()
    }

    /// The triggers being held, which wear 托腮 already.
    pub fn held(&self) -> impl Iterator<Item = MessageId> + '_ {
        self.holds.iter().flat_map(|hold| hold.ids.iter().copied())
    }

    fn release_at(&self, hold: &Hold) -> Instant {
        (hold.last + self.config.quiet).min(hold.since + self.config.hold_at_most)
    }

    fn burst(&mut self, sender: IdentityId, now: Instant) -> bool {
        let window = self.config.burst;
        self.recent.retain(|(_, at)| now < *at + window);
        let before = self.recent.iter().filter(|(who, _)| *who == sender).count();
        self.recent.push_back((sender, now));
        before >= 2
    }
}

/// Looks like the sender is mid-sentence: nothing but the @, a trailing
/// comma-like mark, or a word that leads into more.
fn unfinished(text: &str) -> bool {
    const LEADS: &[&str] = &[
        "但是",
        "然后",
        "我跟你讲",
        "对了",
        "就是",
        "所以",
        "而且",
        "还有",
        "那个",
        "因为",
    ];
    let text = text.trim();
    text.is_empty()
        || text.ends_with([',', '，', '、', ';', '；', ':', '：', '…'])
        || LEADS.iter().any(|lead| text.ends_with(lead))
}

#[cfg(test)]
mod tests;
