//! SSH to a guest over cloud-hypervisor's hybrid vsock: max connects to the
//! VM's socket, asks for the guest's port 22 with `CONNECT 22`, and what
//! follows the `OK` line is sshd. One connection per VM, one channel per
//! command. A call is a transient unit in the guest, which the guest
//! stops when the call's channel closes: with max's connection, or when
//! max lets go of the call.

use std::path::Path;
use std::pin::pin;
use std::sync::Arc;

use color_eyre::eyre::{Result, bail, ensure};
use russh::client::{self, Handle, Msg};
use russh::keys::{PrivateKey, PrivateKeyWithHashAlg, PublicKeyOrCertificate};
use russh::{Channel, ChannelMsg};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender};

/// The most of a control command's stderr its error keeps.
const STDERR_KEPT: usize = 1024;
/// The most of a control command's answer kept.
const ANSWER_KEPT: usize = 64 << 10;

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

/// The channels of calls max let go of before they ended, for the VM's
/// [`closer`].
pub type Closes = UnboundedSender<Channel<Msg>>;

/// A call running in the guest: `maxx units run`, which stops the call's
/// unit when its input ends. The input stays open for as long as this is
/// held; dropped before the call has ended, as when the turn is killed,
/// its channel goes to the VM's closer, since closing one has to wait.
pub struct Command {
    /// None once the call is over.
    channel: Option<Channel<Msg>>,
    closes: Closes,
    status: Option<u32>,
}

impl Command {
    /// Runs `line` in a shell as root and gives it `input`, with no end
    /// to it: the guest reads as much as `line` says.
    pub async fn start(
        connection: &Connection,
        line: &str,
        input: &[u8],
        closes: Closes,
    ) -> Result<Self> {
        let channel = connection.channel_open_session().await?;
        let command = Self {
            channel: Some(channel),
            closes,
            status: None,
        };
        if let Some(channel) = &command.channel {
            channel.exec(true, line).await?;
            if !input.is_empty() {
                channel.data(input).await?;
            }
        }
        Ok(command)
    }

    /// Hands each piece of output to `sink` until the channel closes, with
    /// the exit status if the guest sent one, or until `until` is done.
    /// `until` is checked only between pieces, so `sink` never has one cut
    /// off halfway; what is still to be read stays for the next wait.
    pub async fn wait_or<T>(
        &mut self,
        sink: &mut impl Sink,
        until: impl Future<Output = T>,
    ) -> Result<Waited<T>> {
        let Some(channel) = &mut self.channel else {
            return Ok(Waited::Exited(self.status));
        };
        let waited = relay(channel, &mut self.status, sink, until).await?;
        if let Waited::Exited(_) = waited {
            // The call is over, however it ended.
            self.channel = None;
        }
        Ok(waited)
    }
}

impl Drop for Command {
    fn drop(&mut self) {
        if let Some(channel) = self.channel.take() {
            let _ = self.closes.send(channel);
        }
    }
}

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

/// Closes each channel sent to it, until every sender is gone: the guest
/// then stops the call whose channel it was. One after another: a close
/// waits for nothing of the guest's, and fails only when the connection
/// is gone, and every call's caller with it.
pub async fn closer(mut channels: UnboundedReceiver<Channel<Msg>>) {
    while let Some(channel) = channels.recv().await {
        let _ = channel.close().await;
    }
}

/// Runs `line` as root and waits for it to end: what it wrote to stdout,
/// the start of it, for a command of max's own that answers in a line or
/// a few. Fails unless it exits with 0, saying how it did end and what it
/// wrote to stderr, the start of it.
pub async fn ask(connection: &Connection, line: &str) -> Result<String> {
    let mut channel = connection.channel_open_session().await?;
    channel.exec(true, line).await?;
    channel.eof().await?;
    let mut status = None;
    let (mut stdout, mut stderr) = (Vec::new(), Vec::new());
    let keep = |kept: &mut Vec<u8>, data: &[u8], most: usize| {
        let room = most.saturating_sub(kept.len());
        kept.extend_from_slice(&data[..data.len().min(room)]);
    };
    while let Some(message) = channel.wait().await {
        match message {
            ChannelMsg::ExitStatus { exit_status } => status = Some(exit_status),
            ChannelMsg::Data { data } => keep(&mut stdout, &data, ANSWER_KEPT),
            ChannelMsg::ExtendedData { data, .. } => keep(&mut stderr, &data, STDERR_KEPT),
            _ => {}
        }
    }
    let said = String::from_utf8_lossy(&stderr);
    let said = said.trim();
    match status {
        Some(0) => Ok(String::from_utf8_lossy(&stdout).into_owned()),
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
    use std::time::Duration;

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
