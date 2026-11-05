//! The groups' VMs: one per conversation, started when a tool first needs
//! it and stopped once it has gone unused for a while, unless the group
//! keeps units of Max's in it. The VM service owns them all; a tool call
//! borrows a VM's SSH connection. See "VM 进程" and "常驻程序" in
//! docs/rust-rewrite.md.

mod events;
mod host;
mod machine;
pub mod ssh;
#[cfg(test)]
mod webread_tests;

use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use color_eyre::eyre::Result;
use max_core::ids::ConversationId;
use max_core::render::span;
use tokio::sync::mpsc::{self, UnboundedReceiver, UnboundedSender};
use tokio::sync::oneshot;
use tokio::time::{Instant, MissedTickBehavior, interval, timeout};
use tracing::{info, warn};

use self::machine::{BOOT, Booted, Guest, Machine};
use self::ssh::{Command, Connection, Input};
use crate::config;
use crate::conversation::Subscription;
use crate::mcp::api::{self, Apis};
use crate::mcp::{self, Sessions};
use crate::scope::Scope;

/// How often idle and dead VMs are looked for, and kept ones that are
/// down are started.
const SWEEP: Duration = Duration::from_secs(60);
/// A VM unused this long has its guest drop its caches, and again each time
/// it stays unused as long again. A guest's page cache, and the files it
/// remembers looking up, which virtiofsd keeps open, are otherwise never
/// freed while it runs; what it frees goes back to the host through the
/// balloon's free page reporting.
const TRIM: Duration = Duration::from_secs(10 * 60);
/// A VM that failed to boot, or stopped by itself, twice within this long
/// boots once without Max's units: one of them may be what stops it.
const FAILING: Duration = Duration::from_secs(30 * 60);
/// The files max-units installs.
const UNIT_KINDS: [&str; 5] = ["service", "socket", "timer", "path", "target"];

/// Where `conversation`'s /work is on the host, under the VMs' `dir`,
/// whether or not its VM runs.
pub fn work(dir: &Path, conversation: ConversationId) -> PathBuf {
    dir.join(conversation.0.to_string()).join("work")
}

/// What the VM service has for a conversation's actor.
#[derive(Debug)]
pub enum Signal {
    /// A program Max keeps in the VM calls a tool, outside any turn: the
    /// conversation's actor runs it, and says how it went.
    Call {
        conversation: ConversationId,
        tool: String,
        args: serde_json::Value,
        reply: oneshot::Sender<Result<serde_json::Value, mcp::Failure>>,
    },
    /// Something about the VM Max should hear.
    Notice {
        conversation: ConversationId,
        text: String,
    },
    /// A program in the VM follows the conversation's timeline.
    Subscribe {
        conversation: ConversationId,
        reply: oneshot::Sender<Subscription>,
    },
}

/// What a VM's own route asks of the service.
enum Internal {
    /// max-units ran: the group has `count` units.
    Units {
        conversation: ConversationId,
        count: u32,
        reply: oneshot::Sender<Result<String, String>>,
    },
}

/// How long a VM may idle, by the configuration.
fn idle(config: &config::Vm) -> Duration {
    Duration::from_secs(config.idle_minutes * 60)
}

/// A handle to the VM service; it stops once every handle is gone.
#[derive(Clone)]
pub struct Vms {
    requests: UnboundedSender<Request>,
    sessions: Sessions,
    apis: Arc<Apis>,
    idle: Duration,
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
    /// Starts the service in `scope`; what programs in the VMs say to Max
    /// goes to `signals`, and the `apis` are theirs to call.
    pub fn start(
        config: config::Vm,
        scope: &mut Scope,
        signals: UnboundedSender<Signal>,
        apis: Arc<Apis>,
    ) -> Result<Self> {
        let guest = Guest::load(&config.guest)?;
        std::fs::create_dir_all(&config.dir)?;
        let idle = idle(&config);
        let (requests, rx) = mpsc::unbounded_channel();
        let sessions = Sessions::with_programs(signals.clone());
        let served = sessions.clone();
        let called = Arc::clone(&apis);
        scope.spawn(move |_| run(config, guest, served, called, signals, rx));
        Ok(Self {
            requests,
            sessions,
            apis,
            idle,
        })
    }

    /// How long a VM may go without a command before it is stopped,
    /// unless it is kept on.
    pub fn idle(&self) -> Duration {
        self.idle
    }

    /// The MCP service's sessions, which programs and background agents
    /// in the VMs call through.
    pub fn sessions(&self) -> &Sessions {
        &self.sessions
    }

    /// The HTTP APIs the VMs call through the host.
    pub fn apis(&self) -> &Apis {
        &self.apis
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

    /// A name for a command's unit. A VM doesn't outlive max, but the
    /// command's output files in /work are named after the unit, and they
    /// do; so the name says which start of max it is from, and a file of
    /// an earlier one isn't in the way. A count alone began again at every
    /// restart, and a long output then failed: its file was already there.
    pub fn unit() -> String {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        static STARTED: LazyLock<u64> = LazyLock::new(|| {
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_or(0, |since| since.as_secs())
        });
        format!(
            "max-{:x}-{}",
            *STARTED,
            NEXT.fetch_add(1, Ordering::Relaxed)
        )
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
        /// With Max's units.
        units: bool,
    },
    Running(Box<Running>),
}

struct Running {
    slot: usize,
    machine: Machine,
    connection: Arc<Connection>,
    stops: UnboundedSender<String>,
    /// The stopper, which stops the units of commands dropped early, the
    /// VM's MCP service and its port to the VM service; and trims.
    tasks: Scope,
    work: Arc<PathBuf>,
    lent: Arc<()>,
    idle_since: Instant,
    /// When the guest last dropped its caches, or booted.
    trimmed: Instant,
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

    /// Has the guest drop its caches if it has gone unused for `TRIM`
    /// since it was last used or trimmed.
    fn trim(&mut self, conversation: ConversationId, now: Instant) {
        if now < self.idle_since.max(self.trimmed) + TRIM {
            return;
        }
        self.trimmed = now;
        let connection = Arc::clone(&self.connection);
        self.tasks.spawn(move |_| async move {
            if let Err(error) = ssh::trim(&connection).await {
                warn!(%conversation, error = format!("{error:#}"), "couldn't trim an idle VM");
            }
        });
    }
}

type Waiting = Vec<oneshot::Sender<Result<Vm, String>>>;

struct Service {
    config: Arc<config::Vm>,
    guest: Arc<Guest>,
    sessions: Sessions,
    apis: Arc<Apis>,
    signals: UnboundedSender<Signal>,
    idle: Duration,
    vms: HashMap<ConversationId, State>,
    free: Vec<usize>,
    boots: Scope,
    booted: UnboundedSender<(ConversationId, Result<Booted, String>)>,
    internal: UnboundedSender<Internal>,
    /// The groups whose VMs stay on, for the units Max keeps in them.
    kept: BTreeSet<ConversationId>,
    /// When each VM failed to boot or stopped by itself, lately.
    failed: HashMap<ConversationId, Vec<Instant>>,
}

async fn run(
    config: config::Vm,
    guest: Guest,
    sessions: Sessions,
    apis: Arc<Apis>,
    signals: UnboundedSender<Signal>,
    mut requests: UnboundedReceiver<Request>,
) {
    let (booted, mut booted_rx) = mpsc::unbounded_channel();
    let (internal, mut internal_rx) = mpsc::unbounded_channel();
    let dir = config.dir.clone();
    let mut service = Service {
        idle: idle(&config),
        free: (0..config.slots.len()).rev().collect(),
        config: Arc::new(config),
        guest: Arc::new(guest),
        sessions,
        apis,
        signals,
        vms: HashMap::new(),
        boots: Scope::new(),
        booted,
        internal,
        kept: BTreeSet::new(),
        failed: HashMap::new(),
    };
    // The groups that had units when max stopped are back on.
    let had = tokio::task::spawn_blocking(move || with_units(&dir))
        .await
        .unwrap_or_default();
    for conversation in had.into_iter().take(service.config.kept) {
        service.kept.insert(conversation);
        service.start(conversation, Vec::new());
    }
    let mut sweep = interval(SWEEP);
    sweep.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            request = requests.recv() => {
                let Some(Request { conversation, reply }) = request else { break };
                service.get(conversation, reply);
            }
            Some((conversation, result)) = booted_rx.recv() => service.booted(conversation, result),
            Some(Internal::Units { conversation, count, reply }) = internal_rx.recv() => {
                let _ = reply.send(Ok(service.units(conversation, count)));
            }
            _ = sweep.tick() => service.sweep(),
        }
    }
    // Dropping the VMs kills them.
    service.boots.close(Duration::ZERO).await;
}

impl Service {
    fn get(&mut self, conversation: ConversationId, reply: oneshot::Sender<Result<Vm, String>>) {
        match self.vms.get_mut(&conversation) {
            Some(State::Running(running)) => {
                if !running.dead() {
                    let _ = reply.send(Ok(running.lend()));
                    return;
                }
                let slot = running.slot;
                self.vms.remove(&conversation);
                self.died(conversation, slot);
            }
            Some(State::Booting { waiting, .. }) => {
                waiting.push(reply);
                return;
            }
            None => {}
        }
        self.start(conversation, vec![reply]);
    }

    /// Boots the conversation's VM for `waiting`: without Max's units if
    /// it has been failing.
    fn start(&mut self, conversation: ConversationId, waiting: Waiting) {
        let Some(slot) = self.free.pop().or_else(|| evict(&mut self.vms, &self.kept)) else {
            for reply in waiting {
                let _ = reply.send(Err("同时开着的 VM 太多了，过一会儿再试。".into()));
            }
            return;
        };
        let units = !self.failing(conversation);
        if !units {
            warn!(%conversation, "booting a VM without Max's units: it failed twice lately");
            self.failed.remove(&conversation);
        }
        self.vms.insert(
            conversation,
            State::Booting {
                slot,
                waiting,
                units,
            },
        );
        let dir = self.config.dir.join(conversation.0.to_string());
        let (config, guest, booted) = (
            Arc::clone(&self.config),
            Arc::clone(&self.guest),
            self.booted.clone(),
        );
        self.boots.spawn(move |_| async move {
            let started = Instant::now();
            let slot = &config.slots[slot];
            let booting = machine::boot(&config, &guest, &dir, slot, units);
            let result = match timeout(BOOT + Duration::from_secs(10), booting).await {
                Ok(result) => result.map_err(|error| format!("{error:#}")),
                Err(_) => Err(format!("the VM didn't boot within {BOOT:?}")),
            };
            match &result {
                Ok(_) => {
                    info!(%conversation, tap = %slot.tap, took = ?started.elapsed(), "a VM booted")
                }
                Err(error) => warn!(%conversation, %error, "a VM didn't boot"),
            }
            let _ = booted.send((conversation, result));
        });
    }

    fn booted(&mut self, conversation: ConversationId, result: Result<Booted, String>) {
        let Some(State::Booting {
            slot,
            waiting,
            units,
        }) = self.vms.remove(&conversation)
        else {
            return;
        };
        let Booted {
            machine,
            connection,
            mcp,
        } = match result {
            Ok(booted) => booted,
            Err(error) => {
                self.free.push(slot);
                self.fail(conversation);
                if !units {
                    // Not the units, then: the VM waits for a tool to need
                    // it, instead of booting again every sweep.
                    self.kept.remove(&conversation);
                }
                for reply in waiting {
                    let _ = reply.send(Err(format!("VM 没起来：{error}")));
                }
                return;
            }
        };
        let connection = Arc::new(connection);
        let (stops, stopped) = mpsc::unbounded_channel();
        let mut tasks = Scope::new();
        let held = Arc::clone(&connection);
        tasks.spawn(move |_| ssh::stopper(held, stopped));
        let sessions = self.sessions.clone();
        let host = host::router(conversation, self.internal.clone())
            .merge(api::router(conversation, Arc::clone(&self.apis)));
        let signals = self.signals.clone();
        tasks.spawn(move |stop| {
            // The timeline's streams end with the service, which waits for them.
            let host = host.merge(events::router(conversation, signals, stop.clone()));
            mcp::serve_with(mcp, conversation, sessions, host, stop)
        });
        let mut running = Running {
            slot,
            machine,
            connection,
            stops,
            tasks,
            work: Arc::new(work(&self.config.dir, conversation)),
            lent: Arc::new(()),
            idle_since: Instant::now(),
            trimmed: Instant::now(),
        };
        for reply in waiting {
            let _ = reply.send(Ok(running.lend()));
        }
        self.vms
            .insert(conversation, State::Running(Box::new(running)));
        if !units {
            // Kept on again once Max runs max-units.
            self.kept.remove(&conversation);
            let text = "这个群的 VM 最近两次没开起来，或者开着开着自己停了，这次开机就没装 /work/.max/systemd 里的 unit，VM 也不再常开。多半是哪个 unit 的问题：用 systemctl、journalctl 查清楚、改好，再跑 max-units。".to_owned();
            let _ = self.signals.send(Signal::Notice { conversation, text });
        }
    }

    /// Stops idle VMs, but kept ones, and trims the rest that are unused;
    /// finds dead ones; starts kept ones that are down.
    fn sweep(&mut self) {
        let now = Instant::now();
        let mut died = Vec::new();
        self.vms.retain(|conversation, state| {
            let State::Running(running) = state else {
                return true;
            };
            let keep = if running.dead() {
                died.push((*conversation, running.slot));
                return false;
            } else if running.lent() {
                running.idle_since = now;
                true
            } else if !self.kept.contains(conversation) && now >= running.idle_since + self.idle {
                info!(%conversation, "stopped an idle VM");
                false
            } else {
                running.trim(*conversation, now);
                true
            };
            if !keep {
                self.free.push(running.slot);
            }
            keep
        });
        for (conversation, slot) in died {
            self.died(conversation, slot);
        }
        let down: Vec<ConversationId> = self
            .kept
            .iter()
            .filter(|conversation| !self.vms.contains_key(conversation))
            .copied()
            .collect();
        for conversation in down {
            self.start(conversation, Vec::new());
        }
    }

    /// The VM on `slot` had stopped by itself; it is gone already.
    fn died(&mut self, conversation: ConversationId, slot: usize) {
        warn!(%conversation, "a VM had stopped by itself");
        self.free.push(slot);
        self.fail(conversation);
    }

    fn fail(&mut self, conversation: ConversationId) {
        self.failed
            .entry(conversation)
            .or_default()
            .push(Instant::now());
    }

    /// Failed twice within `FAILING`.
    fn failing(&mut self, conversation: ConversationId) -> bool {
        let Some(times) = self.failed.get_mut(&conversation) else {
            return false;
        };
        times.retain(|at| at.elapsed() < FAILING);
        times.len() >= 2
    }

    /// max-units says the group has `count` units: what becomes of its VM,
    /// for max-units to show. Failures stay counted: max-units runs at
    /// every boot, before a unit has had the time to fail.
    fn units(&mut self, conversation: ConversationId, count: u32) -> String {
        let idle = span(self.idle);
        match keep(&mut self.kept, self.config.kept, conversation, count) {
            Kept::On => {
                info!(%conversation, count, "a VM is kept on for its units");
                "这个群的 VM 会一直开着，unit 一直跑；重启、部署之后也会自己开起来。".to_owned()
            }
            Kept::Full => format!(
                "常开的群满了（{} 个）：这个群的 VM 闲 {idle}还是会关，unit 跟着停，下次开机再起。",
                self.config.kept
            ),
            Kept::Off => format!("没有 unit 了：VM 闲 {idle}会关。"),
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Kept {
    On,
    /// Has units, but `most` groups are kept on already.
    Full,
    /// Has none.
    Off,
}

/// Whether a group with `count` units is kept on: while it has any, if
/// it is already, or fewer than `most` are.
fn keep(
    kept: &mut BTreeSet<ConversationId>,
    most: usize,
    conversation: ConversationId,
    count: u32,
) -> Kept {
    if count == 0 {
        kept.remove(&conversation);
        Kept::Off
    } else if kept.contains(&conversation) || kept.len() < most {
        kept.insert(conversation);
        Kept::On
    } else {
        Kept::Full
    }
}

/// The conversations whose /work, under `dir`, has units of Max's, in
/// order; not vm-check's, conversation 0, which keeps one of its own.
fn with_units(dir: &Path) -> Vec<ConversationId> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut found: Vec<ConversationId> = entries
        .filter_map(|entry| entry.ok()?.file_name().to_str()?.parse::<i64>().ok())
        .filter(|&id| id != 0)
        .map(ConversationId)
        .filter(|&conversation| has_units(&work(dir, conversation)))
        .collect();
    found.sort();
    found
}

fn has_units(work: &Path) -> bool {
    !units(work).is_empty()
}

/// The units Max keeps in a group's /work, by name, in order: the files
/// max-units installs.
pub fn units(work: &Path) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(work.join(".max/systemd")) else {
        return Vec::new();
    };
    let mut names: Vec<String> = entries
        .filter_map(Result::ok)
        // Not a link: it could point anywhere on the host.
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_file()))
        .filter_map(|entry| entry.file_name().into_string().ok())
        .filter(|name| {
            name.rsplit_once('.')
                .is_some_and(|(_, kind)| UNIT_KINDS.contains(&kind))
        })
        .collect();
    names.sort();
    names
}

/// Stops the VM that has gone unused longest, if one isn't lent or kept,
/// for its slot.
fn evict(
    vms: &mut HashMap<ConversationId, State>,
    kept: &BTreeSet<ConversationId>,
) -> Option<usize> {
    let (&conversation, _) = vms
        .iter()
        .filter(|(conversation, _)| !kept.contains(conversation))
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_group_is_kept_on_while_it_has_units_and_there_is_room() {
        let mut kept = BTreeSet::new();
        let (a, b, c) = (ConversationId(4), ConversationId(8), ConversationId(9));
        assert_eq!(keep(&mut kept, 2, a, 1), Kept::On);
        assert_eq!(keep(&mut kept, 2, b, 3), Kept::On);
        assert_eq!(keep(&mut kept, 2, c, 1), Kept::Full);
        // Already on, it stays on.
        assert_eq!(keep(&mut kept, 2, a, 2), Kept::On);
        assert_eq!(keep(&mut kept, 2, a, 0), Kept::Off);
        assert_eq!(keep(&mut kept, 2, c, 1), Kept::On);
        assert_eq!(kept, BTreeSet::from([b, c]));
    }

    #[test]
    fn the_groups_with_units_are_found_on_disk() {
        let dir = std::env::temp_dir().join(format!("max-kept-{}", std::process::id()));
        let units = |id: i64| work(&dir, ConversationId(id)).join(".max/systemd");
        for id in [0, 9, 12, 4] {
            std::fs::create_dir_all(units(id)).unwrap();
        }
        std::fs::write(units(0).join("boot-note.service"), "").unwrap();
        std::fs::write(units(12).join("ci.timer"), "").unwrap();
        std::fs::write(units(4).join("ci.service"), "").unwrap();
        // Not a unit, and an empty group.
        std::fs::write(units(9).join("notes.txt"), "").unwrap();
        std::fs::create_dir_all(dir.join("not-a-group")).unwrap();
        assert_eq!(with_units(&dir), [ConversationId(4), ConversationId(12)]);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
