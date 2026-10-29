//! The historian as a worker. Each row committed in a group calls for a
//! check against the high watermark at most once a minute, and for a
//! summary once the group has been quiet for ten minutes; `/compact` goes
//! first. The driver runs one capture at a time in a group, since the
//! historian is the only writer of `summaries` and nothing else keeps two
//! from covering the same rows.

use std::collections::HashMap;
use std::fmt;
use std::hash::{Hash, Hasher};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use color_eyre::eyre::Result;
use max_core::ids::ConversationId;
use max_db::platform::ConversationKind;
use max_db::summaries::Reason;
use tokio::sync::mpsc::UnboundedReceiver;
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;
use tracing::warn;

use super::{Captured, Historian};
use crate::conversation::Place;
use crate::worker::{self, Attempt, Derivation, Policy, Row, Wait};

/// How often a group that said something is checked against the high
/// watermark, at most.
const CHECK: Duration = Duration::from_secs(60);
/// How long a group is quiet before it is summarized.
const QUIET: Duration = Duration::from_secs(600);

const POLICY: Policy = Policy {
    name: "historian",
    concurrent: 2,
    // Two calls to the model at most, five minutes each, and the reading
    // and the publishing.
    timeout: Duration::from_secs(11 * 60),
    // A capture that failed rests its group ten minutes, and tries once
    // more.
    retries: &[Duration::from_secs(600)],
    rescan: None,
};

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
    notices: UnboundedReceiver<Notice>,
    stop: CancellationToken,
) {
    let service = Service {
        historian,
        waiting: Mutex::default(),
    };
    worker::drive(Arc::new(service), POLICY, notices, stop).await;
}

struct Service {
    historian: Historian,
    /// Who waits for `/compact` in each group.
    waiting: Mutex<HashMap<ConversationId, Vec<oneshot::Sender<Compacted>>>>,
}

/// A capture of a group, for a reason.
#[derive(Clone)]
struct Capture {
    place: Arc<Place>,
    reason: Reason,
}

impl PartialEq for Capture {
    fn eq(&self, other: &Self) -> bool {
        (self.place.conversation, self.reason) == (other.place.conversation, other.reason)
    }
}

impl Eq for Capture {}

impl Hash for Capture {
    fn hash<H: Hasher>(&self, state: &mut H) {
        (self.place.conversation, self.reason).hash(state);
    }
}

impl fmt::Debug for Capture {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} {:?}", self.place.conversation, self.reason)
    }
}

impl Derivation for Service {
    type Input = Notice;
    type Unit = Capture;

    fn on_input(&self, notice: Notice) -> Vec<(Capture, Wait)> {
        match notice {
            Notice::Row(row) if row.place.kind == ConversationKind::Group => {
                let capture = |reason| Capture {
                    place: Arc::clone(&row.place),
                    reason,
                };
                vec![
                    (capture(Reason::Pressure), Wait::Throttle(CHECK)),
                    (capture(Reason::Quiet), Wait::Debounce(QUIET)),
                ]
            }
            Notice::Row(_) => Vec::new(),
            Notice::Compact(Compact { place, reply }) => {
                let mut waiting = self.waiting.lock().unwrap_or_else(|e| e.into_inner());
                waiting.entry(place.conversation).or_default().push(reply);
                let capture = Capture {
                    place,
                    reason: Reason::Compact,
                };
                vec![(capture, Wait::Urgent)]
            }
        }
    }

    fn conversation(&self, capture: &Capture) -> Option<ConversationId> {
        Some(capture.place.conversation)
    }

    /// None: a group comes back to the historian with its first row after
    /// a restart, and no one reads its summaries before that.
    async fn scan(&self) -> Result<Vec<Capture>> {
        Ok(Vec::new())
    }

    async fn run(&self, capture: &Capture, _: Attempt) -> Result<()> {
        let conversation = capture.place.conversation;
        if capture.reason != Reason::Compact {
            self.historian
                .capture(&capture.place, capture.reason)
                .await?;
            return Ok(());
        }
        // Those who asked since get the next run.
        let replies = {
            let mut waiting = self.waiting.lock().unwrap_or_else(|e| e.into_inner());
            waiting.remove(&conversation).unwrap_or_default()
        };
        let result = self
            .historian
            .capture(&capture.place, Reason::Compact)
            .await;
        if let Err(error) = &result {
            warn!(%conversation, "/compact failed: {error:#}");
        }
        // They hear how it went; it isn't tried again.
        let compacted = result.map_err(|error| format!("{error:#}"));
        for reply in replies {
            let _ = reply.send(compacted.clone());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests;
