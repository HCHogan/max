//! SSH to a guest over cloud-hypervisor's hybrid vsock: max connects to the
//! VM's socket, asks for the guest's port 22 with `CONNECT 22`, and what
//! follows the `OK` line is sshd. One connection per VM, one channel per
//! command; each command is a transient unit in the guest, so that it can
//! be stopped by name.

use std::convert::Infallible;
use std::path::Path;
use std::pin::pin;
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
    /// exit status, if the guest sent one. Dropped, it may leave `sink` with
    /// a piece half handed over; to stop waiting, use [`Self::wait_or`].
    pub async fn wait(&mut self, sink: &mut impl Sink) -> Result<Option<u32>> {
        match self
            .wait_or(sink, std::future::pending::<Infallible>())
            .await?
        {
            Waited::Exited(status) => Ok(status),
            Waited::Interrupted(never) => match never {},
        }
    }

    /// Hands each piece of output to `sink`, as [`Self::wait`] does, until
    /// the channel closes or `until` is done. `until` is checked only
    /// between pieces, so `sink` never has one cut off halfway; what is
    /// still to be read stays for the next wait.
    pub async fn wait_or<T>(
        &mut self,
        sink: &mut impl Sink,
        until: impl Future<Output = T>,
    ) -> Result<Waited<T>> {
        let waited = relay(&mut self.channel, &mut self.status, sink, until).await?;
        if let Waited::Exited(_) = waited {
            // The command is over, however it ended.
            self.unit = None;
        }
        Ok(waited)
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

/// Where a command's messages come from: its channel, or a test's.
trait Messages {
    /// The next one; None once there are no more. Cancel-safe.
    fn next(&mut self) -> impl Future<Output = Option<ChannelMsg>> + Send;
}

impl Messages for Channel<Msg> {
    fn next(&mut self) -> impl Future<Output = Option<ChannelMsg>> + Send {
        self.wait()
    }
}

/// [`Command::wait_or`]'s work: hands the output in `messages` to `sink`
/// until there is no more, or `until` is done, between pieces; the exit
/// status goes to `status` as it comes.
async fn relay<T>(
    messages: &mut impl Messages,
    status: &mut Option<u32>,
    sink: &mut impl Sink,
    until: impl Future<Output = T>,
) -> Result<Waited<T>> {
    let mut until = pin!(until);
    loop {
        // Receiving is cancel-safe; handing over isn't, so it is done
        // outside the select. `until` first: once it is done, no more
        // output is handed over, however much is waiting.
        let message = tokio::select! {
            biased;
            interrupted = &mut until => return Ok(Waited::Interrupted(interrupted)),
            message = messages.next() => message,
        };
        match message {
            Some(ChannelMsg::Data { data }) => sink.output(Stream::Out, &data).await?,
            Some(ChannelMsg::ExtendedData { data, .. }) => sink.output(Stream::Err, &data).await?,
            Some(ChannelMsg::ExitStatus { exit_status }) => *status = Some(exit_status),
            Some(_) => {}
            None => return Ok(Waited::Exited(*status)),
        }
    }
}

/// How [`Command::wait_or`] ended.
#[derive(Debug, PartialEq, Eq)]
pub enum Waited<T> {
    /// The command is over: its exit status, if the guest sent one.
    Exited(Option<u32>),
    /// What it waited on besides came first; the command may still run.
    Interrupted(T),
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
    use tokio::sync::mpsc::unbounded_channel;
    use tokio::time::{Instant, sleep, sleep_until};

    use super::*;

    impl Messages for UnboundedReceiver<ChannelMsg> {
        fn next(&mut self) -> impl Future<Output = Option<ChannelMsg>> + Send {
            self.recv()
        }
    }

    /// Takes a second over each piece, and keeps them.
    #[derive(Default)]
    struct Slow(Vec<(Stream, Vec<u8>)>);

    impl Sink for Slow {
        async fn output(&mut self, stream: Stream, data: &[u8]) -> Result<()> {
            sleep(Duration::from_secs(1)).await;
            self.0.push((stream, data.to_vec()));
            Ok(())
        }
    }

    /// What stops a wait does so between pieces of output, never in the
    /// middle of one, and leaves the rest for the next wait.
    #[tokio::test(start_paused = true)]
    async fn a_wait_stops_between_pieces() {
        let (messages, mut received) = unbounded_channel();
        for data in [b"one", b"two"] {
            let data = data.to_vec().into();
            messages.send(ChannelMsg::Data { data }).unwrap();
        }
        let (mut status, mut sink) = (None, Slow::default());
        // Due halfway through the first piece.
        let half = Instant::now() + Duration::from_millis(500);
        let waited = relay(&mut received, &mut status, &mut sink, sleep_until(half)).await;
        assert_eq!(waited.unwrap(), Waited::Interrupted(()));
        assert_eq!(sink.0, [(Stream::Out, b"one".to_vec())]);

        let data = b"oops".to_vec().into();
        messages
            .send(ChannelMsg::ExtendedData { data, ext: 1 })
            .unwrap();
        let exit_status = 3;
        messages
            .send(ChannelMsg::ExitStatus { exit_status })
            .unwrap();
        drop(messages);
        let waited = relay(
            &mut received,
            &mut status,
            &mut sink,
            std::future::pending::<()>(),
        );
        assert_eq!(waited.await.unwrap(), Waited::Exited(Some(3)));
        let pieces: Vec<_> = sink
            .0
            .iter()
            .map(|(stream, data)| (*stream, &data[..]))
            .collect();
        assert_eq!(
            pieces,
            [
                (Stream::Out, &b"one"[..]),
                (Stream::Out, b"two"),
                (Stream::Err, b"oops")
            ]
        );
    }

    #[test]
    fn quoted_words_stay_one() {
        assert_eq!(quote("ls -l"), "'ls -l'");
        assert_eq!(quote("it's"), r"'it'\''s'");
        assert_eq!(quote(""), "''");
    }
}
