//! The derived-data workers' side of the conversations: every committed
//! row, fanned out to each worker's mailbox. See "派生数据 worker" under
//! "三种角色" in docs/rust-rewrite.md.

use std::sync::Arc;

use max_core::message::Message;
use tokio::sync::mpsc::{self, UnboundedReceiver, UnboundedSender};

use crate::conversation::Place;

/// A row as committed, in the conversation it was committed in.
#[derive(Clone, Debug)]
pub struct Row {
    pub place: Arc<Place>,
    pub message: Arc<Message>,
}

/// The workers' mailboxes. Sending never waits; a worker that stopped is
/// skipped.
#[derive(Debug, Default)]
pub struct Rows(Vec<UnboundedSender<Row>>);

impl Rows {
    pub fn subscribe(&mut self) -> UnboundedReceiver<Row> {
        let (tx, rx) = mpsc::unbounded_channel();
        self.0.push(tx);
        rx
    }

    pub fn send(&self, place: &Arc<Place>, message: &Message) {
        if self.0.is_empty() {
            return;
        }
        let row = Row {
            place: Arc::clone(place),
            message: Arc::new(message.clone()),
        };
        for mailbox in &self.0 {
            let _ = mailbox.send(row.clone());
        }
    }
}
