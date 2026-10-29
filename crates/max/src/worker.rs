//! The derived-data workers: every committed row, fanned out to each
//! worker's mailbox, and the driver that runs a worker's units. See
//! "派生数据 worker" under "三种角色" in docs/rust-rewrite.md.

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::fmt::Debug;
use std::future::Future;
use std::hash::Hash;
use std::sync::Arc;
use std::time::Duration;

use color_eyre::eyre::{Result, eyre};
use max_core::ids::ConversationId;
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
    /// One unit of work, and what tells two apart: one already waiting
    /// isn't added again, and one running runs once more after.
    type Unit: Clone + Eq + Hash + Debug + Send + Sync + 'static;

    /// The units an input calls for, and when. No I/O.
    fn on_input(&self, input: Self::Input) -> Vec<(Self::Unit, Wait)>;

    /// The units of one conversation run one at a time; None, any number.
    fn conversation(&self, _unit: &Self::Unit) -> Option<ConversationId> {
        None
    }

    /// What is missing from the worker's own output, at the start and
    /// then every `rescan`. The units run in turn.
    fn scan(&self) -> impl Future<Output = Result<Vec<Self::Unit>>> + Send;

    /// Does one unit, in one transaction. A unit may come again, from a
    /// scan or after a restart, so doing it twice must be harmless.
    fn run(&self, unit: &Self::Unit, attempt: Attempt) -> impl Future<Output = Result<()>> + Send;
}

/// When a unit runs, after the input that calls for it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Wait {
    /// In turn.
    Now,
    /// First, past the limit of units at a time: someone waits for it.
    Urgent,
    /// After this long; inputs meanwhile change nothing.
    Throttle(Duration),
    /// Once inputs stop for this long.
    Debounce(Duration),
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
    /// Units at a time, urgent ones aside.
    pub concurrent: usize,
    /// For each try; one that runs over has failed.
    pub timeout: Duration,
    /// How long to wait before each retry: `[1s, 4s]` is three tries.
    pub retries: &'static [Duration],
    /// How often to scan again after the first; None for never.
    pub rescan: Option<Duration>,
}

/// Runs `worker` until `cancel`: units from its inputs and its scans, when
/// their waits say, at most `concurrent` at a time and one at a time in a
/// conversation, each retried as the policy says and then given up with a
/// log line. Units still running at the end are dropped; their
/// transactions roll back, and a later scan or input brings them back.
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
    let mut busy = HashSet::new();
    let mut rescans = policy.rescan.map(|every| {
        let mut rescans = interval_at(Instant::now() + every, every);
        rescans.set_missed_tick_behavior(MissedTickBehavior::Delay);
        rescans
    });
    queue.scanned(policy.name, worker.scan().await);
    loop {
        queue.due(Instant::now());
        let starting = queue.start(|unit, urgent| {
            let conversation = worker.conversation(unit);
            if conversation.is_some_and(|c| busy.contains(&c))
                || (!urgent && running >= policy.concurrent)
            {
                return false;
            }
            running += 1;
            busy.extend(conversation);
            true
        });
        for (unit, number) in starting {
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
        let next = queue.next_due();
        tokio::select! {
            () = cancel.cancelled() => break,
            Some(input) = inputs.recv() => {
                let now = Instant::now();
                for (unit, wait) in worker.on_input(input) {
                    queue.add(unit, wait, now);
                }
            }
            Some((unit, attempt, result)) = done.recv() => {
                running -= 1;
                if let Some(conversation) = worker.conversation(&unit) {
                    busy.remove(&conversation);
                }
                let again = queue.finished(&unit);
                let now = Instant::now();
                match result {
                    Err(error) if !attempt.last => {
                        debug!(worker = policy.name, ?unit, try = attempt.number, "failed: {error:#}");
                        let wait = policy.retries[attempt.number - 1];
                        queue.wait(unit, attempt.number + 1, now + wait);
                        // The retry covers what came meanwhile.
                        continue;
                    }
                    Err(error) => {
                        warn!(worker = policy.name, ?unit, tries = attempt.number, "gave up: {error:#}");
                    }
                    Ok(()) => {}
                }
                if let Some(wait) = again {
                    queue.add(unit, wait, now);
                }
            }
            () = sleep_until(next.unwrap_or_else(Instant::now)), if next.is_some() => {}
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

/// Where each unit is: in turn, waiting for its time, or running.
struct Queue<U> {
    units: HashMap<U, State>,
    ready: VecDeque<Ready<U>>,
    waiting: BTreeMap<(Instant, u64), (U, usize)>,
    order: u64,
}

#[derive(Clone, Copy)]
enum State {
    Ready,
    Waiting((Instant, u64)),
    /// With the wait of the run wanted after this one, if any.
    Running(Option<Wait>),
}

struct Ready<U> {
    unit: U,
    number: usize,
    urgent: bool,
}

impl<U> Default for Queue<U> {
    fn default() -> Self {
        Self {
            units: HashMap::new(),
            ready: VecDeque::new(),
            waiting: BTreeMap::new(),
            order: 0,
        }
    }
}

impl<U: Clone + Eq + Hash + Debug> Queue<U> {
    fn add(&mut self, unit: U, wait: Wait, now: Instant) {
        match self.units.get(&unit).copied() {
            None => match wait {
                Wait::Now => self.ready(unit, 1, false),
                Wait::Urgent => self.ready(unit, 1, true),
                Wait::Throttle(after) | Wait::Debounce(after) => self.wait(unit, 1, now + after),
            },
            Some(State::Ready) => {
                if wait == Wait::Urgent
                    && let Some(at) = self.ready.iter().position(|ready| ready.unit == unit)
                    && let Some(mut ready) = self.ready.remove(at)
                {
                    ready.urgent = true;
                    self.ready.push_front(ready);
                }
            }
            Some(State::Waiting(key)) => {
                let later = match wait {
                    Wait::Now | Wait::Urgent => None,
                    Wait::Throttle(_) => return,
                    // Never sooner: it may be waiting to retry.
                    Wait::Debounce(after) if now + after > key.0 => Some(now + after),
                    Wait::Debounce(_) => return,
                };
                let Some((unit, number)) = self.waiting.remove(&key) else {
                    return;
                };
                match later {
                    Some(at) => self.wait(unit, number, at),
                    None => self.ready(unit, number, wait == Wait::Urgent),
                }
            }
            Some(State::Running(again)) => {
                let wait = if again == Some(Wait::Urgent) {
                    Wait::Urgent
                } else {
                    wait
                };
                self.units.insert(unit, State::Running(Some(wait)));
            }
        }
    }

    fn scanned(&mut self, worker: &str, scanned: Result<Vec<U>>) {
        match scanned {
            Ok(units) => {
                let now = Instant::now();
                for unit in units {
                    self.add(unit, Wait::Now, now);
                }
            }
            Err(error) => warn!(worker, "a scan failed: {error:#}"),
        }
    }

    fn ready(&mut self, unit: U, number: usize, urgent: bool) {
        self.units.insert(unit.clone(), State::Ready);
        let ready = Ready {
            unit,
            number,
            urgent,
        };
        if urgent {
            self.ready.push_front(ready);
        } else {
            self.ready.push_back(ready);
        }
    }

    fn wait(&mut self, unit: U, number: usize, at: Instant) {
        self.order += 1;
        let key = (at, self.order);
        self.units.insert(unit.clone(), State::Waiting(key));
        self.waiting.insert(key, (unit, number));
    }

    fn next_due(&self) -> Option<Instant> {
        self.waiting.first_key_value().map(|((at, _), _)| *at)
    }

    /// Puts the units whose time has come in turn.
    fn due(&mut self, now: Instant) {
        while let Some(entry) = self.waiting.first_entry()
            && entry.key().0 <= now
        {
            let (unit, number) = entry.remove();
            self.ready(unit, number, false);
        }
    }

    /// The units in turn that `may` start, now running, with their try.
    fn start(&mut self, mut may: impl FnMut(&U, bool) -> bool) -> Vec<(U, usize)> {
        let mut starting = Vec::new();
        let mut kept = VecDeque::new();
        while let Some(ready) = self.ready.pop_front() {
            if may(&ready.unit, ready.urgent) {
                self.units.insert(ready.unit.clone(), State::Running(None));
                starting.push((ready.unit, ready.number));
            } else {
                kept.push_back(ready);
            }
        }
        self.ready = kept;
        starting
    }

    /// Forgets a unit that ran, and says if another run was wanted.
    fn finished(&mut self, unit: &U) -> Option<Wait> {
        match self.units.remove(unit) {
            Some(State::Running(again)) => again,
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests;
