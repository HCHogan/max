//! The connection to wxdesk, which the listener keeps and the sender
//! borrows: one at a time, as wxdesk's window is one.

use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use tokio::sync::oneshot;
use wxdesk_proto::{Commands, ToDriver};

/// How long a command may wait for wxdesk's answer: behind a picture it
/// copies, say, or a private chat it reads.
const ANSWER: Duration = Duration::from_secs(180);

/// Why a command didn't go through, or may not have.
#[derive(Debug)]
pub enum Failed {
    /// wxdesk said no, or it never reached wxdesk.
    Refused(String),
    /// wxdesk's answer never came: it may have gone out.
    Unknown(String),
}

/// The connection to wxdesk, while there is one.
pub struct Link {
    /// Where wxdesk listens.
    pub address: String,
    /// What it wants first.
    pub token: String,
    /// Where commands go, while connected.
    commands: tokio::sync::Mutex<Option<Commands>>,
    /// The commands sent and not answered, by id: told their error, if
    /// any.
    waiting: Mutex<HashMap<u64, oneshot::Sender<Option<String>>>>,
    next: AtomicU64,
}

impl std::fmt::Debug for Link {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Link")
            .field("address", &self.address)
            .finish_non_exhaustive()
    }
}

impl Link {
    /// Not connected yet: the listener connects.
    #[must_use]
    pub fn new(address: String, token: String) -> Self {
        Self {
            address,
            token,
            commands: tokio::sync::Mutex::new(None),
            waiting: Mutex::default(),
            next: AtomicU64::new(1),
        }
    }

    /// A connection is up: commands go to it.
    pub async fn connected(&self, commands: Commands) {
        *self.commands.lock().await = Some(commands);
    }

    /// The connection is down: what waits on it won't hear back.
    pub async fn lost(&self) {
        *self.commands.lock().await = None;
        self.waiting().clear();
    }

    /// wxdesk's answer to the command `id`.
    pub fn answered(&self, id: u64, error: Option<String>) {
        if let Some(waiting) = self.waiting().remove(&id) {
            let _ = waiting.send(error);
        }
    }

    /// Sends the command `make` makes of an id, and waits for its answer.
    ///
    /// # Errors
    ///
    /// If it couldn't be sent, wxdesk refused it, or its answer didn't come.
    pub async fn call(&self, make: impl FnOnce(u64) -> ToDriver) -> Result<(), Failed> {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.waiting().insert(id, tx);
        {
            let mut commands = self.commands.lock().await;
            let sent = match commands.as_mut() {
                Some(commands) => commands.send(&make(id)).await.map_err(|e| e.to_string()),
                None => Err("WeChat's driver isn't connected".to_owned()),
            };
            if let Err(error) = sent {
                self.waiting().remove(&id);
                return Err(Failed::Refused(error));
            }
        }
        match tokio::time::timeout(ANSWER, rx).await {
            Ok(Ok(None)) => Ok(()),
            Ok(Ok(Some(error))) => Err(Failed::Refused(error)),
            Ok(Err(_)) => Err(Failed::Unknown(
                "the connection to WeChat's driver dropped before it answered".to_owned(),
            )),
            Err(_) => {
                self.waiting().remove(&id);
                Err(Failed::Unknown(format!(
                    "WeChat's driver didn't answer within {} seconds",
                    ANSWER.as_secs()
                )))
            }
        }
    }

    fn waiting(&self) -> std::sync::MutexGuard<'_, HashMap<u64, oneshot::Sender<Option<String>>>> {
        self.waiting
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}
