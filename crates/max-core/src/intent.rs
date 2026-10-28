//! intent decides when to wake the core. Every row the conversation actor
//! commits goes through it: direct triggers wake the core at once (after a
//! short wait if the sender seems to be mid-sentence), and other chatter
//! goes to a small classifier model, a batch at a time.
//!
//! Like the core it is a pure state machine: the actor passes the time in.
//! Its state lives only in memory; a restart forgets it, including a held
//! trigger, which then goes unanswered.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::ids::{IdentityId, MessageId};

pub mod classify;

/// Why the core was woken.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Reason {
    /// An @, a reply to Max, or a private message.
    Direct,
    /// The classifier judged that Max should join in, and said why.
    Judged { note: String },
}

/// Judged wakes in an hour at most: a fuse against a classifier gone
/// wrong.
pub const MAX_PER_HOUR: usize = 8;
/// The most messages one classification looks at.
const BATCH: usize = 30;
/// A held trigger wakes once its sender has been quiet this long...
const QUIET: Duration = Duration::from_secs(10);
/// ...or this long after it came, whichever is first.
const HOLD_AT_MOST: Duration = Duration::from_secs(20);
/// Three messages from one sender this close together look like a
/// sentence typed in pieces.
const BURST: Duration = Duration::from_secs(5);
const HOUR: Duration = Duration::from_secs(3600);

/// A committed row, as intent sees it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub id: MessageId,
    pub sender: IdentityId,
    pub kind: EntryKind,
    /// What the sender wrote, without the mention of Max: what the
    /// mid-sentence check reads.
    pub text: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EntryKind {
    /// An @ of Max, a reply to Max, or a private message.
    Direct,
    /// A command, which the actor runs.
    Command,
    /// Anything else, events included.
    Chatter,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decision {
    /// Wake the core: feed it an `Input::Wake`, or start one.
    Wake { ids: Vec<MessageId>, reason: Reason },
    /// Run the classifier on these, newest last.
    Classify { batch: Vec<MessageId> },
}

/// What the classifier said, parsed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Verdict {
    pub trigger: bool,
    pub reason: String,
}

#[derive(Debug)]
pub struct Intent {
    proactive: bool,
    holds: Vec<Hold>,
    /// Recent messages by sender, for spotting bursts.
    recent: VecDeque<(IdentityId, Instant)>,
    /// The batch being classified.
    classifying: Option<Vec<MessageId>>,
    /// Chatter that came while a classification was in flight.
    waiting: Vec<MessageId>,
    /// When each judged wake went out, the last hour's worth.
    judged: VecDeque<Instant>,
}

#[derive(Debug)]
struct Hold {
    sender: IdentityId,
    ids: Vec<MessageId>,
    since: Instant,
    last: Instant,
}

impl Default for Intent {
    fn default() -> Self {
        Self::new()
    }
}

impl Intent {
    pub fn new() -> Self {
        Self {
            proactive: true,
            holds: Vec::new(),
            recent: VecDeque::new(),
            classifying: None,
            waiting: Vec::new(),
            judged: VecDeque::new(),
        }
    }

    pub fn observe(&mut self, entry: &Entry, now: Instant) -> Vec<Decision> {
        let burst = self.burst(entry.sender, now);
        if let Some(hold) = self
            .holds
            .iter_mut()
            .find(|hold| hold.sender == entry.sender)
            && entry.kind != EntryKind::Command
        {
            hold.ids.push(entry.id);
            hold.last = now;
            return Vec::new();
        }
        match entry.kind {
            EntryKind::Direct if burst || unfinished(&entry.text) => {
                self.holds.push(Hold {
                    sender: entry.sender,
                    ids: vec![entry.id],
                    since: now,
                    last: now,
                });
                Vec::new()
            }
            EntryKind::Direct => vec![Decision::Wake {
                ids: vec![entry.id],
                reason: Reason::Direct,
            }],
            EntryKind::Chatter if self.proactive => {
                self.waiting.push(entry.id);
                self.classify().into_iter().collect()
            }
            EntryKind::Chatter | EntryKind::Command => Vec::new(),
        }
    }

    /// The classifier's answer for the batch in flight; None if it failed.
    pub fn verdict(&mut self, verdict: Option<Verdict>, now: Instant) -> Vec<Decision> {
        let Some(batch) = self.classifying.take() else {
            return Vec::new();
        };
        while self.judged.front().is_some_and(|at| now >= *at + HOUR) {
            self.judged.pop_front();
        }
        let mut decisions = Vec::new();
        if let Some(verdict) = verdict
            && verdict.trigger
            && self.proactive
            && self.judged.len() < MAX_PER_HOUR
        {
            self.judged.push_back(now);
            decisions.push(Decision::Wake {
                ids: batch,
                reason: Reason::Judged {
                    note: verdict.reason,
                },
            });
        }
        decisions.extend(self.classify());
        decisions
    }

    /// Held triggers whose wait is over.
    pub fn tick(&mut self, now: Instant) -> Vec<Decision> {
        let (due, held): (Vec<Hold>, Vec<Hold>) = std::mem::take(&mut self.holds)
            .into_iter()
            .partition(|hold| now >= hold.release_at());
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
        self.holds.iter().map(Hold::release_at).min()
    }

    /// `!proactive on` or `off`.
    pub fn set_proactive(&mut self, on: bool) {
        self.proactive = on;
        if !on {
            self.waiting.clear();
        }
    }

    fn burst(&mut self, sender: IdentityId, now: Instant) -> bool {
        self.recent.retain(|(_, at)| now < *at + BURST);
        let before = self.recent.iter().filter(|(who, _)| *who == sender).count();
        self.recent.push_back((sender, now));
        before >= 2
    }

    /// Starts a classification of what's waiting, unless one is in flight.
    fn classify(&mut self) -> Option<Decision> {
        if self.classifying.is_some() || self.waiting.is_empty() || !self.proactive {
            return None;
        }
        let mut batch = std::mem::take(&mut self.waiting);
        let skip = batch.len().saturating_sub(BATCH);
        batch.drain(..skip);
        self.classifying = Some(batch.clone());
        Some(Decision::Classify { batch })
    }
}

impl Hold {
    fn release_at(&self) -> Instant {
        (self.last + QUIET).min(self.since + HOLD_AT_MOST)
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
