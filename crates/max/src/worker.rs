//! The derived-data workers: every committed row, fanned out to each
//! worker's mailbox, and the driver that runs a worker's units. See
//! "派生数据 worker" under "三种角色" in docs/rust-rewrite.md.

use std::collections::{BTreeMap, HashSet, VecDeque};
use std::fmt::Debug;
use std::future::Future;
use std::hash::Hash;
use std::sync::Arc;
use std::time::Duration;

use color_eyre::eyre::{Result, eyre};
use max_core::message::Message;
use tokio::sync::mpsc::{self, UnboundedReceiver, UnboundedSender};
use tokio::time::{Instant, Interval, MissedTickBehavior, interval_at, sleep_until, timeout};
use tokio_util::sync::CancellationToken;
use tracing::{debug, warn};

use crate::conversation::Place;
use crate::scope::Scope;

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

/// A worker: what to do with a row, how to find what it missed, and how
/// to do one unit of work.
pub trait Derivation: Send + Sync + 'static {
    /// A committed row, or another worker's output.
    type Input: Send + 'static;
    /// One unit of work, and what tells two apart: one already waiting or
    /// running isn't added again.
    type Unit: Clone + Eq + Hash + Debug + Send + Sync + 'static;

    /// The units an input calls for. No I/O.
    fn on_input(&self, input: Self::Input) -> Vec<Self::Unit>;

    /// What is missing from the worker's own output, at the start and
    /// then every `rescan`.
    fn scan(&self) -> impl Future<Output = Result<Vec<Self::Unit>>> + Send;

    /// Does one unit, in one transaction. A unit may come again, from a
    /// scan or after a restart, so doing it twice must be harmless.
    fn run(&self, unit: &Self::Unit, attempt: Attempt) -> impl Future<Output = Result<()>> + Send;
}

/// Which try this is, from 1; the last gets no other.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Attempt {
    pub number: usize,
    pub last: bool,
}

/// How a worker runs: constants in its module, not settings.
#[derive(Clone, Copy, Debug)]
pub struct Policy {
    pub name: &'static str,
    /// Units at a time.
    pub concurrent: usize,
    /// For each try; one that runs over has failed.
    pub timeout: Duration,
    /// How long to wait before each retry: `[1s, 4s]` is three tries.
    pub retries: &'static [Duration],
    /// How often to scan again after the first; None for never.
    pub rescan: Option<Duration>,
}

/// Runs `worker` until `cancel`: units from its inputs and its scans, at
/// most `concurrent` at a time, each retried as the policy says and then
/// given up with a log line. Units still running at the end are dropped;
/// their transactions roll back, and a later scan finds them.
pub async fn drive<D: Derivation>(
    worker: Arc<D>,
    policy: Policy,
    mut inputs: UnboundedReceiver<D::Input>,
    cancel: CancellationToken,
) {
    let mut queue = Queue::default();
    let mut units = Scope::new();
    let (done_tx, mut done) = mpsc::unbounded_channel();
    let mut running = 0;
    let mut rescans = policy.rescan.map(|every| {
        let mut rescans = interval_at(Instant::now() + every, every);
        rescans.set_missed_tick_behavior(MissedTickBehavior::Delay);
        rescans
    });
    queue.scanned(policy.name, worker.scan().await);
    loop {
        while running < policy.concurrent
            && let Some((unit, number)) = queue.ready.pop_front()
        {
            running += 1;
            let attempt = Attempt {
                number,
                last: number > policy.retries.len(),
            };
            let worker = Arc::clone(&worker);
            let done = done_tx.clone();
            units.spawn(move |_| async move {
                let result = match timeout(policy.timeout, worker.run(&unit, attempt)).await {
                    Ok(result) => result,
                    Err(_) => Err(eyre!("took more than {:?}", policy.timeout)),
                };
                let _ = done.send((unit, attempt, result));
            });
        }
        let retry = queue.next_retry();
        tokio::select! {
            () = cancel.cancelled() => break,
            Some(input) = inputs.recv() => {
                for unit in worker.on_input(input) {
                    queue.add(unit);
                }
            }
            Some((unit, attempt, result)) = done.recv() => {
                running -= 1;
                match result {
                    Ok(()) => queue.forget(&unit),
                    Err(error) if attempt.last => {
                        warn!(worker = policy.name, ?unit, tries = attempt.number, "gave up: {error:#}");
                        queue.forget(&unit);
                    }
                    Err(error) => {
                        debug!(worker = policy.name, ?unit, try = attempt.number, "failed: {error:#}");
                        let wait = policy.retries[attempt.number - 1];
                        queue.later(unit, attempt.number + 1, Instant::now() + wait);
                    }
                }
            }
            () = sleep_until(retry.unwrap_or_else(Instant::now)), if retry.is_some() => {
                queue.due(Instant::now());
            }
            () = tick(rescans.as_mut()) => {
                queue.scanned(policy.name, worker.scan().await);
            }
        }
    }
    units.close(Duration::ZERO).await;
}

/// The next tick, or never.
async fn tick(interval: Option<&mut Interval>) {
    match interval {
        Some(interval) => {
            interval.tick().await;
        }
        None => std::future::pending().await,
    }
}

/// The units waiting to run, now or after a failure, and every unit
/// waiting or running.
struct Queue<U> {
    ready: VecDeque<(U, usize)>,
    retrying: BTreeMap<(Instant, u64), (U, usize)>,
    known: HashSet<U>,
    order: u64,
}

impl<U> Default for Queue<U> {
    fn default() -> Self {
        Self {
            ready: VecDeque::new(),
            retrying: BTreeMap::new(),
            known: HashSet::new(),
            order: 0,
        }
    }
}

impl<U: Clone + Eq + Hash + Debug> Queue<U> {
    fn add(&mut self, unit: U) {
        if self.known.insert(unit.clone()) {
            self.ready.push_back((unit, 1));
        }
    }

    fn scanned(&mut self, worker: &str, scanned: Result<Vec<U>>) {
        match scanned {
            Ok(units) => units.into_iter().for_each(|unit| self.add(unit)),
            Err(error) => warn!(worker, "a scan failed: {error:#}"),
        }
    }

    fn forget(&mut self, unit: &U) {
        self.known.remove(unit);
    }

    fn later(&mut self, unit: U, number: usize, at: Instant) {
        self.order += 1;
        self.retrying.insert((at, self.order), (unit, number));
    }

    fn next_retry(&self) -> Option<Instant> {
        self.retrying.first_key_value().map(|((at, _), _)| *at)
    }

    fn due(&mut self, now: Instant) {
        while let Some(entry) = self.retrying.first_entry()
            && entry.key().0 <= now
        {
            self.ready.push_back(entry.remove());
        }
    }
}

#[cfg(test)]
mod tests;
