//! A task's one event to its actor: the result when it ends, or, from
//! `Drop`, when the task is aborted or panics, a fallback, so the actor
//! never waits for a task that is gone.

use tokio::sync::mpsc::UnboundedSender;

use super::Event;

pub struct Report<F: FnOnce() -> Event> {
    mailbox: UnboundedSender<Event>,
    fallback: Option<F>,
}

impl<F: FnOnce() -> Event> Report<F> {
    pub fn new(mailbox: UnboundedSender<Event>, fallback: F) -> Self {
        Self {
            mailbox,
            fallback: Some(fallback),
        }
    }

    pub fn send(mut self, event: Event) {
        self.fallback = None;
        let _ = self.mailbox.send(event);
    }
}

impl<F: FnOnce() -> Event> Drop for Report<F> {
    fn drop(&mut self) {
        if let Some(fallback) = self.fallback.take() {
            let _ = self.mailbox.send(fallback());
        }
    }
}
