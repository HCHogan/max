//! intent decides when to wake the core. Every row the conversation actor
//! commits goes through it: direct triggers wake the core at once, and
//! other chatter goes to a small classifier model, a batch at a time.
//!
//! Like the core it is a pure state machine: the actor passes the time in.
//! Its state lives only in memory; a restart forgets it.

use std::collections::VecDeque;
use std::time::Instant;

use serde::{Deserialize, Serialize};

use crate::ids::MessageId;
use crate::limits::{HOUR, JUDGED_WAKES_PER_HOUR};

pub mod classify;

/// Why the core was woken.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Reason {
    /// An @, a reply to Max, or a private message.
    Direct,
    /// The classifier judged that Max should join in, and said why.
    Judged {
        /// Its reason, which the model is shown.
        note: String,
    },
    /// A program in the group's VM ran `maxx wake`, as a background
    /// command and a background agent do when they end, or the VM service
    /// has something to say about the VM: the wake's item says what.
    Program,
    /// Max in another conversation asks Max here: the wake's item is the
    /// question.
    Asked,
    /// Max in another conversation answers what Max here asked it, or
    /// says why it doesn't: the wake's item is the answer. Read too from
    /// the wakes the ledger has as `job`, with a job's handle beside it:
    /// the host's jobs of before, a question that waited or a background
    /// agent, whose end woke Max so.
    #[serde(alias = "job")]
    Answered,
}

/// The most messages one classification looks at.
const BATCH: usize = 30;

/// A committed row, as intent sees it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub id: MessageId,
    /// How it bears on Max.
    pub kind: EntryKind,
}

/// What a row is to intent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EntryKind {
    /// An @ of Max, a reply to Max, or a private message.
    Direct,
    /// A command, which the actor runs.
    Command,
    /// Anything else, events included.
    Chatter,
}

/// What intent has the actor do.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decision {
    /// Wake the core: feed it an `Input::Wake`, or start one.
    Wake {
        /// The rows it is about.
        ids: Vec<MessageId>,
        reason: Reason,
    },
    /// Run the classifier on these, newest last.
    Classify {
        /// The rows to judge.
        batch: Vec<MessageId>,
    },
}

/// What the classifier said, parsed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Verdict {
    /// Whether Max should join in.
    pub trigger: bool,
    /// Why, in a few words.
    pub reason: String,
}

/// Decides when to wake the core: see the module.
#[derive(Debug)]
pub struct Intent {
    proactive: bool,
    /// The batch being classified.
    classifying: Option<Vec<MessageId>>,
    /// Chatter that came while a classification was in flight.
    waiting: Vec<MessageId>,
    /// When each judged wake went out, the last hour's worth.
    judged: VecDeque<Instant>,
}

impl Default for Intent {
    fn default() -> Self {
        Self::new()
    }
}

impl Intent {
    /// With proactivity on and nothing waiting.
    #[must_use]
    pub fn new() -> Self {
        Self {
            proactive: true,
            classifying: None,
            waiting: Vec::new(),
            judged: VecDeque::new(),
        }
    }

    /// A committed row: what it has the actor do now. A direct trigger
    /// wakes at once: when its sender goes on, the actor takes the model
    /// call back instead of intent waiting for them. Chatter joins the
    /// classifier's next batch.
    pub fn observe(&mut self, entry: &Entry) -> Vec<Decision> {
        match entry.kind {
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
            && self.judged.len() < JUDGED_WAKES_PER_HOUR
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

    /// `/stop`: drops the chatter waiting for the classifier, and the
    /// batch in flight, whose verdict then wakes nobody. The hour's judged
    /// wakes it keeps.
    pub fn forget(&mut self) {
        self.waiting.clear();
        self.classifying = None;
    }

    /// `/proactive on` or `off`.
    pub fn set_proactive(&mut self, on: bool) {
        self.proactive = on;
        if !on {
            self.waiting.clear();
        }
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

#[cfg(test)]
mod tests;
