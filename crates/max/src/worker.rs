//! The derived-data workers' feed: every committed row, fanned out to
//! each worker's mailbox. How a worker schedules its work is its own;
//! see "Derived-data workers" under "The three roles" in docs/rust-rewrite.md.

use std::collections::HashSet;
use std::fmt;
use std::hash::Hash;
use std::sync::{Arc, Mutex, PoisonError};

use max_core::message::Message;
use tokio::sync::mpsc::{self, UnboundedReceiver};

use crate::conversation::Place;

/// A row as committed, in the conversation it was committed in.
#[derive(Clone, Debug)]
pub struct Row {
    /// Where it was committed.
    pub place: Arc<Place>,
    pub message: Arc<Message>,
}

type Mailbox = Box<dyn Fn(Row) + Send + Sync>;

/// The workers' mailboxes. Sending never waits; a worker that stopped is
/// skipped.
#[derive(Default)]
pub struct Rows(Vec<Mailbox>);

/// By how many workers take rows.
impl fmt::Debug for Rows {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("Rows").field(&self.0.len()).finish()
    }
}

impl Rows {
    /// A mailbox that gets every row, as a `T`.
    pub fn subscribe<T: From<Row> + Send + 'static>(&mut self) -> UnboundedReceiver<T> {
        let (mailbox, rx) = mpsc::unbounded_channel();
        self.0.push(Box::new(move |row| {
            let _ = mailbox.send(T::from(row));
        }));
        rx
    }

    /// Gives every worker the row committed at `place`.
    pub fn send(&self, place: &Arc<Place>, message: &Arc<Message>) {
        if self.0.is_empty() {
            return;
        }
        let row = Row {
            place: Arc::clone(place),
            message: Arc::clone(message),
        };
        for mailbox in &self.0 {
            mailbox(row.clone());
        }
    }
}

/// The units a worker has in flight, so that one that comes again
/// meanwhile isn't started twice. A unit is among them for as long as its
/// [`Claim`] lives: a task that ends, one that panics and one that is
/// aborted let go of it alike.
#[derive(Debug)]
pub struct Busy<K>(Arc<Mutex<HashSet<K>>>);

impl<K> Default for Busy<K> {
    fn default() -> Self {
        Self(Arc::default())
    }
}

impl<K: Clone + Eq + Hash> Busy<K> {
    /// Takes `key`, unless something has it.
    pub fn claim(&self, key: &K) -> Option<Claim<K>> {
        let mut keys = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        keys.insert(key.clone()).then(|| Claim {
            busy: Arc::clone(&self.0),
            key: key.clone(),
        })
    }
}

/// A unit in flight: dropping it lets the unit be started again.
#[derive(Debug)]
pub struct Claim<K: Eq + Hash> {
    busy: Arc<Mutex<HashSet<K>>>,
    key: K,
}

impl<K: Eq + Hash> Drop for Claim<K> {
    fn drop(&mut self) {
        let mut keys = self.busy.lock().unwrap_or_else(PoisonError::into_inner);
        keys.remove(&self.key);
    }
}
