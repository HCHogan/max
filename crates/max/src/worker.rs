//! The derived-data workers' feed: every committed row, fanned out to
//! each worker's mailbox. How a worker schedules its work is its own;
//! see "派生数据 worker" under "三种角色" in docs/rust-rewrite.md.

use std::sync::Arc;

use max_core::message::Message;
use tokio::sync::mpsc::{self, UnboundedReceiver};

use crate::conversation::Place;

/// A row as committed, in the conversation it was committed in.
#[derive(Clone, Debug)]
pub struct Row {
    pub place: Arc<Place>,
    pub message: Arc<Message>,
}

type Mailbox = Box<dyn Fn(Row) + Send + Sync>;

/// The workers' mailboxes. Sending never waits; a worker that stopped is
/// skipped.
#[derive(Default)]
pub struct Rows(Vec<Mailbox>);

impl Rows {
    /// A mailbox that gets every row, as a `T`.
    pub fn subscribe<T: From<Row> + Send + 'static>(&mut self) -> UnboundedReceiver<T> {
        let (tx, rx) = mpsc::unbounded_channel();
        self.0.push(Box::new(move |row| {
            let _ = tx.send(T::from(row));
        }));
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
            mailbox(row.clone());
        }
    }
}
