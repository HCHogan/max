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
use tokio::net::UnixListener;
use tokio::process::Command;
use tokio::time::{Instant, sleep};
use tracing::warn;

use super::ssh::{self, Connection};
use crate::config::{self, Slot};

/// The hybrid vsock port the guest reaches the MCP service on, and the
/// VM service's own routes; see `host`.
const MCP_PORT: u32 = 7777;

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

/// What the flake's `guest` package says to boot.
#[derive(Debug, Deserialize)]
pub struct Guest {
    pub kernel: PathBuf,
    pub initrd: PathBuf,
    pub cmdline: String,
    /// The contract it keeps with a host: nix/contract.nix.
    pub contract: u32,
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
    /// What it booted: the configuration's `guest` then.
    pub guest: PathBuf,
    /// Whether with Max's units.
    pub units: bool,
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
}

/// A conversation's VM: its unit, and what goes with it on the host.
#[derive(Clone, Debug)]
pub struct Machine {
    systemctl: PathBuf,
    unit: String,
    /// The VM's files.
    pub dir: PathBuf,
    /// The link that keeps what it booted from the garbage collector.
    root: Option<PathBuf>,
}

impl Machine {
    pub fn of(config: &config::Vm, conversation: ConversationId) -> Self {
        let instance = format!("{}{}", config.instances, conversation.0);
        Self {
            systemctl: config.systemctl.clone(),
            unit: format!("{}{instance}.service", config.unit),
            dir: config.dir.join(conversation.0.to_string()),
            root: config.roots.as_ref().map(|roots| roots.join(instance)),
        }
    }

    /// Has systemd stop it, without waiting for that: the VM ends, and
    /// what it booted is the collector's again.
    pub fn stop(&self) {
        let stopping = self
            .systemctl(&["stop", "--no-block"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
        if let Err(error) = stopping {
            warn!(unit = %self.unit, %error, "couldn't ask systemd to stop a VM");
        }
        if let Some(root) = &self.root {
            let _ = std::fs::remove_file(root);
        }
    }

    /// Stops it, and waits until it has stopped.
    pub async fn stopped(&self) {
        if let Err(error) = self.run(&["stop"]).await {
            warn!(unit = %self.unit, error = format!("{error:#}"), "couldn't stop a VM");
        }
        if let Some(root) = &self.root {
            let _ = fs::remove_file(root).await;
        }
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
pub async fn running(config: &config::Vm) -> Vec<ConversationId> {
    let pattern = format!("{}{}*", config.unit, config.instances);
    let listed = Command::new(&config.systemctl)
        .args(["list-units", "--type=service", "--state=active"])
        .args(["--no-legend", "--plain", &pattern])
        .stdin(Stdio::null())
        .output()
        .await;
    let listed = match listed {
        Ok(listed) if listed.status.success() => listed.stdout,
        Ok(listed) => {
            let said = String::from_utf8_lossy(&listed.stderr);
            warn!(error = said.trim(), "couldn't list the VMs that run");
            return Vec::new();
        }
        Err(error) => {
            warn!(%error, "couldn't list the VMs that run");
            return Vec::new();
        }
    };
    let prefix = format!("{}{}", config.unit, config.instances);
    String::from_utf8_lossy(&listed)
        .lines()
        .filter_map(|line| conversation(line.split_whitespace().next()?, &prefix))
        .collect()
}

/// The conversation whose VM the unit `name` is, if it is one of those
/// whose names begin with `prefix`: another's, such as vm-check's beside
/// max's, isn't.
fn conversation(name: &str, prefix: &str) -> Option<ConversationId> {
    let instance = name.strip_prefix(prefix)?.strip_suffix(".service")?;
    instance.parse().ok().map(ConversationId)
}

/// A VM max can use: its unit, the SSH connection, and where its programs
/// call the MCP service.
pub struct Booted {
    pub machine: Machine,
    pub connection: Connection,
    pub mcp: UnixListener,
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
    // cloud-hypervisor connects here when the guest connects to the host's
    // port, so it listens before the guest boots.
    let mcp = listen(dir).await?;

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
    let dns: Vec<&str> = operations
        .into_iter()
        .flat_map(|ops| &ops.dns)
        .chain(&config.dns)
        .map(String::as_str)
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
    };
    fs::write(dir.join(RECORD), serde_json::to_vec(&record)?).await?;
    if let Some(root) = &machine.root {
        // What the guest reads from the host's store, for as long as it
        // runs.
        let _ = fs::remove_file(root).await;
        if let Err(error) = fs::symlink(&config.guest, root).await {
            warn!(root = %root.display(), %error, "couldn't root a VM's image");
        }
    }
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
                    mcp,
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

/// Attaches to `conversation`'s VM, which runs: binds the socket its
/// programs reach the MCP service on again, and logs in with the key its
/// boot left.
pub async fn attach(config: &config::Vm, conversation: ConversationId) -> Result<Booted> {
    let machine = Machine::of(config, conversation);
    let dir = &machine.dir;
    let key = fs::read(dir.join(KEY)).await.wrap_err("reading its key")?;
    let key = Arc::new(PrivateKey::from_openssh(key)?);
    let mcp = listen(dir).await?;
    let socket = dir.join("notify.vsock");
    let deadline = Instant::now() + ATTACH;
    loop {
        match ssh::connect(&socket, Arc::clone(&key)).await {
            Ok(connection) => {
                return Ok(Booted {
                    machine,
                    connection,
                    mcp,
                });
            }
            Err(error) if Instant::now() >= deadline => {
                return Err(
                    error.wrap_err(format!("the guest didn't let max in within {ATTACH:?}"))
                );
            }
            Err(_) => sleep(RETRY).await,
        }
    }
}

/// Listens where cloud-hypervisor connects when the guest connects to the
/// host's MCP port: `notify.vsock_7777` in the VM's directory. Only that
/// socket is replaced: the VM's own, which it made, are its to keep while
/// it runs (on 2026-11-03 a second start replaced a running VM's).
async fn listen(dir: &Path) -> Result<UnixListener> {
    let socket = dir.join(format!("notify.vsock_{MCP_PORT}"));
    let _ = fs::remove_file(&socket).await;
    UnixListener::bind(&socket).wrap_err_with(|| format!("listening at {}", socket.display()))
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
    fn a_unit_names_its_conversation_if_it_is_one_of_ours() {
        let seven = Some(ConversationId(7));
        assert_eq!(conversation("maxx-vm@7.service", "maxx-vm@"), seven);
        assert_eq!(conversation("maxx-vm@check-0.service", "maxx-vm@"), None);
        assert_eq!(
            conversation("maxx-vm@check-0.service", "maxx-vm@check-"),
            Some(ConversationId(0))
        );
        assert_eq!(conversation("maxx-vm@7.service", "maxx-vm@check-"), None);
        assert_eq!(conversation("maxx-vm@7.socket", "maxx-vm@"), None);
    }

    #[test]
    fn the_units_environment_keeps_a_command_line_whole() {
        let written = environment(&[
            ("TAP", "maxx-vm3".to_owned()),
            (
                "CMDLINE",
                r#"console=ttyS0 max.git=A "B" C\D,a@b.c"#.to_owned(),
            ),
        ]);
        assert_eq!(
            written,
            "TAP=\"maxx-vm3\"\nCMDLINE=\"console=ttyS0 max.git=A \\\"B\\\" C\\\\D,a@b.c\"\n"
        );
    }

    #[test]
    fn a_boot_is_read_as_it_was_written() {
        let boot = Boot {
            slot: 3,
            contract: 1,
            guest: "/nix/store/x-max-guest.json".into(),
            units: true,
        };
        let written = serde_json::to_string(&boot).unwrap();
        assert_eq!(serde_json::from_str::<Boot>(&written).unwrap(), boot);
    }
}
