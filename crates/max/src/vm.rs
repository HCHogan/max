//! The groups' VMs: one per conversation, started when a tool first needs
//! it and stopped once it has gone unused for a while, unless the group
//! keeps units of Max's in it. The VM service owns them all; a tool call
//! borrows a VM's SSH connection. See "VM processes" and "Resident programs" in
//! docs/rust-rewrite.md.

mod about;
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
use futures_util::FutureExt;
use futures_util::future::BoxFuture;
use max_core::ids::ConversationId;
use serde::Deserialize;
use tokio::sync::mpsc::{self, UnboundedReceiver, UnboundedSender};
use tokio::sync::oneshot;
use tokio::time::{Instant, MissedTickBehavior, interval, timeout};
use tracing::{info, warn};

pub use self::about::{About, Unit, taken};
use self::machine::{BOOT, Boot, Booted, Guest, Machine};
use self::ssh::{Closes, Command, Connection};
use crate::config;
use crate::conversation::{Heard, Signal};
use crate::scope::Scope;
use crate::service;

/// How often idle and dead VMs are looked for, and kept ones that are
/// down are started.
const SWEEP: Duration = Duration::from_secs(60);
/// A VM on an older image is stopped, to boot the new one, once it has
/// gone unused this long and nothing of Max's runs in it.
const QUIET: Duration = Duration::from_secs(10 * 60);
/// A VM that failed to boot, or stopped by itself, twice within this long
/// boots once without Max's units: one of them may be what stops it.
const FAILING: Duration = Duration::from_secs(30 * 60);
/// The files `maxx units apply` installs.
const UNIT_KINDS: [&str; 5] = ["service", "socket", "timer", "path", "target"];

/// What `maxx units list` says (nix/max-jobs.sh): what runs in a guest.
#[derive(Deserialize)]
struct Listed {
    units: Vec<Listing>,
}

/// One of them: `unit` for one /work/.max/systemd keeps, and for what was
/// started `call`, `job` or `agent`.
#[derive(Deserialize)]
struct Listing {
    kind: String,
}

/// What `maxx units stop-all` says: the units it stopped.
#[derive(Deserialize)]
pub struct Stopped {
    pub stopped: Vec<String>,
}

/// Where `conversation`'s /work is on the host, under the VMs' `dir`,
/// whether or not its VM runs.
pub fn work(dir: &Path, conversation: ConversationId) -> PathBuf {
    dir.join(conversation.0.to_string()).join("work")
}

/// What a VM's own route asks of the service, and what its tasks tell it.
enum Internal {
    /// `maxx units apply` ran: the group has `count` units.
    Units {
        conversation: ConversationId,
        count: u32,
        reply: oneshot::Sender<Result<String, String>>,
    },
    /// The guest says something of Max's runs in it: a background command,
    /// which no call of max's waits for.
    Busy { conversation: ConversationId },
    /// A VM on an older image was switched to the one max boots, where it
    /// runs; `stale` if it must still boot again, for a kernel.
    Switched {
        conversation: ConversationId,
        stale: Stale,
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
    apis: Arc<str>,
    idle: Duration,
    /// The groups on the operations network.
    operating: Arc<BTreeSet<ConversationId>>,
}

enum Request {
    /// A conversation's VM.
    Vm {
        conversation: ConversationId,
        /// Whether to start it if it isn't running.
        boot: bool,
        reply: oneshot::Sender<Result<Vm, String>>,
    },
    /// Stop every VM, and say once they have stopped.
    Shut { reply: oneshot::Sender<()> },
}

/// A running VM, lent to a tool call. It isn't idle while one is held.
#[derive(Clone)]
pub struct Vm {
    connection: Arc<Connection>,
    closes: Closes,
    work: Arc<PathBuf>,
    _lent: Arc<()>,
}

impl Vms {
    /// Starts the service in `scope`; what programs in the VMs say to Max
    /// goes to `signals`, and `apis` is what the system prompt says of
    /// the APIs they may call. Those, and the models' calls, are each
    /// VM's forwarder's to carry (`crate::forwarder`), not max's.
    pub fn start(
        config: config::Vm,
        scope: &mut Scope,
        signals: UnboundedSender<Signal>,
        apis: Arc<str>,
    ) -> Result<Self> {
        let guest = Guest::load(&config.guest)?;
        std::fs::create_dir_all(&config.dir)?;
        let idle = idle(&config);
        let operating = Arc::new(
            config
                .operations
                .iter()
                .flat_map(|ops| &ops.conversations)
                .map(|&id| ConversationId(id))
                .collect(),
        );
        let (requests, rx) = mpsc::unbounded_channel();
        scope.spawn(move |_| run(config, guest, signals, rx));
        Ok(Self {
            requests,
            apis,
            idle,
            operating,
        })
    }

    /// Whether the conversation's VM is on the operations network.
    pub fn operates(&self, conversation: ConversationId) -> bool {
        self.operating.contains(&conversation)
    }

    /// How long a VM may go without a command before it is stopped,
    /// unless it is kept on.
    pub fn idle(&self) -> Duration {
        self.idle
    }

    /// The HTTP APIs the VMs call through the host, as the system prompt
    /// lists them.
    pub fn apis(&self) -> &str {
        &self.apis
    }

    /// The conversation's VM, started if it isn't running; or why there
    /// isn't one.
    pub async fn get(&self, conversation: ConversationId) -> Result<Vm, String> {
        self.ask(conversation, true).await
    }

    /// The conversation's VM if it runs: nothing is started for the
    /// asking.
    pub async fn running(&self, conversation: ConversationId) -> Option<Vm> {
        self.ask(conversation, false).await.ok()
    }

    async fn ask(&self, conversation: ConversationId, boot: bool) -> Result<Vm, String> {
        let (reply, answer) = oneshot::channel();
        let gone = || "the VM service has stopped".to_owned();
        let request = Request::Vm {
            conversation,
            boot,
            reply,
        };
        self.requests.send(request).map_err(|_| gone())?;
        answer.await.map_err(|_| gone())?
    }

    /// Stops every VM and waits until they have stopped. The VMs outlive
    /// the service otherwise, as they outlive max: this is for vm-check,
    /// which leaves none behind.
    pub async fn shut(&self) {
        let (reply, done) = oneshot::channel();
        if self.requests.send(Request::Shut { reply }).is_ok() {
            let _ = done.await;
        }
    }
}

impl Vm {
    /// Starts `line`, a call (`maxx units run`), in the guest's shell, and
    /// gives it `input`. The guest stops the call when what this returns
    /// is dropped, or max's connection goes.
    pub async fn command(&self, line: &str, input: &[u8]) -> Result<Command> {
        Command::start(&self.connection, line, input, self.closes.clone()).await
    }

    /// Runs `line`, a command of max's own that is no unit, and waits for
    /// it: what it wrote to stdout.
    pub async fn ask(&self, line: &str) -> Result<String> {
        ssh::ask(&self.connection, line).await
    }

    /// What the guest says of itself, and of those of `units` its systemd
    /// knows: for `/status`.
    pub async fn about(&self, units: &[String]) -> Result<About> {
        about::read(&self.ask(&about::line(units)).await?)
    }

    /// A name for a command's unit, one `maxx units` takes. A VM outlives
    /// max, and so do the command's output files in /work, which are
    /// named after the unit; so the name says which start of max it is
    /// from, and neither a unit nor a file of an earlier one is in the
    /// way. A count alone began again at every restart, and a long
    /// output then failed: its file was already there.
    pub fn unit() -> String {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        static STARTED: LazyLock<u64> = LazyLock::new(|| {
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_or(0, |since| since.as_secs())
        });
        format!(
            "max-job-{:x}-{}",
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
    /// Booting, or being attached to.
    Booting {
        slot: usize,
        waiting: Vec<oneshot::Sender<Result<Vm, String>>>,
        /// With Max's units.
        units: bool,
        /// Booted by a max before this one, which attaches to it; and if
        /// so, how it stands to the image max boots.
        attached: Option<Attached>,
    },
    Running(Box<Running>),
}

/// How a VM that max attaches to stands to the image max boots now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Attached {
    /// It isn't whole on that image; see [`Running::stale`].
    stale: Stale,
    /// Its guest is on another image's system, and is to be switched.
    switch: bool,
}

impl Attached {
    /// A VM of `boot`, for a max that boots `guest`, the image at `image`.
    fn of(boot: &Boot, image: &Path, guest: &Guest) -> Self {
        let switch = boot.guest != image;
        Self {
            // On another system until it is switched, and on another
            // kernel until it boots again, however long ago it was
            // switched.
            stale: switch || boot.reboots_for(guest),
            switch,
        }
    }
}

/// Whether a VM isn't whole on the image max boots.
type Stale = bool;

struct Running {
    slot: usize,
    machine: Machine,
    connection: Arc<Connection>,
    closes: Closes,
    /// The closer, which closes the channels of calls dropped early, the
    /// task that asks the guest what runs, and max's service to the VM with
    /// its port to the VM service: they end when max lets go of the VM.
    _tasks: Scope,
    work: Arc<PathBuf>,
    lent: Arc<()>,
    idle_since: Instant,
    /// When the guest last said something of Max's runs in it.
    busy: Option<Instant>,
    /// Not whole on the image max boots, which a deploy has replaced
    /// since this VM booted: until its guest is switched to it where it
    /// runs, and after that if the kernel or the initrd changed too. It
    /// boots the new image at a quiet moment.
    stale: Stale,
    /// Booted with Max's units.
    units: bool,
}

impl Running {
    fn lend(&mut self) -> Vm {
        self.idle_since = Instant::now();
        Vm {
            connection: Arc::clone(&self.connection),
            closes: self.closes.clone(),
            work: Arc::clone(&self.work),
            _lent: Arc::clone(&self.lent),
        }
    }

    fn lent(&self) -> bool {
        Arc::strong_count(&self.lent) > 1
    }

    /// Whether the guest said, at one of the last two times it was asked,
    /// that something of Max's runs in it.
    fn busy(&self) -> bool {
        self.busy.is_some_and(|said| said.elapsed() < 2 * SWEEP)
    }

    /// Its connection is gone, and with it the VM, as far as max can use
    /// it.
    fn dead(&self) -> bool {
        self.connection.is_closed()
    }
}

type Waiting = Vec<oneshot::Sender<Result<Vm, String>>>;

/// Why a boot or an attach left no VM to use.
enum Unusable {
    /// It didn't boot, or the guest didn't let max in: why.
    Failed(String),
    /// The VM max was to attach to again has ended by itself.
    Gone,
}

struct Service {
    config: Arc<config::Vm>,
    guest: Arc<Guest>,
    signals: UnboundedSender<Signal>,
    idle: Duration,
    vms: HashMap<ConversationId, State>,
    free: Free,
    boots: Scope,
    booted: UnboundedSender<(ConversationId, Result<Booted, Unusable>)>,
    /// The VMs max had systemd stop a moment ago, each done once systemd
    /// has the request: a boot of the same VM waits for that.
    stopping: HashMap<ConversationId, BoxFuture<'static, ()>>,
    internal: UnboundedSender<Internal>,
    /// The groups whose VMs stay on, for the units Max keeps in them.
    kept: BTreeSet<ConversationId>,
    /// When each VM failed to boot or stopped by itself, lately.
    failed: HashMap<ConversationId, Vec<Instant>>,
}

async fn run(
    config: config::Vm,
    guest: Guest,
    signals: UnboundedSender<Signal>,
    mut requests: UnboundedReceiver<Request>,
) {
    let (booted, mut booted_rx) = mpsc::unbounded_channel();
    let (internal, mut internal_rx) = mpsc::unbounded_channel();
    let dir = config.dir.clone();
    let mut service = Service {
        idle: idle(&config),
        free: Free::new(&config),
        config: Arc::new(config),
        guest: Arc::new(guest),
        signals,
        vms: HashMap::new(),
        boots: Scope::new(),
        booted,
        stopping: HashMap::new(),
        internal,
        kept: BTreeSet::new(),
        failed: HashMap::new(),
    };
    // The VMs a max before this one booted run on, with what runs in
    // them: this one attaches to those it can use. What the rest were
    // rooted for is the collector's.
    match machine::running(&service.config).await {
        Ok(running) => {
            machine::unroot_ended(&service.config, &running);
            for conversation in running {
                service.attach(conversation).await;
            }
        }
        Err(error) => warn!(
            error = format!("{error:#}"),
            "couldn't list the VMs that run"
        ),
    }
    // The groups that had units when max stopped are back on, if their
    // VMs aren't up already.
    let had = tokio::task::spawn_blocking(move || with_units(&dir))
        .await
        .unwrap_or_default();
    for conversation in had.into_iter().take(service.config.kept) {
        service.kept.insert(conversation);
        if !service.vms.contains_key(&conversation) {
            service.start(conversation, Vec::new());
        }
    }
    let mut sweep = interval(SWEEP);
    sweep.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            request = requests.recv() => match request {
                Some(Request::Vm { conversation, boot, reply }) => {
                    service.get(conversation, boot, reply);
                }
                Some(Request::Shut { reply }) => {
                    service.shut().await;
                    let _ = reply.send(());
                }
                None => break,
            },
            Some((conversation, result)) = booted_rx.recv() => service.booted(conversation, result),
            Some(internal) = internal_rx.recv() => match internal {
                Internal::Units { conversation, count, reply } => {
                    let _ = reply.send(Ok(service.units(conversation, count)));
                }
                Internal::Busy { conversation } => service.busy(conversation),
                Internal::Switched { conversation, stale } => {
                    if let Some(State::Running(running)) = service.vms.get_mut(&conversation) {
                        running.stale = stale;
                    }
                }
            },
            _ = sweep.tick() => service.sweep(),
        }
    }
    // The VMs stay, and what runs in them: the next max attaches to them.
    service.boots.close(Duration::ZERO).await;
}

impl Service {
    fn get(
        &mut self,
        conversation: ConversationId,
        boot: bool,
        reply: oneshot::Sender<Result<Vm, String>>,
    ) {
        match self.vms.get_mut(&conversation) {
            Some(State::Running(running)) => {
                if !running.dead() {
                    let _ = reply.send(Ok(running.lend()));
                    return;
                }
                self.reattach(conversation, vec![reply]);
                return;
            }
            Some(State::Booting { waiting, .. }) => {
                waiting.push(reply);
                return;
            }
            None => {}
        }
        if boot {
            self.start(conversation, vec![reply]);
        } else {
            let _ = reply.send(Err("the VM isn't running".to_owned()));
        }
    }

    /// The guest of `conversation`'s VM has something of Max's running: it
    /// counts as used now.
    fn busy(&mut self, conversation: ConversationId) {
        if let Some(State::Running(running)) = self.vms.get_mut(&conversation) {
            let now = Instant::now();
            running.idle_since = now;
            running.busy = Some(now);
        }
    }

    /// Boots the conversation's VM for `waiting`: without Max's units if
    /// it has been failing.
    fn start(&mut self, conversation: ConversationId, waiting: Waiting) {
        let operates = self.config.operates(conversation.0);
        let pool = self.config.operations_slots();
        let Some(slot) = self.free.take(operates).or_else(|| {
            evict(&mut self.vms, &self.kept, &mut self.stopping, |slot| {
                pool.contains(&slot) == operates
            })
        }) else {
            for reply in waiting {
                let _ = reply.send(Err(
                    "too many VMs are running at once; try again in a while".into(),
                ));
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
                attached: None,
            },
        );
        let (config, guest, booted) = (
            Arc::clone(&self.config),
            Arc::clone(&self.guest),
            self.booted.clone(),
        );
        let stopping = self.stopping.remove(&conversation);
        self.boots.spawn(move |_| async move {
            // Stopped a moment ago, as for a new image: started once
            // systemd has that, or the stop would end this boot.
            if let Some(stopping) = stopping {
                stopping.await;
            }
            let started = Instant::now();
            let operations = if operates {
                config.operations.as_ref()
            } else {
                None
            };
            let slot = (slot, config.slot(slot));
            let booting = machine::boot(&config, &guest, conversation, slot, operations, units);
            let result = match timeout(BOOT + Duration::from_secs(10), booting).await {
                Ok(result) => result.map_err(|error| format!("{error:#}")),
                Err(_) => Err(format!("the VM didn't boot within {BOOT:?}")),
            };
            match &result {
                Ok(_) => {
                    info!(%conversation, tap = %slot.1.tap, took = ?started.elapsed(), "a VM booted")
                }
                Err(error) => warn!(%conversation, %error, "a VM didn't boot"),
            }
            let _ = booted.send((conversation, result.map_err(Unusable::Failed)));
        });
    }

    /// Attaches to `conversation`'s VM, which a max before this one
    /// booted, if this one can use it: it kept a record of its boot, the
    /// guest keeps this max's contract, and its slot is free. One it
    /// can't use is stopped, and boots again when it is next needed.
    async fn attach(&mut self, conversation: ConversationId) {
        let machine = Machine::of(&self.config, conversation);
        let operates = self.config.operates(conversation.0);
        let usable = match Boot::read(&machine.dir).await {
            Err(error) => Err(format!("{error:#}")),
            Ok(boot) if boot.contract != self.guest.contract => Err(format!(
                "its guest keeps contract {}, and max {}",
                boot.contract, self.guest.contract
            )),
            Ok(boot) => match self.free.take_slot(boot.slot, operates) {
                true => Ok(boot),
                false => Err(format!("its slot, {}, isn't free for it", boot.slot)),
            },
        };
        let boot = match usable {
            Ok(boot) => boot,
            Err(why) => {
                warn!(%conversation, why, "a VM that runs can't be attached to, and is stopped");
                machine.stopped().await;
                return;
            }
        };
        let attached = Attached::of(&boot, &self.config.guest, &self.guest);
        self.vms.insert(
            conversation,
            State::Booting {
                slot: boot.slot,
                waiting: Vec::new(),
                units: boot.units,
                attached: Some(attached),
            },
        );
        self.attaching(conversation, attached);
    }

    /// max's connection to `conversation`'s VM is gone. The VM may run
    /// on, as when its sshd restarted under a switch: max attaches to it
    /// again, with `waiting` for it. One it can't reach any more is
    /// stopped as one that failed, and one that has ended by itself
    /// failed too, and boots again for whoever waits.
    fn reattach(&mut self, conversation: ConversationId, waiting: Waiting) {
        let Some(State::Running(running)) = self.vms.remove(&conversation) else {
            return;
        };
        warn!(%conversation, "the connection to a VM is gone; attaching to it again");
        let (slot, units, stale) = (running.slot, running.units, running.stale);
        // Its tasks end, and the service's socket is free to bind again.
        drop(running);
        // Whatever it was switched to stands: only the connection is new.
        let attached = Attached {
            stale,
            switch: false,
        };
        self.vms.insert(
            conversation,
            State::Booting {
                slot,
                waiting,
                units,
                attached: Some(attached),
            },
        );
        self.attaching(conversation, attached);
    }

    /// Attaches to `conversation`'s VM in a task, which says how it went.
    fn attaching(&mut self, conversation: ConversationId, attached: Attached) {
        let (config, booted) = (Arc::clone(&self.config), self.booted.clone());
        self.boots.spawn(move |_| async move {
            let result = match machine::attach(&config, conversation).await {
                Ok(Some(booted)) => {
                    info!(%conversation, ?attached, "attached to a VM that runs");
                    Ok(booted)
                }
                Ok(None) => {
                    warn!(%conversation, "a VM that ran has ended by itself");
                    Err(Unusable::Gone)
                }
                Err(error) => {
                    let error = format!("{error:#}");
                    warn!(%conversation, error, "couldn't attach to a VM");
                    Err(Unusable::Failed(error))
                }
            };
            let _ = booted.send((conversation, result));
        });
    }

    /// Stops every VM and waits for each: vm-check's, as it ends.
    async fn shut(&mut self) {
        std::mem::replace(&mut self.boots, Scope::new())
            .close(Duration::ZERO)
            .await;
        for (conversation, state) in std::mem::take(&mut self.vms) {
            let slot = match state {
                State::Booting { slot, .. } => slot,
                State::Running(running) => running.slot,
            };
            Machine::of(&self.config, conversation).stopped().await;
            self.free.release(slot);
        }
    }

    fn booted(&mut self, conversation: ConversationId, result: Result<Booted, Unusable>) {
        let Some(State::Booting {
            slot,
            waiting,
            units,
            attached,
        }) = self.vms.remove(&conversation)
        else {
            return;
        };
        let Booted {
            machine,
            connection,
            listener,
        } = match result {
            Ok(booted) => booted,
            Err(unusable) => {
                let machine = Machine::of(&self.config, conversation);
                self.free.release(slot);
                self.fail(conversation);
                if !units {
                    // Not the units, then: the VM waits for a tool to need
                    // it, instead of booting again every sweep.
                    self.kept.remove(&conversation);
                }
                match unusable {
                    Unusable::Failed(error) => {
                        // Whatever is left of it: one max couldn't attach
                        // to runs.
                        self.stopping.insert(conversation, machine.stop().boxed());
                        for reply in waiting {
                            let _ = reply.send(Err(format!("the VM didn't start: {error}")));
                        }
                    }
                    Unusable::Gone => {
                        // Nothing runs to stop. A call that found it so
                        // has it boot again, as it would one that was
                        // never up; a kept one comes back at the sweep.
                        machine.unroot();
                        if !waiting.is_empty() {
                            self.start(conversation, waiting);
                        }
                    }
                }
                return;
            }
        };
        let connection = Arc::new(connection);
        let (closes, closed) = mpsc::unbounded_channel();
        let mut tasks = Scope::new();
        tasks.spawn(move |_| ssh::closer(closed));
        // A background command is the guest's, and no call of max's holds
        // the VM for it: the guest is asked whether any runs.
        let (asked, internal) = (Arc::clone(&connection), self.internal.clone());
        tasks.spawn(move |stop| async move {
            let mut every = interval(SWEEP);
            every.set_missed_tick_behavior(MissedTickBehavior::Delay);
            loop {
                tokio::select! {
                    () = stop.cancelled() => return,
                    _ = every.tick() => {}
                }
                // One that doesn't say isn't kept up for it. What runs
                // is the last line: the group's .bashrc may write before
                // it. A unit /work/.max/systemd keeps isn't work under
                // way: the VM is kept on for those another way.
                let said = ssh::ask(&asked, "maxx units list '{}'").await;
                let jobs = said.ok().and_then(|said| {
                    let listed: Listed = serde_json::from_str(said.lines().last()?).ok()?;
                    Some(
                        listed
                            .units
                            .iter()
                            .filter(|unit| unit.kind != "unit")
                            .count(),
                    )
                });
                if jobs.is_some_and(|jobs| jobs > 0)
                    && internal.send(Internal::Busy { conversation }).is_err()
                {
                    return;
                }
            }
        });
        if attached.is_some_and(|attached| attached.switch) {
            // An older image's guest moves to the one max boots where it
            // runs. If it can't, or its kernel isn't that image's either,
            // the VM stays stale, and boots again at a quiet moment.
            let (config, guest) = (Arc::clone(&self.config), Arc::clone(&self.guest));
            let (machine, asked) = (machine.clone(), Arc::clone(&connection));
            let internal = self.internal.clone();
            tasks.spawn(move |_| async move {
                match machine::switch(&config, &guest, &machine, &asked).await {
                    Ok(stale) => {
                        info!(%conversation, stale, "a VM's guest is switched to the image max boots");
                        let _ = internal.send(Internal::Switched { conversation, stale });
                    }
                    Err(error) => {
                        warn!(%conversation, error = format!("{error:#}"), "a VM's guest couldn't be switched to the image max boots");
                    }
                }
            });
        }
        let host = host::router(conversation, self.internal.clone());
        let signals = self.signals.clone();
        tasks.spawn(move |stop| {
            // The timeline's streams end with the service, which waits for them.
            let calls = signals.clone();
            let host = host.merge(events::router(conversation, signals, stop.clone()));
            service::serve(listener, conversation, calls, host, stop)
        });
        let mut running = Running {
            slot,
            machine,
            connection,
            closes,
            _tasks: tasks,
            work: Arc::new(work(&self.config.dir, conversation)),
            lent: Arc::new(()),
            idle_since: Instant::now(),
            busy: None,
            stale: attached.is_some_and(|attached| attached.stale),
            units,
        };
        for reply in waiting {
            let _ = reply.send(Ok(running.lend()));
        }
        self.vms
            .insert(conversation, State::Running(Box::new(running)));
        if !units {
            // Kept on again once Max runs maxx units apply.
            self.kept.remove(&conversation);
        }
        // Max was told when it booted so.
        if !units && attached.is_none() {
            let text = "这个群的 VM 最近两次没开起来，或者开着开着自己停了，这次开机就没装 /work/.max/systemd 里的 unit，VM 也不再常开。多半是哪个 unit 的问题：用 systemctl、journalctl 查清楚、改好，再跑 maxx units apply。".to_owned();
            let heard = Heard::Vm(text);
            let _ = self.signals.send(Signal::Heard {
                conversation,
                heard,
            });
        }
    }

    /// Stops idle VMs, but kept ones, and those on an older image once
    /// they are quiet; attaches again to those whose connection is gone;
    /// starts kept ones that are down, one stopped for its image among
    /// them.
    fn sweep(&mut self) {
        let now = Instant::now();
        // Those systemd has by now are done with.
        self.stopping
            .retain(|_, stopping| stopping.as_mut().now_or_never().is_none());
        let mut lost = Vec::new();
        self.vms.retain(|conversation, state| {
            let State::Running(running) = state else {
                return true;
            };
            let kept = self.kept.contains(conversation);
            let keep = if running.dead() {
                lost.push(*conversation);
                return true;
            } else if running.lent() {
                running.idle_since = now;
                true
            } else if rested(running.stale, running.busy(), now - running.idle_since) {
                info!(%conversation, "stopped a quiet VM on an older image");
                false
            } else if !kept && now >= running.idle_since + self.idle {
                info!(%conversation, "stopped an idle VM");
                false
            } else {
                true
            };
            if !keep {
                self.stopping
                    .insert(*conversation, running.machine.stop().boxed());
                self.free.release(running.slot);
            }
            keep
        });
        for conversation in lost {
            self.reattach(conversation, Vec::new());
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

    /// `maxx units apply` says the group has `count` units: what becomes of
    /// its VM, for it to show. Failures stay counted: it runs at every
    /// boot, before a unit has had the time to fail.
    fn units(&mut self, conversation: ConversationId, count: u32) -> String {
        let idle = self.idle.as_secs() / 60;
        match keep(&mut self.kept, self.config.kept, conversation, count) {
            Kept::On => {
                info!(%conversation, count, "a VM is kept on for its units");
                "This chat's VM stays on and its units keep running; after a restart or a deploy it starts by itself again.".to_owned()
            }
            Kept::Full => format!(
                "The chats whose VMs stay on are full ({} of them): this chat's VM still stops after idling {idle} minutes, and its units with it; they start again when it next boots.",
                self.config.kept
            ),
            Kept::Off => {
                format!("There are no units any more: the VM stops after idling {idle} minutes.")
            }
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
/// `maxx units apply` installs.
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

/// The slots no VM has: the ordinary ones and the operations network's
/// apart, since a group's VM takes only its own kind.
struct Free {
    ordinary: Vec<usize>,
    operations: Vec<usize>,
    /// The first of the operations network's.
    first: usize,
}

impl Free {
    fn new(config: &config::Vm) -> Self {
        let pool = config.operations_slots();
        Self {
            ordinary: (0..pool.start).rev().collect(),
            first: pool.start,
            operations: pool.rev().collect(),
        }
    }

    fn take(&mut self, operations: bool) -> Option<usize> {
        if operations {
            self.operations.pop()
        } else {
            self.ordinary.pop()
        }
    }

    /// Takes `slot` itself, for a VM that runs on it already: whether it
    /// was free, and of the VM's kind.
    fn take_slot(&mut self, slot: usize, operations: bool) -> bool {
        let pool = if operations {
            &mut self.operations
        } else {
            &mut self.ordinary
        };
        match pool.iter().position(|&free| free == slot) {
            Some(at) => {
                pool.remove(at);
                true
            }
            None => false,
        }
    }

    fn release(&mut self, slot: usize) {
        if slot >= self.first {
            self.operations.push(slot);
        } else {
            self.ordinary.push(slot);
        }
    }
}

/// Stops the VM that has gone unused longest, if one isn't lent, busy or
/// kept and its slot is one `fits`, for that slot.
fn evict(
    vms: &mut HashMap<ConversationId, State>,
    kept: &BTreeSet<ConversationId>,
    stopping: &mut HashMap<ConversationId, BoxFuture<'static, ()>>,
    fits: impl Fn(usize) -> bool,
) -> Option<usize> {
    let (&conversation, _) = vms
        .iter()
        .filter(|(conversation, _)| !kept.contains(conversation))
        .filter_map(|(conversation, state)| match state {
            State::Running(running) if !running.lent() && !running.busy() && fits(running.slot) => {
                Some((conversation, running.idle_since))
            }
            _ => None,
        })
        .min_by_key(|(_, idle_since)| *idle_since)?;
    let Some(State::Running(running)) = vms.remove(&conversation) else {
        return None;
    };
    info!(%conversation, "stopped a VM to make room");
    stopping.insert(conversation, running.machine.stop().boxed());
    Some(running.slot)
}

/// Whether a VM on an older image is stopped now, to boot the new one: it
/// is `stale`, nothing of Max's runs in it, and nobody has used it for
/// `QUIET`. Ten minutes unused stands in for "no turn": the service
/// doesn't know of cores, and a core idle that long loses no more than
/// it does to the idle stop or to an eviction.
fn rested(stale: Stale, busy: bool, unused: Duration) -> bool {
    stale && !busy && unused >= QUIET
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_kind_of_group_takes_its_own_slots() {
        let mut free = Free {
            ordinary: vec![1, 0],
            operations: vec![3, 2],
            first: 2,
        };
        assert_eq!(free.take(false), Some(0));
        assert_eq!(free.take(true), Some(2));
        assert_eq!(free.take(true), Some(3));
        assert_eq!(free.take(true), None);
        free.release(2);
        free.release(0);
        assert_eq!(
            (free.ordinary.as_slice(), free.operations.as_slice()),
            (&[1, 0][..], &[2][..])
        );
    }

    /// A VM a max before this one booted keeps its slot, if the slot is
    /// free and of its kind.
    #[test]
    fn a_vm_that_runs_takes_its_own_slot() {
        let mut free = Free {
            ordinary: vec![1, 0],
            operations: vec![3, 2],
            first: 2,
        };
        assert!(free.take_slot(1, false));
        assert!(!free.take_slot(1, false), "taken already");
        assert!(!free.take_slot(3, false), "the operations network's");
        assert!(free.take_slot(3, true));
        assert!(!free.take_slot(9, true), "no such slot");
        assert_eq!(free.take(false), Some(0));
        assert_eq!(free.take(true), Some(2));
    }

    /// A VM is switched if its system isn't the one max boots, and is
    /// stale until then; one switched already, under a max before this
    /// one, is still stale if it booted another kernel.
    #[test]
    fn a_vm_max_attaches_to_is_measured_against_the_image_max_boots() {
        let guest = Guest {
            kernel: "/nix/store/k2-linux/vmlinux".into(),
            initrd: "/nix/store/i-initrd/initrd".into(),
            cmdline: String::new(),
            contract: 1,
            system: "/nix/store/s2-nixos-system".into(),
            registration: "/nix/store/r2-closure-info/registration".into(),
        };
        let boot = |image: &str, kernel: &str| Boot {
            slot: 0,
            contract: 1,
            guest: image.into(),
            units: true,
            kernel: kernel.into(),
            initrd: "/nix/store/i-initrd/initrd".into(),
        };
        let now = Path::new("/nix/store/g2-max-guest.json");
        let (old, new) = ("/nix/store/k1-linux/vmlinux", "/nix/store/k2-linux/vmlinux");
        let same = Attached::of(&boot("/nix/store/g2-max-guest.json", new), now, &guest);
        assert_eq!((same.stale, same.switch), (false, false));
        let older = Attached::of(&boot("/nix/store/g1-max-guest.json", new), now, &guest);
        assert_eq!((older.stale, older.switch), (true, true));
        let switched = Attached::of(&boot("/nix/store/g2-max-guest.json", old), now, &guest);
        assert_eq!((switched.stale, switched.switch), (true, false));
    }

    #[test]
    fn a_vm_on_an_older_image_is_stopped_once_it_is_quiet() {
        let (short, long) = (QUIET - Duration::from_secs(1), QUIET);
        assert!(rested(true, false, long));
        assert!(!rested(true, false, short), "used lately");
        assert!(!rested(true, true, long), "something of Max's runs in it");
        assert!(!rested(false, false, long), "on the image max boots");
    }

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
