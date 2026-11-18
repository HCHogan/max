//! A VM as a unit of the host's systemd, which max starts and stops but
//! doesn't own: the VM outlives max, and the max that comes after attaches
//! to it. max makes the VM's directory and disk, writes what the unit and
//! its own successor need (`boot.env`, `boot.json`, `ssh.key`), and has
//! systemd start the unit; then SSH once the guest answers. The unit's
//! processes are the NixOS module's to run (nix/module.nix). See "VM
//! processes" and "Lifetimes move to systemd" in docs/rust-rewrite.md.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use color_eyre::eyre::{Result, WrapErr, bail, eyre};
use max_core::ids::ConversationId;
use russh::keys::ssh_key::LineEnding;
use russh::keys::{Algorithm, PrivateKey};
use serde::{Deserialize, Serialize};
use tokio::fs;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;
use tokio::time::{Instant, sleep, timeout_at};
use tracing::warn;

use super::ssh::{self, Connection};
use crate::config::{self, Slot};

/// How long the guest has to boot and let max in.
pub const BOOT: Duration = Duration::from_secs(60);
/// How long a VM that runs already has to let max in.
const ATTACH: Duration = Duration::from_secs(10);
/// Between tries to log in while the guest boots.
const RETRY: Duration = Duration::from_millis(100);

/// What the unit reads of a boot: nix/module.nix's `EnvironmentFile`.
const ENV: &str = "boot.env";
/// What the next max reads of it.
const RECORD: &str = "boot.json";
/// The key max logs in with, made for the boot.
const KEY: &str = "ssh.key";
/// Where the guest's calls arrive: the hybrid vsock's port 7777, as
/// cloud-hypervisor names the socket it connects to when the guest
/// connects to the host's port. A link to max's own socket ([`calls`]).
const CALLS: &str = "notify.vsock_7777";

/// What the flake's `guest` package says to boot.
#[derive(Debug, Deserialize)]
pub struct Guest {
    pub kernel: PathBuf,
    pub initrd: PathBuf,
    pub cmdline: String,
    /// The contract it keeps with a host: nix/contract.nix.
    pub contract: u32,
    /// The system it boots into, which a running guest of an older image
    /// is switched to...
    pub system: PathBuf,
    /// ...and that system's paths, for the guest's Nix database.
    pub registration: PathBuf,
}

impl Guest {
    pub fn load(path: &Path) -> Result<Self> {
        let text = std::fs::read_to_string(path)
            .wrap_err_with(|| format!("reading the guest {}", path.display()))?;
        Ok(serde_json::from_str(&text)?)
    }
}

/// What max wrote down of a VM as it booted it, for the max that attaches
/// to it later: where it is, and what it runs.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Boot {
    /// Its tap's slot.
    pub slot: usize,
    /// The contract of the guest it booted.
    pub contract: u32,
    /// The image it runs: the configuration's `guest` when it booted, or
    /// the one it was switched to since.
    pub guest: PathBuf,
    /// Whether with Max's units.
    pub units: bool,
    /// What it booted, which no switch changes.
    pub kernel: PathBuf,
    pub initrd: PathBuf,
}

impl Boot {
    /// The one in the VM's directory.
    pub async fn read(dir: &Path) -> Result<Self> {
        let path = dir.join(RECORD);
        let text = fs::read(&path)
            .await
            .wrap_err_with(|| format!("reading {}", path.display()))?;
        Ok(serde_json::from_slice(&text)?)
    }

    async fn write(&self, dir: &Path) -> Result<()> {
        fs::write(dir.join(RECORD), serde_json::to_vec(self)?).await?;
        Ok(())
    }

    /// Whether a VM of this boot has to boot again to run `guest`'s image
    /// whole: a switch gives it the system, and leaves the kernel and the
    /// initrd it booted.
    pub fn reboots_for(&self, guest: &Guest) -> bool {
        self.kernel != guest.kernel || self.initrd != guest.initrd
    }
}

/// A conversation's VM: its unit, and what goes with it on the host.
#[derive(Clone, Debug)]
pub struct Machine {
    systemctl: PathBuf,
    unit: String,
    /// The VM's files.
    pub dir: PathBuf,
    /// The link that keeps what it booted from the garbage collector;
    /// those beside it, named after it with a dot and an image's name,
    /// keep each image it was switched to since.
    root: Option<PathBuf>,
}

impl Machine {
    pub fn of(config: &config::Vm, conversation: ConversationId) -> Self {
        let instance = format!("{}{}", config.instances, conversation.get());
        Self {
            systemctl: config.systemctl.clone(),
            unit: format!("{}{instance}.service", config.unit),
            dir: config.dir.join(conversation.to_string()),
            root: config.roots.as_ref().map(|roots| roots.join(instance)),
        }
    }

    /// Has systemd stop it, without waiting for it to end: the VM ends,
    /// and what it ran is the collector's again. The request is on its
    /// way when this returns, and systemd has it when what this returns
    /// is done: a boot of the same VM waits for that, since a start that
    /// reached systemd first would be the one stopped.
    pub fn stop(&self) -> impl Future<Output = ()> + Send + use<> {
        let stopping = self
            .systemctl(&["stop", "--no-block"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        self.unroot();
        let unit = self.unit.clone();
        async move {
            if let Err(error) = stopping.await {
                warn!(%unit, %error, "couldn't ask systemd to stop a VM");
            }
        }
    }

    /// What it ran is the collector's again: a VM that has ended. A few
    /// unlinks, done before this returns: left for later, they could take
    /// the link of the boot that comes next.
    pub fn unroot(&self) {
        for root in self.roots() {
            let _ = std::fs::remove_file(root);
        }
    }

    /// Its links among the collector's roots: what it booted, and each
    /// image it was switched to since.
    fn roots(&self) -> Vec<PathBuf> {
        let Some(root) = &self.root else {
            return Vec::new();
        };
        let mut roots = vec![root.clone()];
        let name = root.file_name().and_then(|name| name.to_str());
        if let (Some(dir), Some(name)) = (root.parent(), name)
            && let Ok(entries) = std::fs::read_dir(dir)
        {
            let switched = format!("{name}.");
            roots.extend(
                entries
                    .filter_map(|entry| Some(entry.ok()?.path()))
                    .filter(|path| {
                        let name = path.file_name().and_then(|name| name.to_str());
                        name.is_some_and(|name| name.starts_with(&switched))
                    }),
            );
        }
        roots
    }

    /// Roots `image`, which the VM boots.
    async fn keep(&self, image: &Path) {
        if let Some(root) = &self.root {
            link(image, root).await;
        }
    }

    /// Roots `image`, which its guest is switched to, beside what it
    /// booted and what it was switched to before: what started under
    /// each of those may run on from it.
    async fn keep_too(&self, image: &Path) {
        let name = image.file_name().and_then(|name| name.to_str());
        if let (Some(root), Some(name)) = (&self.root, name) {
            let mut beside = root.clone().into_os_string();
            beside.push(format!(".{name}"));
            link(image, Path::new(&beside)).await;
        }
    }

    /// Stops it, and waits until it has stopped.
    pub async fn stopped(&self) {
        if let Err(error) = self.run(&["stop"]).await {
            warn!(unit = %self.unit, error = format!("{error:#}"), "couldn't stop a VM");
        }
        self.unroot();
    }

    /// Whether its unit runs.
    async fn active(&self) -> bool {
        let asked = self.systemctl(&["is-active", "--quiet"]).status().await;
        asked.is_ok_and(|status| status.success())
    }

    fn systemctl(&self, words: &[&str]) -> Command {
        let mut command = Command::new(&self.systemctl);
        command.args(words).arg(&self.unit);
        command
    }

    async fn run(&self, words: &[&str]) -> Result<()> {
        let out = self
            .systemctl(words)
            .stdin(Stdio::null())
            .output()
            .await
            .wrap_err("running systemctl")?;
        if !out.status.success() {
            bail!(
                "systemctl {} {}: {}",
                words.join(" "),
                self.unit,
                String::from_utf8_lossy(&out.stderr).trim()
            );
        }
        Ok(())
    }
}

/// The conversations whose VMs run, by the units systemd has active: the
/// ones a max before this one booted.
pub async fn running(config: &config::Vm) -> Result<Vec<ConversationId>> {
    let pattern = format!("{}{}*", config.unit, config.instances);
    let listed = Command::new(&config.systemctl)
        .args(["list-units", "--type=service", "--state=active"])
        .args(["--no-legend", "--plain", &pattern])
        .stdin(Stdio::null())
        .output()
        .await
        .wrap_err("running systemctl")?;
    if !listed.status.success() {
        bail!("{}", String::from_utf8_lossy(&listed.stderr).trim());
    }
    let prefix = format!("{}{}", config.unit, config.instances);
    Ok(String::from_utf8_lossy(&listed.stdout)
        .lines()
        .filter_map(|line| conversation(line.split_whitespace().next()?, &prefix))
        .collect())
}

/// Lets the collector have what the VMs that no longer run were rooted
/// for: all but those of `running`. A VM that ended without max, as when
/// the host restarted, left its links, which max removes only as it
/// stops one.
pub fn unroot_ended(config: &config::Vm, running: &[ConversationId]) {
    if let Some(roots) = &config.roots {
        unroot_but(roots, &config.instances, running);
    }
}

/// [`unroot_ended`]'s work, among the links in `roots` of the VMs whose
/// instances' names begin with `instances`: another's, such as
/// vm-check's beside max's, are left.
fn unroot_but(roots: &Path, instances: &str, running: &[ConversationId]) {
    let Ok(entries) = std::fs::read_dir(roots) else {
        return;
    };
    for entry in entries.filter_map(Result::ok) {
        let name = entry.file_name();
        // `7`, or `7.` and an image's name.
        let id = name
            .to_str()
            .and_then(|name| name.strip_prefix(instances))
            .and_then(|rest| rest.split('.').next()?.parse().ok());
        if id.is_some_and(|id| !running.contains(&ConversationId::new(id))) {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

/// The conversation whose VM the unit `name` is, if it is one of those
/// whose names begin with `prefix`: another's, such as vm-check's beside
/// max's, isn't.
fn conversation(name: &str, prefix: &str) -> Option<ConversationId> {
    let instance = name.strip_prefix(prefix)?.strip_suffix(".service")?;
    instance.parse().ok().map(ConversationId::new)
}

/// Makes the guest's port for the host, in the VM's directory `dir`, max's
/// socket: a link to the one socket beside the VMs' directories
/// (`super::SOCKET`), which systemd listens at whether max runs or not.
/// What a guest asks comes to max itself, and waits there while max
/// restarts. Which VM a connection is from is [`whose`] to say.
async fn calls(dir: &Path) -> std::io::Result<()> {
    let link = dir.join(CALLS);
    // An earlier boot's.
    let _ = fs::remove_file(&link).await;
    fs::symlink(Path::new("..").join(super::SOCKET), &link).await
}

/// The conversation whose VM the process `pid` is of, if it is one's:
/// systemd says which unit a process belongs to, and a VM's unit is
/// named for its conversation. A guest's connection to max is made by
/// its VM's cloud-hypervisor, the unit's main process, so this is whose
/// guest a connection at max's socket is from. /proc doesn't say: each
/// unit is in a user namespace of its own, and with `ProtectProc=invisible`
/// sees none of another's processes.
pub async fn whose(config: &config::Vm, pid: i32) -> Option<ConversationId> {
    let asked = Command::new(&config.systemctl)
        .args(["whoami", &pid.to_string()])
        .stdin(Stdio::null())
        .output()
        .await
        .ok()?;
    if !asked.status.success() {
        return None;
    }
    let prefix = format!("{}{}", config.unit, config.instances);
    conversation(String::from_utf8_lossy(&asked.stdout).trim(), &prefix)
}

/// A VM max can use: its unit, and the SSH connection.
pub struct Booted {
    pub machine: Machine,
    pub connection: Connection,
}

/// Boots `conversation`'s VM on `slot`, the slot `index`; without the
/// units Max keeps in its /work unless `units`.
pub async fn boot(
    config: &config::Vm,
    guest: &Guest,
    conversation: ConversationId,
    (index, slot): (usize, &Slot),
    operations: Option<&config::Operations>,
    units: bool,
) -> Result<Booted> {
    let machine = Machine::of(config, conversation);
    let dir = &machine.dir;
    fs::create_dir_all(dir.join("work")).await?;
    disk(config, &dir.join("nix.img")).await?;
    calls(dir)
        .await
        .wrap_err("linking the guest's port to max's socket")?;

    let key = PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519)?;
    let public = key.public_key().to_openssh()?;
    let blob = public
        .split(' ')
        .nth(1)
        .ok_or_else(|| eyre!("an OpenSSH public key without its blob"))?;
    // For the max that attaches to the VM: it runs on after this one.
    secret(&dir.join(KEY), key.to_openssh(LineEnding::LF)?.as_bytes()).await?;
    // On the operations network, the tailnet's resolvers come first, and
    // the guest's ssh takes a short host name as one under its domain.
    let dns: Vec<String> = operations
        .into_iter()
        .flat_map(|ops| &ops.dns)
        .chain(&config.dns)
        .map(ToString::to_string)
        .collect();
    let mut cmdline = format!(
        "{} max.ip={} max.gateway={} max.dns={} max.key={blob}",
        guest.cmdline,
        slot.address,
        slot.gateway,
        dns.join(","),
    );
    if let Some(ops) = operations {
        cmdline.push_str(&format!(" max.domain={}", ops.domain));
    }
    if let Some(author) = &config.author {
        cmdline.push_str(&format!(" max.git={},{}", author.name, author.email));
    }
    if !units {
        cmdline.push_str(" max.units=off");
    }
    let env = [
        ("TAP", slot.tap.clone()),
        ("CPUS", config.cpus.to_string()),
        ("MEMORY_MIB", config.memory_mib.to_string()),
        ("KERNEL", guest.kernel.display().to_string()),
        ("INITRD", guest.initrd.display().to_string()),
        ("CMDLINE", cmdline),
    ];
    fs::write(dir.join(ENV), environment(&env)).await?;
    let record = Boot {
        slot: index,
        contract: guest.contract,
        guest: config.guest.clone(),
        units,
        kernel: guest.kernel.clone(),
        initrd: guest.initrd.clone(),
    };
    record.write(dir).await?;
    // What the guest reads from the host's store, for as long as it runs.
    machine.unroot();
    machine.keep(&config.guest).await;
    machine.run(&["start"]).await?;

    let key = Arc::new(key);
    let socket = dir.join("notify.vsock");
    let deadline = Instant::now() + BOOT;
    loop {
        let error = match ssh::connect(&socket, Arc::clone(&key)).await {
            Ok(connection) => {
                return Ok(Booted {
                    machine,
                    connection,
                });
            }
            Err(error) => error,
        };
        let gone = !machine.active().await;
        if gone || Instant::now() >= deadline {
            machine.stopped().await;
            if gone {
                let log = fs::read_to_string(dir.join("cloud-hypervisor.log")).await;
                bail!("the VM's unit ended: {}", log.unwrap_or_default().trim());
            }
            return Err(error.wrap_err(format!("the guest didn't let max in within {BOOT:?}")));
        }
        sleep(RETRY).await;
    }
}

/// Attaches to `conversation`'s VM, which runs: logs in with the key its
/// boot left. None if its unit has ended: there is nothing to attach to,
/// and its socket, which stays, would only be waited on.
pub async fn attach(config: &config::Vm, conversation: ConversationId) -> Result<Option<Booted>> {
    let machine = Machine::of(config, conversation);
    if !machine.active().await {
        return Ok(None);
    }
    let dir = &machine.dir;
    let key = fs::read(dir.join(KEY)).await.wrap_err("reading its key")?;
    let key = Arc::new(PrivateKey::from_openssh(key)?);
    let connection = match let_in(&dir.join("notify.vsock"), &key, ATTACH).await {
        Ok(connection) => connection,
        // It ended while max tried.
        Err(_) if !machine.active().await => return Ok(None),
        Err(error) => return Err(error),
    };
    Ok(Some(Booted {
        machine,
        connection,
    }))
}

/// Logs in at `socket`, again while the guest refuses, for at most
/// `within`. One that takes the connection and then says nothing has no
/// longer: such a VM outlives max, and would keep the next one waiting
/// as well.
async fn let_in(socket: &Path, key: &Arc<PrivateKey>, within: Duration) -> Result<Connection> {
    let deadline = Instant::now() + within;
    let mut refused = None;
    while Instant::now() < deadline {
        match timeout_at(deadline, ssh::connect(socket, Arc::clone(key))).await {
            Ok(Ok(connection)) => return Ok(connection),
            Ok(Err(error)) => refused = Some(error),
            Err(_) => break,
        }
        sleep(RETRY).await;
    }
    Err(refused
        .unwrap_or_else(|| eyre!("it took the connection and said nothing"))
        .wrap_err(format!("the guest didn't let max in within {within:?}")))
}

/// Has the guest of a VM that runs an older image switch to `guest`'s
/// system where it runs, with what runs in it left running: whether the
/// VM must still boot again for the image, its kernel or initrd being
/// another's. The new image's own `max-switch` does it (nix/guest.nix),
/// so a guest older than that command is switched too.
pub async fn switch(
    config: &config::Vm,
    guest: &Guest,
    machine: &Machine,
    connection: &Connection,
) -> Result<bool> {
    let mut boot = Boot::read(&machine.dir).await?;
    let system = guest.system.display().to_string();
    let line = format!(
        "{} {} {}",
        ssh::quote(&format!("{system}/sw/bin/max-switch")),
        ssh::quote(&system),
        ssh::quote(&guest.registration.display().to_string()),
    );
    // Rooted before the guest runs it.
    machine.keep_too(&config.guest).await;
    ssh::ask(connection, &line).await?;
    boot.guest.clone_from(&config.guest);
    boot.write(&machine.dir).await?;
    Ok(boot.reboots_for(guest))
}

/// Makes `root` a link to `image`, in place of what it was.
async fn link(image: &Path, root: &Path) {
    let _ = fs::remove_file(root).await;
    if let Err(error) = fs::symlink(image, root).await {
        warn!(root = %root.display(), %error, "couldn't root a VM's image");
    }
}

/// Writes `bytes` to `path`, a file only max reads.
async fn secret(path: &Path, bytes: &[u8]) -> Result<()> {
    let _ = fs::remove_file(path).await;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .await?;
    file.write_all(bytes).await?;
    file.flush().await?;
    Ok(())
}

/// `variables` as systemd reads an `EnvironmentFile`: a line each, the
/// value in double quotes.
fn environment(variables: &[(&str, String)]) -> String {
    variables
        .iter()
        .map(|(name, value)| {
            let value = value.replace('\\', "\\\\").replace('"', "\\\"");
            format!("{name}=\"{value}\"\n")
        })
        .collect()
}

/// The store disk, made on the first boot and grown when the configured
/// size grows; the guest grows its file system to match.
async fn disk(config: &config::Vm, image: &Path) -> Result<()> {
    let size = u64::from(config.disk_gib) << 30;
    match fs::metadata(image).await {
        Ok(metadata) => {
            if metadata.len() < size {
                fs::OpenOptions::new()
                    .write(true)
                    .open(image)
                    .await?
                    .set_len(size)
                    .await?;
            }
        }
        Err(_) => {
            let file = fs::File::create(image).await?;
            file.set_len(size).await?;
            let status = Command::new(&config.mkfs)
                .args(["-q", "-L", "max-nix"])
                .arg(image)
                .stdin(Stdio::null())
                .status()
                .await
                .wrap_err("running mkfs")?;
            if !status.success() {
                let _ = fs::remove_file(image).await;
                bail!("mkfs failed: {status}");
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {

    use super::*;

    #[test]
    fn a_boot_is_read_as_it_was_written() {
        let boot = Boot {
            slot: 3,
            contract: 1,
            guest: "/nix/store/x-max-guest.json".into(),
            units: true,
            kernel: "/nix/store/k-linux/vmlinux".into(),
            initrd: "/nix/store/i-initrd/initrd".into(),
        };
        let written = serde_json::to_string(&boot).unwrap();
        assert_eq!(serde_json::from_str::<Boot>(&written).unwrap(), boot);
    }

    /// A switch gives a running guest the new system, not the kernel or
    /// the initrd.
    #[test]
    fn a_vm_boots_again_only_for_a_kernel_or_an_initrd() {
        let boot = Boot {
            slot: 0,
            contract: 1,
            guest: "/nix/store/a-max-guest.json".into(),
            units: true,
            kernel: "/nix/store/k-linux/vmlinux".into(),
            initrd: "/nix/store/i-initrd/initrd".into(),
        };
        let guest = |kernel: &str, initrd: &str| Guest {
            kernel: kernel.into(),
            initrd: initrd.into(),
            cmdline: String::new(),
            contract: 1,
            system: "/nix/store/s-nixos-system".into(),
            registration: "/nix/store/r-closure-info/registration".into(),
        };
        let (kernel, initrd) = ("/nix/store/k-linux/vmlinux", "/nix/store/i-initrd/initrd");
        assert!(!boot.reboots_for(&guest(kernel, initrd)));
        assert!(boot.reboots_for(&guest("/nix/store/n-linux/vmlinux", initrd)));
        assert!(boot.reboots_for(&guest(kernel, "/nix/store/n-initrd/initrd")));
    }
}
