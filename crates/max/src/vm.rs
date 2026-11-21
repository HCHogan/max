//! The groups' VMs: one per conversation, started when a tool first needs
//! it and stopped once it has gone unused for a while, unless the group
//! keeps units of Max's in it. The VM service owns them all; a tool call
//! borrows a VM's SSH connection. See docs/design/vm.md, and "Resident
//! programs" in docs/design/jobs.md.

mod about;
mod events;
mod machine;
mod owner;
pub mod ssh;

use std::collections::BTreeSet;
use std::fmt;
use std::os::fd::AsFd;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use color_eyre::eyre::{Result, WrapErr};
use futures_util::FutureExt;
use max_core::ids::ConversationId;
use tokio::net::UnixListener;
use tokio::sync::mpsc::{self, UnboundedSender};
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;
use tracing::info;

pub use self::about::{About, Unit, taken};
use self::machine::Guest;
use self::ssh::{Closes, Command, Connection};
use crate::config;
use crate::conversation::Signal;
use crate::llm::Upstreams;
use crate::scope::Scope;
use crate::service;
use crate::service::api::Apis;

/// The files `maxx units apply` installs.
const UNIT_KINDS: [&str; 5] = ["service", "socket", "timer", "path", "target"];
/// Where max listens for what the guests ask of it, beside the VMs'
/// directories: one socket for them all.
const SOCKET: &str = "max.sock";
/// The units of Max's background commands in a guest, as its systemctl
/// takes them (nix/max-jobs.sh). A call's is `max-call-…`, which ends
/// with its caller.
const JOBS: &str = "'max-job-*.service'";

/// Whether a background command runs in the guest at `connection`, which
/// its systemd says by how systemctl ends: nothing the guest's shell
/// writes is read. A guest that doesn't answer runs none.
async fn busy(connection: &Connection) -> bool {
    let asked = format!("systemctl is-active --quiet {JOBS}");
    ssh::ask(connection, &asked).await.is_ok()
}

/// Where `conversation`'s /work is on the host, under the VMs' `dir`,
/// whether or not its VM runs.
#[must_use]
pub fn work(dir: &Path, conversation: ConversationId) -> PathBuf {
    dir.join(conversation.to_string()).join("work")
}

/// Listens where the VMs' guests reach max: `max.sock` in `dir`, beside
/// the VMs' directories, one socket for them all, which each VM's port
/// for the host is a link to (`machine`). As a unit of systemd's the
/// socket isn't max's to make: systemd listens there and gives max the
/// socket ([`given`]), so what a guest asks while max restarts waits at it
/// for the max that comes. Otherwise, as under vm-check or in a terminal,
/// max binds it, in place of what an earlier one left.
fn listen(dir: &Path) -> Result<UnixListener> {
    let socket = dir.join(SOCKET);
    if let Some(given) = given(&socket) {
        info!(socket = %socket.display(), "listening at the socket systemd gave max");
        return given.wrap_err("taking the socket systemd listens at");
    }
    let _ = std::fs::remove_file(&socket);
    info!(socket = %socket.display(), "listening at a socket of max's own");
    UnixListener::bind(&socket).wrap_err_with(|| format!("listening at {}", socket.display()))
}

/// The socket systemd listens at for this process, if max runs as its
/// unit: with `StandardInput=socket` (`maxx.socket` and max's unit,
/// nix/module.nix) it is the standard input, which takes no `unsafe` to
/// have. systemd names no socket it gives so, with no `LISTEN_FDS`: it is
/// known by what it is, a Unix socket bound at `socket`. A terminal, or
/// nothing, as under vm-check, isn't one.
fn given(socket: &Path) -> Option<std::io::Result<UnixListener>> {
    let input = std::io::stdin().as_fd().try_clone_to_owned().ok()?;
    let listener = std::os::unix::net::UnixListener::from(input);
    let bound = listener.local_addr().ok()?;
    (bound.as_pathname() == Some(socket)).then(move || {
        // systemd gives it blocking.
        listener.set_nonblocking(true)?;
        UnixListener::from_std(listener)
    })
}

/// How long a VM may idle, by the configuration.
fn idle(config: &config::Vm) -> Duration {
    Duration::from_secs(config.idle_minutes * 60)
}

/// A handle to the VM service; it stops once every handle is gone.
#[derive(Clone, Debug)]
pub struct Vms {
    requests: UnboundedSender<Request>,
    apis: Arc<Apis>,
    idle: Duration,
    /// The groups on the operations network.
    operating: Arc<BTreeSet<ConversationId>>,
    /// Ends max's service to the VMs.
    listening: CancellationToken,
}

enum Request {
    /// A conversation's VM.
    Vm {
        conversation: ConversationId,
        /// Whether to start it if it isn't running.
        boot: bool,
        reply: oneshot::Sender<Result<Vm, NoVm>>,
    },
    /// Stop every VM, and say once they have stopped.
    Shut { reply: oneshot::Sender<()> },
}

/// Why there is no VM for a call to use, as its caller is told.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum NoVm {
    /// The service has ended, as Max stops.
    #[error("the VM service has stopped")]
    Stopped,
    /// It was asked for only if it runs.
    #[error("the VM isn't running")]
    NotRunning,
    /// Every slot has a VM that can't be stopped for this one.
    #[error("too many VMs are running at once; try again in a while")]
    Full,
    /// It didn't boot, or its guest didn't let max in: why, with the
    /// causes. Everyone who waited for the boot is told.
    #[error("the VM didn't start: {0}")]
    Failed(String),
}

/// A running VM, lent to a tool call. It isn't idle while one is held.
#[derive(Clone)]
pub struct Vm {
    connection: Arc<Connection>,
    closes: Closes,
    work: Arc<Path>,
    _lent: Arc<()>,
}

/// By the /work it is the VM of.
impl fmt::Debug for Vm {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Vm")
            .field("work", &self.work)
            .finish_non_exhaustive()
    }
}

impl Vms {
    /// Starts the service in `scope`; what programs in the VMs say to Max
    /// goes to `signals`. What they call besides Max's tools is carried
    /// here too: the models, `agents`, if the background agents have one,
    /// and the `apis` the host keeps the keys of.
    ///
    /// # Errors
    ///
    /// If the guest's image can't be read, the VMs' directory can't be made,
    /// or their socket can't be listened at.
    pub fn start(
        config: config::Vm,
        scope: &mut Scope,
        signals: UnboundedSender<Signal>,
        agents: Option<Arc<Upstreams>>,
        apis: Arc<Apis>,
    ) -> Result<Self> {
        let guest = Guest::load(&config.guest)?;
        std::fs::create_dir_all(&config.dir)?;
        let idle = idle(&config);
        let operating = Arc::new(
            config
                .operations
                .iter()
                .flat_map(|ops| &ops.conversations)
                .copied()
                .collect(),
        );
        // Where every VM's guest reaches max: the tools, the timeline's
        // rows, the models and the keyed APIs. Whose
        // VM a connection is from is systemd's to say, by the process
        // that made it.
        let listener = listen(&config.dir)?;
        let config = Arc::new(config);
        let units = Arc::clone(&config);
        let whose: service::Whose = Arc::new(move |pid| {
            let units = Arc::clone(&units);
            async move { machine::whose(&units, pid).await }.boxed()
        });
        let listener = service::Waited::new(listener, whose);
        let calls = signals.clone();
        // The service's own end, which `stop_listening` brings before
        // the scope's: no more is taken, and the timeline's streams
        // end, while the calls it has go on.
        let listening = CancellationToken::new();
        let ends = listening.clone();
        let carried = service::agents(agents).merge(service::api::router(Arc::clone(&apis)));
        scope.spawn(move |stop| async move {
            let host = events::router(calls.clone(), ends.clone());
            let app = service::router(calls, host).merge(carried);
            let serving = service::serve(listener, app, ends.clone());
            tokio::pin!(serving);
            tokio::select! {
                () = &mut serving => {}
                () = stop.cancelled() => {
                    ends.cancel();
                    serving.await;
                }
            }
        });
        let (requests, rx) = mpsc::unbounded_channel();
        scope.spawn(move |_| owner::run(config, guest, signals, rx));
        Ok(Self {
            requests,
            apis,
            idle,
            operating,
            listening,
        })
    }

    /// Takes no more of what the VMs ask, as max begins to stop. What it
    /// has taken goes on, until its conversation stops; what comes from
    /// here on waits at the socket systemd holds, for the max that comes.
    pub fn stop_listening(&self) {
        self.listening.cancel();
    }

    /// Whether the conversation's VM is on the operations network.
    #[must_use]
    pub fn operates(&self, conversation: ConversationId) -> bool {
        self.operating.contains(&conversation)
    }

    /// How long a VM may go without a command before it is stopped,
    /// unless it is kept on.
    #[must_use]
    pub fn idle(&self) -> Duration {
        self.idle
    }

    /// The HTTP APIs the VMs call through the host, as the system prompt
    /// lists them.
    #[must_use]
    pub fn apis(&self) -> &str {
        self.apis.prompt()
    }

    /// The conversation's VM, started if it isn't running; or why there
    /// isn't one.
    ///
    /// # Errors
    ///
    /// [`NoVm`], which says why there is none.
    pub async fn get(&self, conversation: ConversationId) -> Result<Vm, NoVm> {
        self.ask(conversation, true).await
    }

    /// The conversation's VM if it runs: nothing is started for the
    /// asking.
    pub async fn running(&self, conversation: ConversationId) -> Option<Vm> {
        self.ask(conversation, false).await.ok()
    }

    async fn ask(&self, conversation: ConversationId, boot: bool) -> Result<Vm, NoVm> {
        let (reply, answer) = oneshot::channel();
        let request = Request::Vm {
            conversation,
            boot,
            reply,
        };
        self.requests.send(request).map_err(|_| NoVm::Stopped)?;
        answer.await.map_err(|_| NoVm::Stopped)?
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
    /// Starts `line`, a call (`maxx jobs run`), in the guest's shell, and
    /// gives it `input`. The guest stops the call when what this returns
    /// is dropped, or max's connection goes.
    ///
    /// # Errors
    ///
    /// If the command's channel can't be opened, or the line or its input
    /// sent.
    pub async fn command(&self, line: &str, input: &[u8]) -> Result<Command> {
        Command::start(&self.connection, line, input, self.closes.clone()).await
    }

    /// Runs `line`, a command of max's own that is no unit, and waits for
    /// it: what it wrote to stdout.
    ///
    /// # Errors
    ///
    /// If the command can't be run, or doesn't exit with 0.
    pub async fn ask(&self, line: &str) -> Result<String> {
        ssh::ask(&self.connection, line).await
    }

    /// What the guest says of itself, and of those of `units` its systemd
    /// knows: for `/status`.
    ///
    /// # Errors
    ///
    /// As [`Vm::ask`], or if what the guest says can't be read.
    pub async fn about(&self, units: &[String]) -> Result<About> {
        about::read(&self.ask(&about::line(units)).await?)
    }

    /// Has the guest stop every background command, and waits until it
    /// has. One stopped on request tells nobody of its end.
    ///
    /// # Errors
    ///
    /// As [`Vm::ask`].
    pub async fn stop_jobs(&self) -> Result<()> {
        self.ask(&format!("systemctl stop {JOBS}")).await?;
        Ok(())
    }

    /// The SSH connection to the guest.
    #[must_use]
    pub fn connection(&self) -> &Connection {
        &self.connection
    }

    /// The host's side of the guest's /work.
    #[must_use]
    pub fn work(&self) -> &Path {
        &self.work
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
        .map(ConversationId::new)
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
