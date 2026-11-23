//! The VM service's task, which owns every VM: it boots one when a call
//! first wants it, attaches to those a max before it booted on the image
//! it boots itself, lends each to the calls that use it, and stops what
//! has gone unused, unless the group keeps units of Max's in it.

use std::collections::{BTreeSet, HashMap};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use futures_util::FutureExt;
use futures_util::future::BoxFuture;
use max_core::ids::ConversationId;
use tokio::sync::mpsc::{self, UnboundedReceiver, UnboundedSender};
use tokio::sync::oneshot;
use tokio::time::{Instant, MissedTickBehavior, interval, timeout};
use tracing::{info, warn};

use super::machine::{self, BOOT, Boot, Booted, Guest, Machine};
use super::ssh::{self, Closes, Connection};
use super::{NoVm, Request, Vm, busy, idle, units, with_units, work};
use crate::config;
use crate::conversation::{Heard, Signal};
use crate::scope::Scope;

/// How often idle and dead VMs are looked for, and kept ones that are
/// down are started.
const SWEEP: Duration = Duration::from_secs(60);
/// A VM that failed to boot, or stopped by itself, twice within this long
/// boots once without Max's units: one of them may be what stops it.
const FAILING: Duration = Duration::from_secs(30 * 60);

enum State {
    /// Booting, or being attached to.
    Booting {
        slot: usize,
        waiting: Waiting,
        /// With Max's units.
        units: bool,
        /// Booted by a max before this one, which attaches to it.
        attached: bool,
    },
    Running(Box<Running>),
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
    /// The slots no VM has, the next to take last.
    free: Vec<usize>,
    boots: Scope,
    booted: UnboundedSender<(ConversationId, Result<Booted, Unusable>)>,
    /// The VMs max had systemd stop a moment ago, each done once systemd
    /// has the request: a boot of the same VM waits for that.
    stopping: HashMap<ConversationId, BoxFuture<'static, ()>>,
    /// Where a VM's task says that something of Max's runs in its guest.
    busy: UnboundedSender<ConversationId>,
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
) {
    let (booted, mut booted_rx) = mpsc::unbounded_channel();
    let (busy, mut busy_rx) = mpsc::unbounded_channel();
    let dir = config.dir.clone();
    let mut service = Service {
        idle: idle(&config),
        free: (0..config.slots.len()).rev().collect(),
        config,
        guest: Arc::new(guest),
        signals,
        vms: HashMap::new(),
        boots: Scope::new(),
        booted,
        stopping: HashMap::new(),
        busy,
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
            Some(conversation) = busy_rx.recv() => service.busy(conversation),
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
        let Some(slot) = self
            .free
            .pop()
            .or_else(|| evict(&mut self.vms, &self.kept, &mut self.stopping))
        else {
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
                attached: false,
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
            let slot = (slot, &config.slots[slot]);
            let booting = machine::boot(&config, &guest, conversation, slot, units);
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
    /// booted, if this one can use it: it kept a record of its boot, it
    /// booted the image max boots, and its slot is free. One it can't use
    /// is stopped, with what runs in it, and boots again when it is next
    /// needed: a guest and a max of two images have nothing agreed
    /// between them.
    async fn attach(&mut self, conversation: ConversationId) {
        let machine = Machine::of(&self.config, conversation);
        let usable = match Boot::read(&machine.dir).await {
            Err(error) => Err(format!("{error:#}")),
            Ok(boot) if boot.guest != self.config.guest => Err(format!(
                "it booted the image {}, and max boots {}",
                boot.guest.display(),
                self.config.guest.display()
            )),
            Ok(boot) => match self.free.iter().position(|&free| free == boot.slot) {
                Some(at) => {
                    self.free.remove(at);
                    Ok(boot)
                }
                None => Err(format!("its slot, {}, isn't free", boot.slot)),
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
        self.vms.insert(
            conversation,
            State::Booting {
                slot: boot.slot,
                waiting: Vec::new(),
                units: boot.units,
                attached: true,
            },
        );
        self.attaching(conversation);
    }

    /// max's connection to `conversation`'s VM is gone. The VM may run
    /// on, as when its sshd restarted: max attaches to it again, with
    /// `waiting` for it. One it can't reach any more is stopped as one
    /// that failed, and one that has ended by itself failed too, and
    /// boots again for whoever waits.
    fn reattach(&mut self, conversation: ConversationId, waiting: Waiting) {
        let Some(State::Running(running)) = self.vms.remove(&conversation) else {
            return;
        };
        warn!(%conversation, "the connection to a VM is gone; attaching to it again");
        let (slot, units) = (running.slot, running.units);
        drop(running);
        self.vms.insert(
            conversation,
            State::Booting {
                slot,
                waiting,
                units,
                attached: true,
            },
        );
        self.attaching(conversation);
    }

    /// Attaches to `conversation`'s VM in a task, which says how it went.
    fn attaching(&mut self, conversation: ConversationId) {
        let (config, booted) = (Arc::clone(&self.config), self.booted.clone());
        self.boots.spawn(move |_| async move {
            let result = match machine::attach(&config, conversation).await {
                Ok(Some(booted)) => {
                    info!(%conversation, "attached to a VM that runs");
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
            self.free.push(slot);
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
                self.free.push(slot);
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
        // the VM for it: the guest is asked whether any runs. A unit that
        // /work/.max/systemd keeps isn't work under way: the VM is kept
        // on for those another way.
        let (asked, said) = (Arc::clone(&connection), self.busy.clone());
        tasks.spawn(move |stop| async move {
            let mut every = interval(SWEEP);
            every.set_missed_tick_behavior(MissedTickBehavior::Delay);
            loop {
                tokio::select! {
                    () = stop.cancelled() => return,
                    _ = every.tick() => {}
                }
                if busy(&asked).await && said.send(conversation).is_err() {
                    return;
                }
            }
        });
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
            units,
        };
        for reply in waiting {
            let _ = reply.send(Ok(running.lend()));
        }
        self.vms
            .insert(conversation, State::Running(Box::new(running)));
        // Max was told when it booted so.
        if !units && !attached {
            let text = "这个群的 VM 最近两次没开起来，或者开着开着自己停了，这次开机就没装 /work/.max/systemd 里的 unit。多半是哪个 unit 的问题：用 systemctl、journalctl 查清楚、改好，再跑 maxx units apply。".to_owned();
            let heard = Heard::Vm(text);
            let _ = self.signals.send(Signal::Heard {
                conversation,
                heard,
            });
        }
    }

    /// Keeps on the VMs whose groups have units, as their /work says now;
    /// stops idle VMs, but kept ones; attaches again to those whose
    /// connection is gone; starts kept ones that are down.
    fn sweep(&mut self) {
        let now = Instant::now();
        // What a group keeps in /work/.max/systemd changes only while its
        // VM runs. A few small directories, read where they are.
        for (&conversation, state) in &self.vms {
            if let State::Running(running) = state {
                let has = !units(&running.work).is_empty();
                let was = self.kept.contains(&conversation);
                match (
                    was,
                    keep(&mut self.kept, self.config.kept, conversation, has),
                ) {
                    (false, true) => info!(%conversation, "a VM is kept on for its units"),
                    (true, false) => info!(%conversation, "a VM is no longer kept on"),
                    _ => {}
                }
            }
        }
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
            } else if !kept && now >= running.idle_since + self.idle {
                info!(%conversation, "stopped an idle VM");
                false
            } else {
                true
            };
            if !keep {
                self.stopping
                    .insert(*conversation, running.machine.stop().boxed());
                self.free.push(running.slot);
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
}

/// Keeps a group on while it `has` units, if it is kept already or fewer
/// than `most` are: whether it is kept now. One past the `most` isn't, and
/// its VM stops when idle, its units with it, until the next boot.
fn keep(
    kept: &mut BTreeSet<ConversationId>,
    most: usize,
    conversation: ConversationId,
    has: bool,
) -> bool {
    if !has {
        kept.remove(&conversation);
        false
    } else if kept.contains(&conversation) || kept.len() < most {
        kept.insert(conversation);
        true
    } else {
        false
    }
}

/// Stops the VM that has gone unused longest, if one isn't lent, busy or
/// kept, for its slot.
fn evict(
    vms: &mut HashMap<ConversationId, State>,
    kept: &BTreeSet<ConversationId>,
    stopping: &mut HashMap<ConversationId, BoxFuture<'static, ()>>,
) -> Option<usize> {
    let (&conversation, _) = vms
        .iter()
        .filter(|(conversation, _)| !kept.contains(conversation))
        .filter_map(|(conversation, state)| match state {
            State::Running(running) if !running.lent() && !running.busy() => {
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
