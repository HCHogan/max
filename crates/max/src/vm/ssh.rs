//! SSH to a guest over cloud-hypervisor's hybrid vsock: max connects to the
//! VM's socket, asks for the guest's port 22 with `CONNECT 22`, and what
//! follows the `OK` line is sshd. One connection per VM, one channel per
//! command; each command is a transient unit in the guest, so that it can
//! be stopped by name.

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use color_eyre::eyre::{Result, bail, ensure};
use russh::client::{self, Handle, Msg};
use russh::keys::{PrivateKey, PrivateKeyWithHashAlg, PublicKeyOrCertificate};
use russh::{Channel, ChannelMsg};
use tokio::io::{AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};
use tokio::time::timeout;
use tracing::warn;

/// How long a command stopped by [`Command::stop`] has to end: past the
/// 90 seconds systemd gives a unit from SIGTERM to SIGKILL, so a guest
/// that answers has ended it by then. One that doesn't answer leaves it
/// to the stopper, and the turn goes on.
const STOP_WAIT: Duration = Duration::from_secs(120);
/// The most of a control command's stderr its error keeps.
const STDERR_KEPT: usize = 1024;

pub struct Client;

impl client::Handler for Client {
    type Error = russh::Error;

    // The socket is in a directory only max can reach, so whoever answers
    // on it is the guest. Its host key is made anew at every boot.
    async fn check_server_key(
        &mut self,
        _key: &PublicKeyOrCertificate,
    ) -> Result<bool, Self::Error> {
        Ok(true)
    }
}

pub type Connection = Handle<Client>;

/// Logs in as root with `key`. Fails while the guest is still booting.
pub async fn connect(socket: &Path, key: Arc<PrivateKey>) -> Result<Connection> {
    let mut stream = UnixStream::connect(socket).await?;
    stream.write_all(b"CONNECT 22\n").await?;
    // A byte at a time: sshd's greeting follows the line.
    let mut line = Vec::new();
    loop {
        let byte = stream.read_u8().await?;
        if byte == b'\n' {
            break;
        }
        line.push(byte);
        ensure!(line.len() < 64, "the VM's socket answered something long");
    }
    ensure!(
        line.starts_with(b"OK "),
        "the VM's socket answered {:?}",
        String::from_utf8_lossy(&line)
    );
    let config = Arc::new(client::Config::default());
    let mut connection = client::connect_stream(config, stream, Client).await?;
    let auth = connection
        .authenticate_publickey("root", PrivateKeyWithHashAlg::new(key, None))
        .await?;
    ensure!(auth.success(), "the guest refused max's key");
    Ok(connection)
}

/// A command running in the guest as the unit `unit`. The guest doesn't
/// stop it when the channel closes, so a command dropped before it ends
/// has the VM's stopper stop its unit.
pub struct Command {
    channel: Channel<Msg>,
    unit: Option<String>,
    stops: UnboundedSender<String>,
    status: Option<u32>,
}

impl Command {
    /// Runs `line` in a shell as root, with `input` as its whole input;
    /// `line` starts the unit `unit`.
    pub async fn start(
        connection: &Connection,
        unit: String,
        line: &str,
        input: &[u8],
        stops: UnboundedSender<String>,
    ) -> Result<Self> {
        let channel = connection.channel_open_session().await?;
        let command = Self {
            channel,
            unit: Some(unit),
            stops,
            status: None,
        };
        command.channel.exec(true, line).await?;
        if !input.is_empty() {
            command.channel.data(input).await?;
        }
        command.channel.eof().await?;
        Ok(command)
    }

    /// Runs `line` like [`Command::start`], with its input left open: what
    /// goes into the writer is the command's stdin, and shutting the
    /// writer down ends it.
    pub async fn open(
        connection: &Connection,
        unit: String,
        line: &str,
        stops: UnboundedSender<String>,
    ) -> Result<(Self, Input)> {
        let channel = connection.channel_open_session().await?;
        let command = Self {
            channel,
            unit: Some(unit),
            stops,
            status: None,
        };
        command.channel.exec(true, line).await?;
        // Boxed, as its type would keep the channel borrowed.
        let input: Input = Box::new(command.channel.make_writer());
        Ok((command, input))
    }

    /// Hands each piece of output to `sink` until the channel closes: the
    /// exit status, if the guest sent one. Cancel-safe: what was read
    /// stays read.
    pub async fn wait(&mut self, sink: &mut impl Sink) -> Result<Option<u32>> {
        while let Some(message) = self.channel.wait().await {
            match message {
                ChannelMsg::Data { data } => sink.output(Stream::Out, &data).await?,
                ChannelMsg::ExtendedData { data, .. } => sink.output(Stream::Err, &data).await?,
                ChannelMsg::ExitStatus { exit_status } => self.status = Some(exit_status),
                _ => {}
            }
        }
        // The command is over, however it ended.
        self.unit = None;
        Ok(self.status)
    }

    /// Stops the unit now and waits for the channel to close, at most
    /// `STOP_WAIT`. If that fails, it says so in the log, and the unit
    /// goes to the stopper as the command is dropped: the run that stopped
    /// it still reports what it got.
    pub async fn stop(mut self, connection: &Connection) {
        let stopped = timeout(STOP_WAIT, async {
            if let Some(unit) = &self.unit {
                stop(connection, unit).await?;
            }
            while self.channel.wait().await.is_some() {}
            Result::<()>::Ok(())
        })
        .await;
        let error = match stopped {
            Ok(Ok(())) => {
                self.unit = None;
                return;
            }
            Ok(Err(error)) => format!("{error:#}"),
            Err(_) => format!("still running {} seconds after", STOP_WAIT.as_secs()),
        };
        let unit = self.unit.as_deref().unwrap_or_default();
        warn!(%unit, %error, "couldn't stop a command in a VM; the stopper tries again");
    }
}

impl Drop for Command {
    fn drop(&mut self) {
        if let Some(unit) = self.unit.take() {
            let _ = self.stops.send(unit);
        }
    }
}

/// A command's stdin.
pub type Input = Box<dyn AsyncWrite + Send + Unpin>;

/// Where a command's output goes as it arrives.
pub trait Sink {
    fn output(&mut self, stream: Stream, data: &[u8]) -> impl Future<Output = Result<()>> + Send;
}

/// The command's stdout or stderr.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Stream {
    Out,
    Err,
}

/// Stops each unit sent to it, until every sender is gone.
pub async fn stopper(connection: Arc<Connection>, mut units: UnboundedReceiver<String>) {
    while let Some(unit) = units.recv().await {
        if let Err(error) = stop(&connection, &unit).await {
            warn!(%unit, %error, "couldn't stop a command in a VM");
        }
    }
}

async fn stop(connection: &Connection, unit: &str) -> Result<()> {
    // 5: no such unit, as when it has just ended: --collect unloads it.
    exec(
        connection,
        &format!("systemctl stop {}", quote(unit)),
        &[0, 5],
    )
    .await
}

/// Has the guest write out and drop its page cache and the files it
/// remembers, and gather what is free into blocks large enough for free
/// page reporting to give back.
pub async fn trim(connection: &Connection) -> Result<()> {
    exec(
        connection,
        "sync; echo 3 > /proc/sys/vm/drop_caches; echo 1 > /proc/sys/vm/compact_memory",
        &[0],
    )
    .await
}

/// Runs `line` as root and waits for it to end. Fails unless it exits
/// with a status in `fine`, saying how it did end and what it wrote to
/// stderr, the start of it.
async fn exec(connection: &Connection, line: &str, fine: &[u32]) -> Result<()> {
    let mut channel = connection.channel_open_session().await?;
    channel.exec(true, line).await?;
    channel.eof().await?;
    let mut status = None;
    let mut stderr = Vec::new();
    while let Some(message) = channel.wait().await {
        match message {
            ChannelMsg::ExitStatus { exit_status } => status = Some(exit_status),
            ChannelMsg::ExtendedData { data, .. } => {
                let room = STDERR_KEPT.saturating_sub(stderr.len());
                stderr.extend_from_slice(&data[..data.len().min(room)]);
            }
            _ => {}
        }
    }
    let said = String::from_utf8_lossy(&stderr);
    let said = said.trim();
    match status {
        Some(status) if fine.contains(&status) => Ok(()),
        Some(status) => bail!("`{line}` exited with {status}: {said}"),
        None => bail!("`{line}` ended with no exit status: {said}"),
    }
}

/// `text` as one word for the guest's shell.
pub fn quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quoted_words_stay_one() {
        assert_eq!(quote("ls -l"), "'ls -l'");
        assert_eq!(quote("it's"), r"'it'\''s'");
        assert_eq!(quote(""), "''");
    }
}
