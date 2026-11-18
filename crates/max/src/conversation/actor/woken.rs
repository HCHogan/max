//! Wakes from outside the chat: `maxx wake` from something in the group's
//! own VM, what the VM service says about the VM, and a question or an
//! answer from another conversation (`asking`). See "Resident programs"
//! in docs/rust-rewrite.md.

use std::collections::VecDeque;

use color_eyre::eyre::Result;
use max_core::intent::Reason;
use max_core::limits::HOUR;
use max_core::project::Budgets;
use tokio::time::Instant;
use tracing::info;

use super::{Conversation, Does};
use crate::conversation::Heard;
use crate::conversation::notice::Notice;

/// When the group's programs woke Max, in the last hour. Not a cap: Max
/// is shown the count with each wake, so a program that wakes it too
/// often shows even in a turn that didn't see the other wakes, which
/// aren't rows of the timeline.
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
        let item = Notice::Woken { text, count }.item(self.single());
        self.wake_with(Reason::Program, item).await?;
        Ok("woke Max".to_owned())
    }

    /// What Max hears from outside its chat: each a wake, in the running
    /// core or a new one.
    pub(super) async fn heard(&mut self, heard: Heard) -> Result<()> {
        match heard {
            Heard::Vm(text) => self.vm_notice(&text).await,
            Heard::Asked(question) => self.asked(question).await,
            Heard::Answered(answer) => self.answered(answer).await,
        }
    }

    /// The VM service on the group's VM. Stopped, Max isn't told.
    async fn vm_notice(&mut self, text: &str) -> Result<()> {
        if self.refuses(Does::STARTS).is_some() {
            return Ok(());
        }
        let item = Notice::Vm { text }.item(self.single());
        self.wake_with(Reason::Program, item).await
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
