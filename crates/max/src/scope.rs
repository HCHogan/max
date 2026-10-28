//! `Scope`: the only way max creates tasks. A scope owns its tasks and
//! takes them down with it, so every task has an owner that ends it; see
//! "运行时结构" in docs/rust-rewrite.md.
//!
//! Each task gets a child of the scope's token. A task that has something
//! to finish (a delivery, a close) watches it and stops at its own next
//! await; the rest are simply aborted. Dropping a scope aborts everything
//! in it at once, without waiting.

use std::future::Future;
use std::time::Duration;

use tokio::task::JoinSet;
use tokio::time::timeout;
use tokio_util::sync::CancellationToken;
use tracing::error;

#[derive(Debug, Default)]
pub struct Scope {
    tasks: JoinSet<()>,
    token: CancellationToken,
}

impl Scope {
    pub fn new() -> Self {
        Self::default()
    }

    /// A scope whose tasks are also cancelled when `parent` is.
    pub fn child(parent: &CancellationToken) -> Self {
        Self {
            tasks: JoinSet::new(),
            token: parent.child_token(),
        }
    }

    /// Runs `task` with a token of its own, which is returned too, to cancel
    /// this one task.
    pub fn spawn<F>(&mut self, task: impl FnOnce(CancellationToken) -> F) -> CancellationToken
    where
        F: Future<Output = ()> + Send + 'static,
    {
        self.reap();
        let token = self.token.child_token();
        self.tasks.spawn(task(token.clone()));
        token
    }

    pub fn token(&self) -> &CancellationToken {
        &self.token
    }

    pub fn is_empty(&self) -> bool {
        self.tasks.is_empty()
    }

    /// Cancels every task and gives them `grace` to stop on their own; then
    /// aborts what's left and waits until it has really stopped, so nothing
    /// of this scope runs once `close` returns.
    pub async fn close(mut self, grace: Duration) {
        self.token.cancel();
        let finished = timeout(grace, async {
            while let Some(result) = self.tasks.join_next().await {
                report(result);
            }
        })
        .await;
        if finished.is_err() {
            self.tasks.shutdown().await;
        }
    }

    /// Collects tasks that have finished, so a long-lived scope doesn't
    /// keep their results.
    fn reap(&mut self) {
        while let Some(result) = self.tasks.try_join_next() {
            report(result);
        }
    }
}

fn report(result: Result<(), tokio::task::JoinError>) {
    if let Err(error) = result
        && error.is_panic()
    {
        error!(%error, "a task panicked");
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU32, Ordering};

    use tokio::sync::oneshot;
    use tokio::time::{Instant, sleep};

    use super::*;

    /// Counts how its tasks ended.
    #[derive(Clone, Default)]
    struct Ends {
        finished: Arc<AtomicU32>,
        dropped: Arc<AtomicU32>,
    }

    struct Guard(Ends, bool);

    impl Drop for Guard {
        fn drop(&mut self) {
            let counter = if self.1 {
                &self.0.finished
            } else {
                &self.0.dropped
            };
            counter.fetch_add(1, Ordering::SeqCst);
        }
    }

    #[tokio::test(start_paused = true)]
    async fn close_lets_willing_tasks_finish_and_aborts_the_rest() {
        let ends = Ends::default();
        let mut scope = Scope::new();
        let polite = ends.clone();
        scope.spawn(move |token| async move {
            let mut guard = Guard(polite, false);
            token.cancelled().await;
            sleep(Duration::from_secs(1)).await;
            guard.1 = true;
        });
        let stubborn = ends.clone();
        scope.spawn(move |_| async move {
            let _guard = Guard(stubborn, false);
            sleep(Duration::from_secs(3600)).await;
        });
        let start = Instant::now();
        scope.close(Duration::from_secs(5)).await;
        assert_eq!(start.elapsed(), Duration::from_secs(5));
        assert_eq!(ends.finished.load(Ordering::SeqCst), 1);
        assert_eq!(ends.dropped.load(Ordering::SeqCst), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn close_returns_as_soon_as_everything_stopped() {
        let mut scope = Scope::new();
        scope.spawn(|token| async move { token.cancelled().await });
        let start = Instant::now();
        scope.close(Duration::from_secs(5)).await;
        assert_eq!(start.elapsed(), Duration::ZERO);
    }

    #[tokio::test]
    async fn dropping_aborts() {
        let ends = Ends::default();
        let (started, running) = oneshot::channel();
        let mut scope = Scope::new();
        let counted = ends.clone();
        scope.spawn(move |_| async move {
            let _guard = Guard(counted, false);
            let _ = started.send(());
            std::future::pending::<()>().await;
        });
        running.await.unwrap();
        drop(scope);
        tokio::task::yield_now().await;
        assert_eq!(ends.dropped.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn one_task_or_a_whole_subtree() {
        let parent = CancellationToken::new();
        let mut scope = Scope::child(&parent);
        let first = scope.spawn(|token| async move { token.cancelled().await });
        let second = scope.spawn(|token| async move { token.cancelled().await });
        first.cancel();
        assert!(!second.is_cancelled());
        parent.cancel();
        assert!(second.is_cancelled());
        scope.close(Duration::from_secs(1)).await;
    }
}
