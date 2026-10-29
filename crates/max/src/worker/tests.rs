//! The driver against a worker that only counts, on a paused clock: this
//! is timing alone, with no database or network to wait for.

use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};

use tokio::time::sleep;

use super::*;

const SECOND: Duration = Duration::from_secs(1);

/// Units are numbers, from 10 in conversations of their tens. A unit fails
/// while `failing` says so, and takes `slow` to run.
#[derive(Default)]
struct Counting {
    scans: Mutex<VecDeque<Vec<u32>>>,
    failing: Mutex<HashSet<u32>>,
    slow: Duration,
    tries: Mutex<Vec<(u32, Attempt, Duration)>>,
    running: AtomicUsize,
    most: AtomicUsize,
    dropped: AtomicUsize,
    start: Mutex<Option<Instant>>,
}

struct Dropped<'a>(&'a AtomicUsize, bool);

impl Drop for Dropped<'_> {
    fn drop(&mut self) {
        if !self.1 {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }
}

impl Derivation for Counting {
    type Input = (u32, Wait);
    type Unit = u32;

    fn on_input(&self, input: (u32, Wait)) -> Vec<(u32, Wait)> {
        vec![input]
    }

    fn conversation(&self, unit: &u32) -> Option<ConversationId> {
        (*unit >= 10).then(|| ConversationId(i64::from(*unit / 10)))
    }

    async fn scan(&self) -> Result<Vec<u32>> {
        Ok(self.scans.lock().unwrap().pop_front().unwrap_or_default())
    }

    async fn run(&self, unit: &u32, attempt: Attempt) -> Result<()> {
        let start = self
            .start
            .lock()
            .unwrap()
            .get_or_insert_with(Instant::now)
            .to_owned();
        let at = Instant::now() - start;
        self.tries.lock().unwrap().push((*unit, attempt, at));
        let now = self.running.fetch_add(1, Ordering::SeqCst) + 1;
        self.most.fetch_max(now, Ordering::SeqCst);
        let mut guard = Dropped(&self.dropped, false);
        sleep(self.slow).await;
        guard.1 = true;
        self.running.fetch_sub(1, Ordering::SeqCst);
        if self.failing.lock().unwrap().contains(unit) {
            return Err(eyre!("{unit} failed"));
        }
        Ok(())
    }
}

const POLICY: Policy = Policy {
    name: "counting",
    concurrent: 2,
    timeout: Duration::from_secs(60),
    retries: &[SECOND, Duration::from_secs(4)],
    rescan: None,
};

/// Drives `worker` while `test` runs, then cancels it and waits for it.
async fn with<T>(
    worker: &Arc<Counting>,
    policy: Policy,
    test: impl AsyncFnOnce(UnboundedSender<(u32, Wait)>) -> T,
) -> T {
    let (inputs, rx) = mpsc::unbounded_channel();
    let cancel = CancellationToken::new();
    let driving = drive(Arc::clone(worker), policy, rx, cancel.clone());
    let testing = async {
        let result = test(inputs).await;
        cancel.cancel();
        result
    };
    tokio::join!(driving, testing).1
}

fn units(worker: &Counting) -> Vec<u32> {
    let mut units: Vec<_> = worker.tries.lock().unwrap().iter().map(|t| t.0).collect();
    units.sort_unstable();
    units
}

#[tokio::test(start_paused = true)]
async fn each_unit_once_and_two_at_a_time() {
    let worker = Arc::new(Counting {
        scans: Mutex::new(VecDeque::from([vec![1, 2, 3]])),
        slow: SECOND,
        ..Counting::default()
    });
    with(&worker, POLICY, async |inputs| {
        // 3 is waiting its turn.
        for unit in [3, 3, 4, 5] {
            inputs.send((unit, Wait::Now)).unwrap();
        }
        sleep(Duration::from_secs(10)).await;
    })
    .await;
    assert_eq!(
        units(&worker),
        [1, 2, 3, 4, 5],
        "the scan's and the inputs', once"
    );
    assert_eq!(worker.most.load(Ordering::SeqCst), 2);
}

#[tokio::test(start_paused = true)]
async fn retries_after_waiting_then_gives_up() {
    let worker = Arc::new(Counting {
        failing: Mutex::new(HashSet::from([7])),
        ..Counting::default()
    });
    with(&worker, POLICY, async |inputs| {
        inputs.send((7, Wait::Now)).unwrap();
        sleep(Duration::from_secs(10)).await;
        // Given up, it is forgotten: the next row brings it back.
        worker.failing.lock().unwrap().clear();
        inputs.send((7, Wait::Now)).unwrap();
        sleep(SECOND).await;
    })
    .await;
    let tries: Vec<_> = worker
        .tries
        .lock()
        .unwrap()
        .iter()
        .map(|(_, attempt, at)| (attempt.number, attempt.last, at.as_secs()))
        .collect();
    assert_eq!(
        tries,
        [(1, false, 0), (2, false, 1), (3, true, 5), (1, false, 10)]
    );
}

#[tokio::test(start_paused = true)]
async fn a_try_that_runs_over_is_dropped() {
    let worker = Arc::new(Counting {
        slow: Duration::from_secs(3600),
        ..Counting::default()
    });
    let policy = Policy {
        timeout: Duration::from_secs(5),
        retries: &[],
        ..POLICY
    };
    with(&worker, policy, async |inputs| {
        inputs.send((1, Wait::Now)).unwrap();
        sleep(Duration::from_secs(6)).await;
        assert_eq!(worker.dropped.load(Ordering::SeqCst), 1, "by its timeout");
        inputs.send((2, Wait::Now)).unwrap();
        sleep(SECOND).await;
    })
    .await;
    assert_eq!(worker.dropped.load(Ordering::SeqCst), 2, "and by the end");
    assert_eq!(units(&worker), [1, 2]);
}

#[tokio::test(start_paused = true)]
async fn scans_again_when_told_to() {
    let worker = Arc::new(Counting {
        scans: Mutex::new(VecDeque::from([vec![1], vec![], vec![2]])),
        ..Counting::default()
    });
    let policy = Policy {
        rescan: Some(Duration::from_secs(60)),
        ..POLICY
    };
    with(&worker, policy, async |_| {
        sleep(Duration::from_secs(150)).await
    })
    .await;
    let at: Vec<_> = worker
        .tries
        .lock()
        .unwrap()
        .iter()
        .map(|t| (t.0, t.2.as_secs()))
        .collect();
    assert_eq!(at, [(1, 0), (2, 120)]);
}

/// When each unit started, in seconds, in order.
fn starts(worker: &Counting) -> Vec<(u32, u64)> {
    let tries = worker.tries.lock().unwrap();
    tries
        .iter()
        .map(|(unit, _, at)| (*unit, at.as_secs()))
        .collect()
}

#[tokio::test(start_paused = true)]
async fn throttled_from_the_first_input_and_debounced_from_the_last() {
    let worker = Arc::new(Counting::default());
    let ten = Duration::from_secs(10);
    with(&worker, POLICY, async |inputs| {
        // The clock starts with the first run: one at once.
        inputs.send((1, Wait::Now)).unwrap();
        sleep(SECOND).await;
        for _ in 0..3 {
            inputs.send((2, Wait::Throttle(ten))).unwrap();
            inputs.send((3, Wait::Debounce(ten))).unwrap();
            sleep(Duration::from_secs(4)).await;
        }
        sleep(Duration::from_secs(30)).await;
    })
    .await;
    assert_eq!(starts(&worker), [(1, 0), (2, 11), (3, 19)]);
}

#[tokio::test(start_paused = true)]
async fn an_input_while_running_runs_it_again_after() {
    let worker = Arc::new(Counting {
        slow: Duration::from_secs(3),
        ..Counting::default()
    });
    with(&worker, POLICY, async |inputs| {
        inputs.send((1, Wait::Now)).unwrap();
        sleep(SECOND).await;
        inputs.send((1, Wait::Now)).unwrap();
        inputs.send((1, Wait::Now)).unwrap();
        sleep(Duration::from_secs(10)).await;
    })
    .await;
    assert_eq!(starts(&worker), [(1, 0), (1, 3)], "once more, not twice");
}

#[tokio::test(start_paused = true)]
async fn one_at_a_time_in_a_conversation_and_urgent_first() {
    let worker = Arc::new(Counting {
        slow: Duration::from_secs(2),
        ..Counting::default()
    });
    let policy = Policy {
        concurrent: 1,
        ..POLICY
    };
    with(&worker, policy, async |inputs| {
        // 11 and 12 share a conversation; 1 and 2 are in none.
        for unit in [11, 12, 1, 2] {
            inputs.send((unit, Wait::Now)).unwrap();
        }
        // Past the limit, but not past 11 in its conversation.
        inputs.send((13, Wait::Urgent)).unwrap();
        inputs.send((2, Wait::Urgent)).unwrap();
        sleep(Duration::from_secs(20)).await;
    })
    .await;
    assert_eq!(starts(&worker), [(11, 0), (2, 0), (13, 2), (12, 4), (1, 6)]);
}
