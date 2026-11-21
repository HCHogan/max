//! The VM service's task, which owns every VM: it boots one when a call
//! first wants it, attaches to those a max before it booted, lends each
//! to the calls that use it, and stops what has gone unused, unless the
//! group keeps units of Max's in it.

use std::collections::{BTreeSet, HashMap};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use futures_util::FutureExt;
use futures_util::future::BoxFuture;
use max_core::ids::ConversationId;
use serde::Deserialize;
use tokio::sync::mpsc::{self, UnboundedReceiver, UnboundedSender};
use tokio::sync::oneshot;
use tokio::time::{Instant, MissedTickBehavior, interval, timeout};
use tracing::{info, warn};

use super::machine::{self, BOOT, Boot, Booted, Guest, Machine};
use super::ssh::{self, Closes, Connection};
use super::{Internal, NoVm, Request, Stale, Vm, idle, with_units, work};
use crate::config;
use crate::conversation::{Heard, Signal};
use crate::scope::Scope;

/// How often idle and dead VMs are looked for, and kept ones that are
/// down are started.
const SWEEP: Duration = Duration::from_secs(60);
/// A VM on an older image is stopped, to boot the new one, once it has
/// gone unused this long and nothing of Max's runs in it.
const QUIET: Duration = Duration::from_secs(10 * 60);
/// A VM that failed to boot, or stopped by itself, twice within this long
/// boots once without Max's units: one of them may be what stops it.
const FAILING: Duration = Duration::from_secs(30 * 60);
/// What `maxx units list` says (nix/max-jobs.sh): what runs in a guest.
#[derive(Deserialize)]
struct Listed {
    units: Vec<Listing>,
}

/// One of them: `unit` for one /work/.max/systemd keeps, and for what was
/// started `call` or `job`.
#[derive(Deserialize)]
struct Listing {
    kind: String,
}

enum State {
    /// Booting, or being attached to.
    Booting {
        slot: usize,
        waiting: Waiting,
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

struct Running {
    slot: usize,
    machine: Machine,
    connection: Arc<Connection>,
    closes: Closes,
    /// The closer, which closes the channels of calls dropped early, and
    /// the task that asks the guest what runs: they end when max lets go
    /// of the VM.
    _tasks: Scope,
    work: Arc<Path>,
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

type Waiting = Vec<oneshot::Sender<Result<Vm, NoVm>>>;

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

pub(super) async fn run(
    config: Arc<config::Vm>,
    guest: Guest,
    signals: UnboundedSender<Signal>,
    mut requests: UnboundedReceiver<Request>,
    (internal, mut internal_rx): (UnboundedSender<Internal>, UnboundedReceiver<Internal>),
) {
    let (booted, mut booted_rx) = mpsc::unbounded_channel();
    let dir = config.dir.clone();
    let mut service = Service {
        idle: idle(&config),
        free: Free::new(&config),
        config,
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
                    let _ = reply.send(service.units(conversation, count));
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
        reply: oneshot::Sender<Result<Vm, NoVm>>,
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
            let _ = reply.send(Err(NoVm::NotRunning));
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
        let operates = self.config.operates(conversation);
        let pool = self.config.operations_slots();
        let Some(slot) = self.free.take(operates).or_else(|| {
            evict(&mut self.vms, &self.kept, &mut self.stopping, |slot| {
                pool.contains(&slot) == operates
            })
        }) else {
            for reply in waiting {
                let _ = reply.send(Err(NoVm::Full));
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
        let operates = self.config.operates(conversation);
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
                            let _ = reply.send(Err(NoVm::Failed(error.clone())));
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
        let mut running = Running {
            slot,
            machine,
            connection,
            closes,
            _tasks: tasks,
            work: work(&self.config.dir, conversation).into(),
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
