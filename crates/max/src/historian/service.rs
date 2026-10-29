//! The historian as a service. It hears of every committed row; it checks a
//! group that said something against the high watermark at most once a
//! minute, and summarizes one that has gone quiet. `/compact` doesn't wait
//! its turn.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use max_core::ids::ConversationId;
use max_db::platform::ConversationKind;
use max_db::summaries::Reason;
use tokio::sync::mpsc::{self, UnboundedReceiver};
use tokio::sync::oneshot;
use tokio::time::{Instant, MissedTickBehavior, interval};
use tracing::warn;

use super::{Captured, Historian};
use crate::conversation::Place;
use crate::scope::Scope;
use crate::worker::Row;

/// How often a conversation that said something is checked against the
/// high watermark, at most.
const CHECK: Duration = Duration::from_secs(60);
/// How long a conversation is quiet before it is summarized.
const QUIET: Duration = Duration::from_secs(600);
/// How long a conversation waits after a capture failed.
const REST: Duration = Duration::from_secs(600);
/// Captures at a time, `/compact` aside.
const CONCURRENT: usize = 2;

/// How `/compact` went: what was published, or what went wrong.
pub type Compacted = Result<Captured, String>;

/// `/compact`: summarize everything settled, the tail too.
#[derive(Debug)]
pub struct Compact {
    pub place: Arc<Place>,
    pub reply: oneshot::Sender<Compacted>,
}

/// Until the rows stop coming, when every conversation's handle is gone.
/// A capture still running then is dropped; its rows are read again next
/// time.
pub async fn run(
    historian: Arc<Historian>,
    mut rows: UnboundedReceiver<Row>,
    mut compacts: UnboundedReceiver<Compact>,
) {
    let mut watch = Watch::default();
    let mut captures = Scope::new();
    let (done_tx, mut done) = mpsc::unbounded_channel();
    let mut tick = interval(CHECK);
    tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            row = rows.recv() => match row {
                Some(row) if row.place.kind == ConversationKind::Group => {
                    watch.said(row.place, Instant::now());
                }
                Some(_) => {}
                None => break,
            },
            Some(compact) = compacts.recv() => {
                watch.compact(compact.place, compact.reply, Instant::now());
            }
            Some((conversation, failed)) = done.recv() => {
                watch.done(conversation, failed, Instant::now());
            }
            _ = tick.tick() => {}
        }
        for start in watch.due(Instant::now()) {
            let historian = Arc::clone(&historian);
            let done = done_tx.clone();
            captures.spawn(move |_| async move {
                let conversation = start.place.conversation;
                let result = historian.capture(&start.place, start.reason).await;
                if let Err(error) = &result {
                    warn!(%conversation, reason = ?start.reason, %error, "a capture failed");
                }
                let compacted = result.map_err(|error| format!("{error:#}"));
                for reply in start.replies {
                    let _ = reply.send(compacted.clone());
                }
                let _ = done.send((conversation, compacted.is_err()));
            });
        }
    }
    captures.close(Duration::ZERO).await;
}

/// What the historian knows of the conversations: when each was last
/// heard from and checked.
#[derive(Default)]
struct Watch {
    conversations: HashMap<ConversationId, Watched>,
}

struct Watched {
    place: Arc<Place>,
    last_said: Instant,
    /// Something was said since the last check against the high watermark.
    unchecked: bool,
    last_check: Option<Instant>,
    /// Summarized since it went quiet.
    quiet_done: bool,
    running: bool,
    /// No capture before this, after one failed; `/compact` aside.
    resting: Option<Instant>,
    compacts: Vec<oneshot::Sender<Compacted>>,
}

/// A capture to start, and who waits for it.
struct Start {
    place: Arc<Place>,
    reason: Reason,
    replies: Vec<oneshot::Sender<Compacted>>,
}

impl Watch {
    fn said(&mut self, place: Arc<Place>, now: Instant) {
        let watched = self.watched(place, now);
        watched.last_said = now;
        watched.unchecked = true;
        watched.quiet_done = false;
    }

    fn compact(&mut self, place: Arc<Place>, reply: oneshot::Sender<Compacted>, now: Instant) {
        self.watched(place, now).compacts.push(reply);
    }

    fn watched(&mut self, place: Arc<Place>, now: Instant) -> &mut Watched {
        self.conversations
            .entry(place.conversation)
            .or_insert_with(|| Watched {
                place,
                last_said: now,
                unchecked: false,
                last_check: None,
                quiet_done: true,
                running: false,
                resting: None,
                compacts: Vec::new(),
            })
    }

    fn done(&mut self, conversation: ConversationId, failed: bool, now: Instant) {
        if let Some(watched) = self.conversations.get_mut(&conversation) {
            watched.running = false;
            watched.resting = failed.then_some(now + REST);
        }
    }

    /// The captures to start now, each conversation's marked running.
    fn due(&mut self, now: Instant) -> Vec<Start> {
        let mut running = self.conversations.values().filter(|w| w.running).count();
        let mut starts = Vec::new();
        for watched in self.conversations.values_mut() {
            if watched.running {
                continue;
            }
            let free = running < CONCURRENT && watched.resting.is_none_or(|until| now >= until);
            let reason = if !watched.compacts.is_empty() {
                Reason::Compact
            } else if !free {
                continue;
            } else if watched.unchecked && watched.last_check.is_none_or(|at| now >= at + CHECK) {
                Reason::Pressure
            } else if !watched.quiet_done && now >= watched.last_said + QUIET {
                Reason::Quiet
            } else {
                continue;
            };
            match reason {
                Reason::Pressure => {
                    watched.unchecked = false;
                    watched.last_check = Some(now);
                }
                Reason::Quiet => watched.quiet_done = true,
                Reason::Compact => {}
            }
            watched.running = true;
            running += 1;
            starts.push(Start {
                place: Arc::clone(&watched.place),
                reason,
                replies: std::mem::take(&mut watched.compacts),
            });
        }
        starts
    }
}

#[cfg(test)]
mod tests;
