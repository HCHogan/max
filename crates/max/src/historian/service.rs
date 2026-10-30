//! The historian as a service. A row committed in a group calls for a
//! check against the high watermark at most once a minute, and for a
//! summary once the group has been quiet for ten minutes; `/compact` goes
//! first. One capture runs at a time in a group, since the historian is
//! the only writer of `summaries` and nothing else keeps two from
//! covering the same rows. When each runs is the historian's own
//! schedule, kept in memory; what is summarized is only in `summaries`.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use color_eyre::eyre::{Result, eyre};
use max_core::ids::ConversationId;
use max_db::platform::ConversationKind;
use max_db::summaries::Reason;
use tokio::sync::mpsc::{self, UnboundedReceiver};
use tokio::sync::oneshot;
use tokio::time::{Instant, sleep_until, timeout};
use tokio_util::sync::CancellationToken;
use tracing::{debug, warn};

use super::{Captured, Historian};
use crate::conversation::Place;
use crate::scope::Scope;
use crate::worker::Row;

/// How often a group that said something is checked against the high
/// watermark, at most.
const CHECK: Duration = Duration::from_secs(60);
/// How long a group is quiet before it is summarized.
const QUIET: Duration = Duration::from_secs(600);
/// Checks running at a time; `/compact` doesn't wait for a place.
const AT_ONCE: usize = 2;
/// The most a capture takes: two calls to the model at most, five minutes
/// each, and the reading and the publishing.
const CAPTURE: Duration = Duration::from_secs(11 * 60);
/// How long a group's check rests after it failed, before its one more
/// try; after that, it waits for the group's next row.
const REST: Duration = Duration::from_secs(600);

/// How `/compact` went: what was published, or what went wrong.
pub type Compacted = Result<Captured, String>;

/// What the historian hears.
#[derive(Debug)]
pub enum Notice {
    /// Every committed row; it keeps to the groups.
    Row(Row),
    /// `/compact`: summarize everything settled, the tail too.
    Compact(Compact),
}

impl From<Row> for Notice {
    fn from(row: Row) -> Self {
        Self::Row(row)
    }
}

#[derive(Debug)]
pub struct Compact {
    pub place: Arc<Place>,
    pub reply: oneshot::Sender<Compacted>,
}

/// Until `stop`. A capture still running then is dropped; its rows are
/// read again next time.
pub async fn run(
    historian: Historian,
    mut notices: UnboundedReceiver<Notice>,
    stop: CancellationToken,
) {
    let historian = Arc::new(historian);
    let mut schedule = Schedule::default();
    let mut captures = Scope::new();
    let (done_tx, mut done) = mpsc::unbounded_channel();
    loop {
        for start in schedule.start(Instant::now()) {
            let historian = Arc::clone(&historian);
            let done = done_tx.clone();
            captures.spawn(move |_| async move {
                let capture = historian.capture(&start.place, start.reason);
                let captured = match timeout(CAPTURE, capture).await {
                    Ok(captured) => captured,
                    Err(_) => Err(eyre!("took more than {CAPTURE:?}")),
                };
                let _ = done.send((start, captured));
            });
        }
        let next = schedule.next();
        tokio::select! {
            () = stop.cancelled() => break,
            Some(notice) = notices.recv() => schedule.hear(notice, Instant::now()),
            Some((start, captured)) = done.recv() => {
                schedule.finished(start, captured, Instant::now());
            }
            () = sleep_until(next.unwrap_or_else(Instant::now)), if next.is_some() => {}
        }
    }
    captures.close(Duration::ZERO).await;
}

/// When each group's captures run. No I/O: what it is told, and the time.
#[derive(Default)]
struct Schedule {
    groups: HashMap<ConversationId, Group>,
    /// Checks running, `/compact` aside.
    running: usize,
}

struct Group {
    place: Arc<Place>,
    pressure: Option<Due>,
    quiet: Option<Due>,
    /// Who waits for `/compact`.
    compact: Vec<oneshot::Sender<Compacted>>,
    /// A capture of the group is running.
    busy: bool,
}

/// When a check is due, and whether it is the one more try after a
/// failure.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Due {
    at: Instant,
    retry: bool,
}

/// A capture starting: the group, why, and who waits for it.
struct Start {
    place: Arc<Place>,
    reason: Reason,
    retry: bool,
    replies: Vec<oneshot::Sender<Compacted>>,
}

impl Schedule {
    fn hear(&mut self, notice: Notice, now: Instant) {
        match notice {
            Notice::Row(row) if row.place.kind == ConversationKind::Group => {
                let group = self.group(row.place);
                // From the first row: rows meanwhile change nothing.
                group.pressure.get_or_insert(Due {
                    at: now + CHECK,
                    retry: false,
                });
                // From the last row, and never sooner than a rest.
                let at = (now + QUIET).max(group.quiet.map_or(now, |due| due.at));
                group.quiet = Some(Due { at, retry: false });
            }
            Notice::Row(_) => {}
            Notice::Compact(Compact { place, reply }) => self.group(place).compact.push(reply),
        }
    }

    fn group(&mut self, place: Arc<Place>) -> &mut Group {
        let group = self.groups.entry(place.conversation).or_insert(Group {
            place: Arc::clone(&place),
            pressure: None,
            quiet: None,
            compact: Vec::new(),
            busy: false,
        });
        group.place = place;
        group
    }

    /// What starts now: `/compact` in each group that isn't busy, then
    /// the checks due, earliest first, while there is a place.
    fn start(&mut self, now: Instant) -> Vec<Start> {
        let mut starting = Vec::new();
        for group in self.groups.values_mut() {
            if !group.busy && !group.compact.is_empty() {
                group.busy = true;
                starting.push(Start {
                    place: Arc::clone(&group.place),
                    reason: Reason::Compact,
                    retry: false,
                    replies: std::mem::take(&mut group.compact),
                });
            }
        }
        let mut due: Vec<(Instant, ConversationId)> = self
            .groups
            .iter()
            .filter(|(_, group)| !group.busy)
            .filter_map(|(id, group)| group.first_due().map(|(_, due)| (due.at, *id)))
            .filter(|(at, _)| *at <= now)
            .collect();
        due.sort();
        for (_, id) in due {
            if self.running >= AT_ONCE {
                break;
            }
            let Some(group) = self.groups.get_mut(&id) else {
                continue;
            };
            let Some((reason, due)) = group.first_due() else {
                continue;
            };
            match reason {
                Reason::Pressure => group.pressure = None,
                _ => group.quiet = None,
            }
            group.busy = true;
            self.running += 1;
            starting.push(Start {
                place: Arc::clone(&group.place),
                reason,
                retry: due.retry,
                replies: Vec::new(),
            });
        }
        starting
    }

    /// When a check is next due, if it could start then.
    fn next(&self) -> Option<Instant> {
        if self.running >= AT_ONCE {
            return None;
        }
        self.groups
            .values()
            .filter(|group| !group.busy)
            .filter_map(|group| group.first_due().map(|(_, due)| due.at))
            .min()
    }

    fn finished(&mut self, start: Start, captured: Result<Captured>, now: Instant) {
        let conversation = start.place.conversation;
        let Some(group) = self.groups.get_mut(&conversation) else {
            return;
        };
        group.busy = false;
        if start.reason == Reason::Compact {
            if let Err(error) = &captured {
                warn!(%conversation, "/compact failed: {error:#}");
            }
            // They hear how it went; it isn't tried again.
            let compacted = captured.map_err(|error| format!("{error:#}"));
            for reply in start.replies {
                let _ = reply.send(compacted.clone());
            }
        } else {
            self.running -= 1;
            match captured {
                Ok(_) => {}
                Err(error) if start.retry => {
                    warn!(%conversation, reason = ?start.reason, "gave up a summary: {error:#}");
                }
                Err(error) => {
                    debug!(%conversation, reason = ?start.reason, "a summary failed: {error:#}");
                    // The one more try covers the rows that came meanwhile.
                    let rest = Some(Due {
                        at: now + REST,
                        retry: true,
                    });
                    match start.reason {
                        Reason::Pressure => group.pressure = rest,
                        _ => group.quiet = rest,
                    }
                }
            }
        }
        if group.pressure.is_none() && group.quiet.is_none() && group.compact.is_empty() {
            self.groups.remove(&conversation);
        }
    }
}

impl Group {
    /// The check due first, and when.
    fn first_due(&self) -> Option<(Reason, Due)> {
        let pressure = self.pressure.map(|due| (Reason::Pressure, due));
        let quiet = self.quiet.map(|due| (Reason::Quiet, due));
        [pressure, quiet]
            .into_iter()
            .flatten()
            .min_by_key(|(_, due)| due.at)
    }
}

#[cfg(test)]
mod tests;
