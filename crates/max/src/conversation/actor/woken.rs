//! Wakes from outside the chat: `maxx wake` from something in the group's
//! own VM, and what the VM service says about the VM. Each is a row of
//! the timeline that is never sent: the core it wakes is shown it, and so
//! is every later one, which would otherwise see what Max said and not
//! why. See "Resident programs" in docs/design/jobs.md.

use std::collections::VecDeque;
use std::sync::Arc;

use chrono::Utc;
use color_eyre::eyre::Result;
use max_core::intent::Reason;
use max_core::limits::HOUR;
use max_core::message::{Draft, DraftNode};
use max_core::project::Budgets;
use max_core::render::Mark;
use max_core::run::{Input, Wake};
use tokio::time::Instant;
use tracing::{info, warn};

use super::{Conversation, Does};
use crate::conversation::ingest::{self, By};

/// When the group's programs woke Max, in the last hour, for `/status`.
/// Not a cap.
#[derive(Default)]
pub(super) struct Woken(VecDeque<Instant>);

impl Woken {
    /// Counts a wake at `now`: the hour's, this one too.
    fn count(&mut self, now: Instant) -> usize {
        while self.0.front().is_some_and(|&at| at + HOUR <= now) {
            self.0.pop_front();
        }
        self.0.push_back(now);
        self.0.len()
    }

    /// For `/status`: the wakes in the last hour.
    pub(super) fn summary(&self, now: Instant) -> Option<String> {
        let recent = self.0.iter().filter(|&&at| at + HOUR > now).count();
        (recent > 0).then(|| format!("{recent} this hour"))
    }
}

impl Conversation {
    /// `maxx wake` from a program in the group's VM: what the program is
    /// told.
    pub(super) async fn woken(&mut self, text: &str) -> Result<String> {
        let count = self.woken.count(Instant::now());
        info!(conversation = %self.place.conversation, count, "a program wakes Max");
        self.wake(By::Wake, text).await?;
        Ok("woke Max".to_owned())
    }

    /// The VM service on the group's VM. Stopped, Max isn't told.
    pub(super) async fn vm_notice(&mut self, text: &str) -> Result<()> {
        if self.refuses(Does::STARTS).is_some() {
            return Ok(());
        }
        self.wake(By::Vm, text).await
    }

    /// Wakes Max with `text`, `by` what: a row of the timeline, which
    /// the sender never sees, fed to the running core or the first input
    /// of a new one, and the trigger either way.
    async fn wake(&mut self, by: By, text: &str) -> Result<()> {
        let draft = Draft {
            reply_to: None,
            nodes: vec![DraftNode::Text {
                text: text.trim().to_owned(),
            }],
        };
        let mut conn = self.shared.services.pool.acquire().await?;
        let (now, offset) = (Utc::now(), self.shared.services.offset);
        let said = ingest::said(&mut conn, &self.place, draft, None, None, by, now, offset);
        let said = said.await?;
        drop(conn);
        let Some(message) = said else {
            return Ok(());
        };
        let message = Arc::new(message);
        self.committed(&message);
        let mark = match by {
            By::Vm => Mark::Vm,
            _ => Mark::Wake,
        };
        self.feed(&[(&message, mark)]).await?;
        let wake = Wake {
            ids: vec![message.id],
            reason: Reason::Program,
            item: None,
        };
        match self.core.as_mut() {
            Some(active) => {
                if let Err(rejected) = active.run.input(Input::Wake(wake)) {
                    warn!(turn = %active.turn, %rejected, "a wake didn't fit the core");
                }
            }
            None => self.start_core(wake).await?,
        }
        Ok(())
    }

    /// The most tokens one item may take: the running core's, or the
    /// next one's.
    pub(super) fn single(&self) -> u32 {
        let settings = &self.settings;
        let window = match &self.core {
            Some(active) => Some(active.chosen.window),
            None => self
                .shared
                .models
                .turn(settings.model.as_deref(), settings.effort.as_deref())
                .ok()
                .map(|chosen| chosen.window),
        };
        Budgets::for_window(window.unwrap_or(0)).single
    }
}
