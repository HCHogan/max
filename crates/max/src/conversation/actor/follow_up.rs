//! What the core's model calls say, and taking back the one in flight
//! when whoever it answers goes on talking: people finish an @ in a second
//! message 3 to 38 seconds later (2026-11-04).

use std::time::Duration;

use color_eyre::eyre::Result;
use max_core::message::{Content, Node};
use max_db::ledger;
use tokio::task::AbortHandle;
use tokio::time::Instant;
use tracing::{info, warn};

use super::Conversation;
use crate::conversation::{TaskId, ingest};

/// How long after someone addresses Max their next message may finish
/// what they meant, and start over the model call in flight.
const FOLLOW_UP: Duration = Duration::from_secs(60);
/// The most times a model call starts over before one finishes.
const MOST_RESTARTS: u32 = 3;

/// What a core's model calls have said, and the call in flight: for a
/// row's segment number, for the words a call cut off had got out, and to
/// tell whether the call in flight may still be taken back.
#[derive(Default)]
pub(super) struct Voice {
    /// What the model call in flight has said, segment by segment.
    said: Vec<String>,
    /// How many segments the core has said.
    segments: i32,
    /// The model call in flight, if one is.
    calling: Option<Calling>,
    /// How many times the model call has started over since one finished.
    restarts: u32,
    /// When the core last said something.
    said_at: Option<Instant>,
}

/// A model call in flight.
struct Calling {
    task: TaskId,
    abort: AbortHandle,
    /// How many segments the core had said when it started.
    segments: i32,
}

impl Voice {
    /// A model call starts.
    pub(super) fn calls(&mut self, task: TaskId, abort: AbortHandle) {
        let segments = self.segments;
        self.calling = Some(Calling {
            task,
            abort,
            segments,
        });
    }

    /// The call in flight said a segment: its number among the core's.
    pub(super) fn says(&mut self, source: String) -> i32 {
        self.said.push(source);
        self.segments += 1;
        self.said_at = Some(Instant::now());
        self.segments
    }

    /// The call in flight ended by itself.
    pub(super) fn called(&mut self) {
        self.calling = None;
        self.restarts = 0;
    }

    /// Its output is the run's now: nothing of it is left to give.
    pub(super) fn taken(&mut self) {
        self.said.clear();
    }

    /// What a call that was cut off had said, if anything.
    pub(super) fn cut_off(&self) -> Option<String> {
        (!self.said.is_empty()).then(|| self.said.join("\n\n"))
    }

    /// Whether the call in flight may be taken back for someone who
    /// addressed Max at `since`: it has said nothing yet, hasn't started
    /// over too often, and the core hasn't spoken since they did.
    fn may_start_over(&self, since: Instant) -> bool {
        let calling = self.calling.as_ref();
        calling.is_some_and(|calling| self.segments == calling.segments)
            && self.restarts < MOST_RESTARTS
            && !self.said_at.is_some_and(|said| said > since)
    }
}

impl Conversation {
    /// Starts the model call in flight over when `committed` looks like
    /// the rest of what its sender meant: they addressed Max in the last
    /// [`FOLLOW_UP`], haven't been answered since, and aren't talking to
    /// someone else now. Nothing is lost: the call hasn't said anything,
    /// tools run only after it, and the next one is the same request with
    /// the row added, which the provider has cached. Other wakes, a
    /// program's or the classifier's, wait for the next call: they don't
    /// change the answer someone is waiting for.
    pub(super) async fn follow_up(&mut self, committed: &ingest::Committed) -> Result<()> {
        let now = Instant::now();
        let sender = committed.sender.identity;
        self.addressed.retain(|_, at| now < *at + FOLLOW_UP);
        let since = self.addressed.get(&sender).copied();
        if committed.direct.is_some() {
            self.addressed.insert(sender, now);
        }
        let Some(since) = since else {
            return Ok(());
        };
        let Some(active) = &self.core else {
            return Ok(());
        };
        if !active.voice.may_start_over(since)
            || (committed.direct.is_none() && !self.own_words(committed).await?)
        {
            return Ok(());
        }
        self.start_over();
        Ok(())
    }

    /// Whether a row that isn't to Max isn't to anyone else either: it
    /// mentions nobody, and quotes nobody but its sender.
    async fn own_words(&self, committed: &ingest::Committed) -> Result<bool> {
        let Content::Message { reply_to, nodes } = &committed.message.content else {
            return Ok(false);
        };
        if nodes
            .iter()
            .any(|node| matches!(node, Node::Mention { .. }))
        {
            return Ok(false);
        }
        let Some(target) = reply_to else {
            return Ok(true);
        };
        let mut conn = self.shared.services.pool.acquire().await?;
        let row = ledger::row(&mut conn, self.place.conversation, *target).await?;
        Ok(row.is_some_and(|row| row.message.sender.identity == committed.sender.identity))
    }

    /// Takes back the model call in flight; the next step makes it again.
    fn start_over(&mut self) {
        let Some(active) = self.core.as_mut() else {
            return;
        };
        let Some(calling) = active.voice.calling.take() else {
            return;
        };
        if let Err(rejected) = active.run.retract() {
            warn!(turn = %active.turn, %rejected, "couldn't take back a model call");
            active.voice.calling = Some(calling);
            return;
        }
        calling.abort.abort();
        active.live.remove(&calling.task);
        active.voice.restarts += 1;
        info!(conversation = %self.place.conversation, turn = %active.turn, restarts = active.voice.restarts, "a model call starts over");
    }
}
