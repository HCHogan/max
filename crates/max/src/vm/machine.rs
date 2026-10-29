//! Starting a VM: its directory and disk, two virtiofsd and a
//! cloud-hypervisor as max's own children, then SSH once the guest
//! answers. The command lines are the ones checked on tank; see "VM 进程".

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use color_eyre::eyre::{Result, WrapErr, bail, eyre};
use russh::keys::{Algorithm, PrivateKey};
use serde::Deserialize;
use tokio::fs;
use tokio::net::UnixListener;
use tokio::process::{Child, Command};
use tokio::time::{Instant, sleep};

use super::ssh::{self, Connection};
use crate::config::{self, Slot};

/// The hybrid vsock port the guest reaches the MCP service on.
const MCP_PORT: u32 = 7777;

/// How long the guest has to boot and let max in.
pub const BOOT: Duration = Duration::from_secs(60);
/// Between tries to log in while the guest boots.
const RETRY: Duration = Duration::from_millis(100);

/// What the flake's `guest` package says to boot.
#[derive(Debug, Deserialize)]
pub struct Guest {
    pub kernel: PathBuf,
    pub initrd: PathBuf,
    pub cmdline: String,
}

impl Guest {
    pub fn load(path: &Path) -> Result<Self> {
        let text = std::fs::read_to_string(path)
            .wrap_err_with(|| format!("reading the guest {}", path.display()))?;
        Ok(serde_json::from_str(&text)?)
    }
}

/// A running VM's processes, killed when it is dropped. virtiofsd's
/// sandboxed child dies with it.
pub struct Machine {
    hypervisor: Child,
    _store: Child,
    _work: Child,
}

impl Machine {
    /// cloud-hypervisor is gone: it crashed, or the guest powered off.
    pub fn exited(&mut self) -> bool {
        !matches!(self.hypervisor.try_wait(), Ok(None))
    }
}

/// A VM that has booted: its processes, the SSH connection, and where its
/// programs call the MCP service.
pub struct Booted {
    pub machine: Machine,
    pub connection: Connection,
    pub mcp: UnixListener,
}

/// Boots the VM whose files are in `dir`, on `slot`'s tap.
pub async fn boot(config: &config::Vm, guest: &Guest, dir: &Path, slot: &Slot) -> Result<Booted> {
    let work = dir.join("work");
    fs::create_dir_all(&work).await?;
    disk(config, &dir.join("nix.img")).await?;
    let mcp_socket = format!("notify.vsock_{MCP_PORT}");
    for stale in ["store.sock", "work.sock", "notify.vsock", &mcp_socket] {
        let _ = fs::remove_file(dir.join(stale)).await;
    }
    // cloud-hypervisor connects here when the guest connects to the host's
    // port, so it listens before the guest boots.
    let mcp = UnixListener::bind(dir.join(&mcp_socket))?;

    // The guest's root is max on the host; its other users are squashed
    // to max.
    let (uid, gid) = ids(dir).await?;
    let map = [
        format!("--translate-uid=map:0:{uid}:1"),
        format!("--translate-gid=map:0:{gid}:1"),
        format!("--translate-uid=squash-guest:1:{uid}:4294967294"),
        format!("--translate-gid=squash-guest:1:{gid}:4294967294"),
    ];
    let store = spawn(
        Command::new(&config.virtiofsd)
            .arg(socket_arg(dir, "store.sock"))
            .args(["--shared-dir=/nix/store", "--readonly", "--cache=always"]),
        &dir.join("virtiofsd-store.log"),
    )?;
    let work_fs = spawn(
        Command::new(&config.virtiofsd)
            .arg(socket_arg(dir, "work.sock"))
            .arg(format!("--shared-dir={}", work.display()))
            .args(&map),
        &dir.join("virtiofsd-work.log"),
    )?;
    for socket in ["store.sock", "work.sock"] {
        appears(&dir.join(socket)).await?;
    }

    let key = Arc::new(PrivateKey::random(&mut rand::rng(), Algorithm::Ed25519)?);
    let public = key.public_key().to_openssh()?;
    let blob = public
        .split(' ')
        .nth(1)
        .ok_or_else(|| eyre!("an OpenSSH public key without its blob"))?;
    let cmdline = format!(
        "{} max.ip={} max.gateway={} max.dns={} max.key={blob}",
        guest.cmdline,
        slot.address,
        slot.gateway,
        config.dns.join(","),
    );
    let path = |name: &str| dir.join(name).display().to_string();
    let hypervisor = spawn(
        Command::new(&config.cloud_hypervisor)
            .args(["--cpus", &format!("boot={}", config.cpus)])
            .args([
                "--memory",
                &format!("size={}M,shared=on", config.memory_mib),
            ])
            .arg("--kernel")
            .arg(&guest.kernel)
            .arg("--initramfs")
            .arg(&guest.initrd)
            .args(["--cmdline", &cmdline])
            .args(["--seccomp", "true", "--landlock", "--landlock-rules"])
            // The tap's flags, and the VM's own sockets.
            .arg("path=/sys/devices/virtual/net,access=r")
            .arg(format!("path={},access=rw", dir.display()))
            .args([
                "--console",
                "off",
                "--serial",
                &format!("file={}", path("serial.log")),
            ])
            .args(["--vsock", &format!("cid=3,socket={}", path("notify.vsock"))])
            .args([
                "--balloon",
                "deflate_on_oom=on,free_page_reporting=on,size=0M",
            ])
            .args([
                "--disk",
                &format!("path={},image_type=raw", path("nix.img")),
            ])
            .args(["--fs", &format!("socket={},tag=store", path("store.sock"))])
            .arg(format!("socket={},tag=work", path("work.sock")))
            .args([
                "--net",
                &format!(
                    "mac=02:00:00:00:00:01,num_queues={},tap={}",
                    2 * config.cpus,
                    slot.tap
                ),
            ]),
        &dir.join("cloud-hypervisor.log"),
    )?;
    let mut machine = Machine {
        hypervisor,
        _store: store,
        _work: work_fs,
    };

    let socket = dir.join("notify.vsock");
    let deadline = Instant::now() + BOOT;
    loop {
        match ssh::connect(&socket, Arc::clone(&key)).await {
            Ok(connection) => {
                return Ok(Booted {
                    machine,
                    connection,
                    mcp,
                });
            }
            Err(error) => {
                if machine.exited() {
                    let log = fs::read_to_string(dir.join("cloud-hypervisor.log")).await;
                    bail!(
                        "cloud-hypervisor exited: {}",
                        log.unwrap_or_default().trim()
                    );
                }
                if Instant::now() >= deadline {
                    return Err(
                        error.wrap_err(format!("the guest didn't let max in within {BOOT:?}"))
                    );
                }
                sleep(RETRY).await;
            }
        }
    }
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

/// The owner of the VM's directory: max.
async fn ids(dir: &Path) -> Result<(u32, u32)> {
    use std::os::unix::fs::MetadataExt;
    let metadata = fs::metadata(dir).await?;
    Ok((metadata.uid(), metadata.gid()))
}

fn socket_arg(dir: &Path, name: &str) -> String {
    format!("--socket-path={}", dir.join(name).display())
}

/// Starts a child that is killed when it is dropped, its output to `log`.
fn spawn(command: &mut Command, log: &Path) -> Result<Child> {
    let out = std::fs::File::create(log)?;
    let program = command.as_std().get_program().to_owned();
    command
        .stdin(Stdio::null())
        .stdout(out.try_clone()?)
        .stderr(out)
        .kill_on_drop(true)
        .spawn()
        .wrap_err_with(|| format!("starting {}", program.display()))
}

/// Waits for virtiofsd's socket.
async fn appears(socket: &Path) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(5);
    while fs::metadata(socket).await.is_err() {
        if Instant::now() >= deadline {
            bail!("virtiofsd didn't make {}", socket.display());
        }
        sleep(Duration::from_millis(20)).await;
    }
    Ok(())
}
