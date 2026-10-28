//! intent decides when to wake the core. Every row the conversation actor
//! commits goes through it: direct triggers wake the core at once (after a
//! short wait if the sender seems to be mid-sentence), and other chatter
//! passes a gate to a small classifier model.
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
    /// Judged wakes per hour, all kinds together.
    pub max_per_hour: u32,
    pub topic_cooldown: Duration,
    /// After Max speaks, chatter is classified as it comes.
    pub hot: Duration,
    /// Otherwise chatter is classified at most this often.
    pub chatter_interval: Duration,
    /// The most messages one classification looks at.
    pub batch: usize,
    /// A held trigger wakes once its sender has been quiet this long...
    pub quiet: Duration,
    /// ...or this long after it came, whichever is first.
    pub hold_at_most: Duration,
    /// Three messages from one sender this close together look like a
    /// sentence typed in pieces.
    pub burst: Duration,
    /// After someone tells Max to back off: no topics, half the hourly cap.
    pub dismissed_for: Duration,
    /// How long after Max speaks on a judged wake a direct reply counts as
    /// taking it up.
    pub taken_up_within: Duration,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            max_per_hour: 8,
            topic_cooldown: Duration::from_secs(300),
            hot: Duration::from_secs(180),
            chatter_interval: Duration::from_secs(15 * 60),
            batch: 30,
            quiet: Duration::from_secs(10),
            hold_at_most: Duration::from_secs(20),
            burst: Duration::from_secs(5),
            dismissed_for: Duration::from_secs(24 * 3600),
            taken_up_within: Duration::from_secs(5 * 60),
        }
    }
}

/// A committed row, as intent sees it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub id: MessageId,
    pub sender: IdentityId,
    pub kind: EntryKind,
    /// What the sender wrote, without the mention of Max: what the gate and
    /// the mid-sentence check read.
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
    /// Run the classifier on these, newest last.
    Classify { batch: Vec<MessageId> },
}

/// What the classifier said, parsed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Verdict {
    pub trigger: bool,
    pub kind: Kind,
    pub reason: String,
    /// Someone is telling Max to back off.
    pub dismiss: bool,
}

#[derive(Debug)]
pub struct Intent {
    config: Config,
    proactive: bool,
    holds: Vec<Hold>,
    /// Recent messages by sender, for spotting bursts.
    recent: VecDeque<(IdentityId, Instant)>,
    last_max: Option<Instant>,
    last_chatter_classified: Option<Instant>,
    /// The batch being classified.
    classifying: Option<Batch>,
    /// What passed the gate while a classification was in flight.
    waiting: Batch,
    /// When each judged wake went out, the last hour's worth.
    judged: VecDeque<Instant>,
    last_topic: Option<Instant>,
    dismissed_until: Option<Instant>,
    /// A judged wake whose run hasn't spoken yet.
    judged_unanswered: bool,
    /// Max spoke on a judged wake; a direct reply before this time takes it up.
    watching_until: Option<Instant>,
    /// Recent judged wakes Max spoke on: whether someone took them up.
    taken_up: VecDeque<bool>,
}

#[derive(Debug)]
struct Hold {
    sender: IdentityId,
    ids: Vec<MessageId>,
    since: Instant,
    last: Instant,
}

/// Classification candidates; direct triggers among them only count for
/// `dismiss`.
#[derive(Debug, Default)]
struct Batch {
    ids: Vec<MessageId>,
    direct: Vec<MessageId>,
}

/// How many of the latest judged wakes Max spoke on are remembered.
const TAKEN_UP_KEPT: usize = 5;

impl Intent {
    pub fn new(config: Config) -> Self {
        Self {
            config,
            proactive: true,
            holds: Vec::new(),
            recent: VecDeque::new(),
            last_max: None,
            last_chatter_classified: None,
            classifying: None,
            waiting: Batch::default(),
            judged: VecDeque::new(),
            last_topic: None,
            dismissed_until: None,
            judged_unanswered: false,
            watching_until: None,
            taken_up: VecDeque::new(),
        }
    }

    pub fn observe(&mut self, entry: &Entry, now: Instant) -> Vec<Decision> {
        self.expire(now);
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
        let mut decisions = Vec::new();
        match entry.kind {
            EntryKind::Direct => {
                if let Some(until) = self.watching_until.take() {
                    self.remember_taken_up(now <= until);
                }
                if self.proactive && self.is_hot(now) {
                    self.waiting.ids.push(entry.id);
                    self.waiting.direct.push(entry.id);
                    decisions.extend(self.classify());
                }
                if burst || unfinished(&entry.text) {
                    self.holds.push(Hold {
                        sender: entry.sender,
                        ids: vec![entry.id],
                        since: now,
                        last: now,
                    });
                } else {
                    decisions.push(Decision::Wake {
                        ids: vec![entry.id],
                        reason: Reason::Direct,
                    });
                }
            }
            EntryKind::Max => {
                self.last_max = Some(now);
                if std::mem::take(&mut self.judged_unanswered) {
                    self.watching_until = Some(now + self.config.taken_up_within);
                }
            }
            EntryKind::Chatter if self.proactive => {
                let named = entry.text.to_lowercase().contains("max");
                let due = self
                    .last_chatter_classified
                    .is_none_or(|at| now >= at + self.config.chatter_interval);
                if named || due || self.is_hot(now) {
                    if !named && !self.is_hot(now) {
                        self.last_chatter_classified = Some(now);
                    }
                    self.waiting.ids.push(entry.id);
                    decisions.extend(self.classify());
                }
            }
            EntryKind::Chatter | EntryKind::Command | EntryKind::Quiet => {}
        }
        decisions
    }

    /// The classifier's answer for the batch in flight; None if it failed.
    pub fn verdict(&mut self, verdict: Option<Verdict>, now: Instant) -> Vec<Decision> {
        self.expire(now);
        let Some(batch) = self.classifying.take() else {
            return Vec::new();
        };
        let mut decisions = Vec::new();
        if let Some(verdict) = verdict {
            if verdict.dismiss {
                self.dismissed_until = Some(now + self.config.dismissed_for);
            }
            let ids: Vec<MessageId> = batch
                .ids
                .into_iter()
                .filter(|id| !batch.direct.contains(id))
                .collect();
            if verdict.trigger && !ids.is_empty() && self.allows(verdict.kind, now) {
                self.judged.push_back(now);
                if verdict.kind == Kind::Topic {
                    self.last_topic = Some(now);
                }
                self.judged_unanswered = true;
                decisions.push(Decision::Wake {
                    ids,
                    reason: Reason::Judged {
                        kind: verdict.kind,
                        note: verdict.reason,
                    },
                });
            }
        }
        decisions.extend(self.classify());
        decisions
    }

    /// Held triggers whose wait is over.
    pub fn tick(&mut self, now: Instant) -> Vec<Decision> {
        self.expire(now);
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

    /// `!proactive on` or `off`. Turning it on also forgets a dismissal.
    pub fn set_proactive(&mut self, on: bool) {
        self.proactive = on;
        if on {
            self.dismissed_until = None;
        } else {
            self.waiting = Batch::default();
        }
    }

    pub fn status(&self, now: Instant) -> Status {
        Status {
            proactive: self.proactive,
            judged_last_hour: self.judged.iter().filter(|at| now < **at + HOUR).count(),
            cap: self.cap(now),
            dismissed_for: self
                .dismissed_until
                .and_then(|until| until.checked_duration_since(now)),
            taken_up: self.taken_up.iter().filter(|taken| **taken).count(),
            spoken_on: self.taken_up.len(),
        }
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

    fn is_hot(&self, now: Instant) -> bool {
        self.last_max.is_some_and(|at| now < at + self.config.hot)
    }

    /// Starts a classification of what's waiting, unless one is in flight.
    fn classify(&mut self) -> Option<Decision> {
        if self.classifying.is_some() || self.waiting.ids.is_empty() || !self.proactive {
            return None;
        }
        let mut batch = std::mem::take(&mut self.waiting);
        let skip = batch.ids.len().saturating_sub(self.config.batch);
        batch.ids.drain(..skip);
        let decision = Decision::Classify {
            batch: batch.ids.clone(),
        };
        self.classifying = Some(batch);
        Some(decision)
    }

    fn allows(&self, kind: Kind, now: Instant) -> bool {
        let dismissed = self.dismissed_until.is_some_and(|until| now < until);
        let recent = self.judged.iter().filter(|at| now < **at + HOUR).count();
        let topic_ok = kind != Kind::Topic
            || (!dismissed
                && self
                    .last_topic
                    .is_none_or(|at| now >= at + self.config.topic_cooldown));
        self.proactive && recent < self.cap(now) as usize && topic_ok
    }

    fn cap(&self, now: Instant) -> u32 {
        let dismissed = self.dismissed_until.is_some_and(|until| now < until);
        if dismissed {
            self.config.max_per_hour / 2
        } else {
            self.config.max_per_hour
        }
    }

    /// Forgets what is too old to matter.
    fn expire(&mut self, now: Instant) {
        while self.judged.front().is_some_and(|at| now >= *at + HOUR) {
            self.judged.pop_front();
        }
        if self.watching_until.is_some_and(|until| now > until) {
            self.watching_until = None;
            self.remember_taken_up(false);
        }
    }

    fn remember_taken_up(&mut self, taken: bool) {
        self.taken_up.push_back(taken);
        if self.taken_up.len() > TAKEN_UP_KEPT {
            self.taken_up.pop_front();
        }
    }
}

const HOUR: Duration = Duration::from_secs(3600);

/// For `!status` and the classifier's "本群情况" line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Status {
    pub proactive: bool,
    pub judged_last_hour: usize,
    pub cap: u32,
    pub dismissed_for: Option<Duration>,
    /// Of the latest judged wakes Max spoke on, how many someone replied to.
    pub taken_up: usize,
    pub spoken_on: usize,
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
