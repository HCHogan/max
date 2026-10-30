//! The groups' VMs: one per conversation, started when a tool first needs
//! it and stopped once it has gone unused for a while. The VM service owns
//! them all; a tool call borrows a VM's SSH connection. See "VM 进程" in
//! docs/rust-rewrite.md.

mod machine;
pub mod ssh;
#[cfg(test)]
mod webread_tests;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use color_eyre::eyre::Result;
use max_core::ids::ConversationId;
use tokio::sync::mpsc::{self, UnboundedReceiver, UnboundedSender};
use tokio::sync::oneshot;
use tokio::time::{Instant, MissedTickBehavior, interval, timeout};
use tracing::{info, warn};

use self::machine::{BOOT, Booted, Guest, Machine};
use self::ssh::{Command, Connection, Input};
use crate::config;
use crate::mcp::{self, Sessions};
use crate::scope::Scope;

/// How often idle and dead VMs are looked for.
const SWEEP: Duration = Duration::from_secs(60);

/// Where `conversation`'s /work is on the host, under the VMs' `dir`,
/// whether or not its VM runs.
pub fn work(dir: &Path, conversation: ConversationId) -> PathBuf {
    dir.join(conversation.0.to_string()).join("work")
}

/// A handle to the VM service; it stops once every handle is gone.
#[derive(Clone)]
pub struct Vms {
    requests: UnboundedSender<Request>,
    sessions: Sessions,
}

struct Request {
    conversation: ConversationId,
    reply: oneshot::Sender<Result<Vm, String>>,
}

/// A running VM, lent to a tool call. It isn't idle while one is held.
#[derive(Clone)]
pub struct Vm {
    connection: Arc<Connection>,
    stops: UnboundedSender<String>,
    work: Arc<PathBuf>,
    _lent: Arc<()>,
}

impl Vms {
    /// Starts the service in `scope`.
    pub fn start(config: config::Vm, scope: &mut Scope) -> Result<Self> {
        let guest = Guest::load(&config.guest)?;
        std::fs::create_dir_all(&config.dir)?;
        let (requests, rx) = mpsc::unbounded_channel();
        let sessions = Sessions::default();
        let served = sessions.clone();
        scope.spawn(move |_| run(config, guest, served, rx));
        Ok(Self { requests, sessions })
    }

    /// The MCP service's sessions, which programs and background agents
    /// in the VMs call through.
    pub fn sessions(&self) -> &Sessions {
        &self.sessions
    }

    /// The conversation's VM, started if it isn't running; or why there
    /// isn't one.
    pub async fn get(&self, conversation: ConversationId) -> Result<Vm, String> {
        let (reply, answer) = oneshot::channel();
        let gone = || "VM 服务停了".to_owned();
        self.requests
            .send(Request {
                conversation,
                reply,
            })
            .map_err(|_| gone())?;
        answer.await.map_err(|_| gone())?
    }
}

impl Vm {
    /// Starts `line` in the guest's shell with `input`; `line` must start
    /// the unit `unit`, from `Vm::unit`.
    pub async fn command(&self, unit: String, line: &str, input: &[u8]) -> Result<Command> {
        Command::start(&self.connection, unit, line, input, self.stops.clone()).await
    }

    /// Like [`Vm::command`], with the command's input left open; see
    /// [`Command::open`].
    pub async fn open(&self, unit: String, line: &str) -> Result<(Command, Input)> {
        Command::open(&self.connection, unit, line, self.stops.clone()).await
    }

    /// A name for a command's unit, unique while max runs. A VM doesn't
    /// outlive max.
    pub fn unit() -> String {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        format!("max-{}", NEXT.fetch_add(1, Ordering::Relaxed))
    }

    pub fn connection(&self) -> &Connection {
        &self.connection
    }

    /// The host's side of the guest's /work.
    pub fn work(&self) -> &std::path::Path {
        &self.work
    }
}

enum State {
    Booting {
        slot: usize,
        waiting: Vec<oneshot::Sender<Result<Vm, String>>>,
    },
    Running(Box<Running>),
}

struct Running {
    slot: usize,
    machine: Machine,
    connection: Arc<Connection>,
    stops: UnboundedSender<String>,
    /// The stopper, which stops the units of commands dropped early, and
    /// the VM's MCP service.
    _tasks: Scope,
    work: Arc<PathBuf>,
    lent: Arc<()>,
    idle_since: Instant,
}

impl Running {
    fn lend(&mut self) -> Vm {
        self.idle_since = Instant::now();
        Vm {
            connection: Arc::clone(&self.connection),
            stops: self.stops.clone(),
            work: Arc::clone(&self.work),
            _lent: Arc::clone(&self.lent),
        }
    }

    fn lent(&self) -> bool {
        Arc::strong_count(&self.lent) > 1
    }

    fn dead(&mut self) -> bool {
        self.machine.exited() || self.connection.is_closed()
    }
}

async fn run(
    config: config::Vm,
    guest: Guest,
    sessions: Sessions,
    mut requests: UnboundedReceiver<Request>,
) {
    let config = Arc::new(config);
    let guest = Arc::new(guest);
    let idle = Duration::from_secs(config.idle_minutes * 60);
    let mut vms: HashMap<ConversationId, State> = HashMap::new();
    let mut free: Vec<usize> = (0..config.slots.len()).rev().collect();
    let mut boots = Scope::new();
    let (booted_tx, mut booted) =
        mpsc::unbounded_channel::<(ConversationId, Result<Booted, String>)>();
    let mut sweep = interval(SWEEP);
    sweep.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            request = requests.recv() => {
                let Some(Request { conversation, reply }) = request else { break };
                match vms.get_mut(&conversation) {
                    Some(State::Running(running)) => {
                        if !running.dead() {
                            let _ = reply.send(Ok(running.lend()));
                            continue;
                        }
                        warn!(%conversation, "a VM had stopped by itself");
                        free.push(running.slot);
                        vms.remove(&conversation);
                    }
                    Some(State::Booting { waiting, .. }) => {
                        waiting.push(reply);
                        continue;
                    }
                    None => {}
                }
                let Some(slot) = free.pop().or_else(|| evict(&mut vms)) else {
                    let _ = reply.send(Err("同时开着的 VM 太多了，过一会儿再试。".into()));
                    continue;
                };
                vms.insert(conversation, State::Booting { slot, waiting: vec![reply] });
                let dir = config.dir.join(conversation.0.to_string());
                let (config, guest, booted) = (Arc::clone(&config), Arc::clone(&guest), booted_tx.clone());
                boots.spawn(move |_| async move {
                    let started = Instant::now();
                    let slot = &config.slots[slot];
                    let result = match timeout(BOOT + Duration::from_secs(10), machine::boot(&config, &guest, &dir, slot)).await {
                        Ok(result) => result.map_err(|error| format!("{error:#}")),
                        Err(_) => Err(format!("the VM didn't boot within {BOOT:?}")),
                    };
                    match &result {
                        Ok(_) => info!(%conversation, tap = %slot.tap, took = ?started.elapsed(), "a VM booted"),
                        Err(error) => warn!(%conversation, %error, "a VM didn't boot"),
                    }
                    let _ = booted.send((conversation, result));
                });
            }
            Some((conversation, result)) = booted.recv() => {
                let Some(State::Booting { slot, waiting }) = vms.remove(&conversation) else {
                    continue;
                };
                match result {
                    Ok(Booted { machine, connection, mcp }) => {
                        let connection = Arc::new(connection);
                        let (stops, units) = mpsc::unbounded_channel();
                        let mut tasks = Scope::new();
                        let held = Arc::clone(&connection);
                        tasks.spawn(move |_| ssh::stopper(held, units));
                        let sessions = sessions.clone();
                        tasks.spawn(move |stop| mcp::serve(mcp, conversation, sessions, stop));
                        let mut running = Running {
                            slot,
                            machine,
                            connection,
                            stops,
                            _tasks: tasks,
                            work: Arc::new(work(&config.dir, conversation)),
                            lent: Arc::new(()),
                            idle_since: Instant::now(),
                        };
                        for reply in waiting {
                            let _ = reply.send(Ok(running.lend()));
                        }
                        vms.insert(conversation, State::Running(Box::new(running)));
                    }
                    Err(error) => {
                        free.push(slot);
                        for reply in waiting {
                            let _ = reply.send(Err(format!("VM 没起来：{error}")));
                        }
                    }
                }
            }
            _ = sweep.tick() => {
                let now = Instant::now();
                vms.retain(|conversation, state| {
                    let State::Running(running) = state else { return true };
                    let keep = if running.dead() {
                        warn!(%conversation, "a VM had stopped by itself");
                        false
                    } else if running.lent() {
                        running.idle_since = now;
                        true
                    } else if now >= running.idle_since + idle {
                        info!(%conversation, "stopped an idle VM");
                        false
                    } else {
                        true
                    };
                    if !keep {
                        free.push(running.slot);
                    }
                    keep
                });
            }
        }
    }
    // Dropping the VMs kills them.
    boots.close(Duration::ZERO).await;
}

/// Stops the VM that has gone unused longest, if one isn't lent, for its
/// slot.
fn evict(vms: &mut HashMap<ConversationId, State>) -> Option<usize> {
    let (&conversation, _) = vms
        .iter()
        .filter_map(|(conversation, state)| match state {
            State::Running(running) if !running.lent() => Some((conversation, running.idle_since)),
            _ => None,
        })
        .min_by_key(|(_, idle_since)| *idle_since)?;
    let Some(State::Running(running)) = vms.remove(&conversation) else {
        return None;
    };
    info!(%conversation, "stopped a VM to make room");
    Some(running.slot)
}
