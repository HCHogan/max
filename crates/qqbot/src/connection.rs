//! Runs a gateway [`Session`] over a WebSocket, connecting again until a
//! close code says it's pointless.

use std::future::Future;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tokio::time::{Instant, sleep, sleep_until, timeout};
use tokio_tungstenite::tungstenite::{self, Message};
use tracing::{info, warn};

use crate::api::{self, Client};
use crate::event::Dispatch;
use crate::gateway::{self, After, BadFrame, Fatal, Out, Session};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(20);
const MAX_BACKOFF: Duration = Duration::from_secs(60);

/// What a connection needs from the REST side.
pub trait Connect {
    fn url(&self) -> impl Future<Output = Result<String, api::Error>> + Send;
    fn token(&self) -> impl Future<Output = Result<String, api::Error>> + Send;
}

impl Connect for Client {
    async fn url(&self) -> Result<String, api::Error> {
        self.gateway().await
    }

    async fn token(&self) -> Result<String, api::Error> {
        Client::token(self).await
    }
}

/// Runs the gateway until a close code says reconnecting won't help, or
/// nobody listens to `events` any more. Events arrive in order; after a
/// resume, QQ replays what the dropped connection missed.
pub async fn run(
    connect: &impl Connect,
    intents: u32,
    events: mpsc::Sender<Dispatch>,
) -> Result<(), Fatal> {
    let mut session = Session::new(intents);
    let mut backoff = Backoff::default();
    loop {
        let code = match connection(connect, &mut session, &events, &mut backoff).await {
            Ok(Ended::Unheard) => return Ok(()),
            Ok(Ended::Closed(code)) => code,
            Err(error) => {
                warn!(%error, "QQ gateway connection failed");
                None
            }
        };
        if let After::Stop(fatal) = session.closed(code) {
            return Err(fatal);
        }
        let delay = backoff.next();
        if !delay.is_zero() {
            info!(?code, ?delay, "reconnecting to the QQ gateway");
        }
        sleep(delay).await;
    }
}

enum Ended {
    /// With the server's close code, if it sent one.
    Closed(Option<u16>),
    /// The receiver of events is gone.
    Unheard,
}

#[derive(Debug, thiserror::Error)]
enum Failure {
    #[error(transparent)]
    Api(#[from] api::Error),
    #[error(transparent)]
    Socket(#[from] tungstenite::Error),
    #[error("timed out connecting")]
    Timeout,
    #[error(transparent)]
    Frame(#[from] BadFrame),
}

async fn connection(
    connect: &impl Connect,
    session: &mut Session,
    events: &mpsc::Sender<Dispatch>,
    backoff: &mut Backoff,
) -> Result<Ended, Failure> {
    let url = connect.url().await?;
    let (mut socket, _) = timeout(CONNECT_TIMEOUT, tokio_tungstenite::connect_async(url))
        .await
        .map_err(|_| Failure::Timeout)??;
    loop {
        let outs = tokio::select! {
            frame = socket.next() => match frame {
                None => return Ok(Ended::Closed(None)),
                Some(Err(error)) => return Err(error.into()),
                Some(Ok(Message::Text(text))) => {
                    session.receive(text.as_str(), std::time::Instant::now())?
                }
                Some(Ok(Message::Close(frame))) => {
                    return Ok(Ended::Closed(frame.map(|frame| u16::from(frame.code))));
                }
                Some(Ok(_)) => continue,
            },
            () = until(session.deadline()) => session.tick(std::time::Instant::now()),
        };
        for out in outs {
            let frame = match out {
                Out::Identify => gateway::identify(&connect.token().await?, session.intents()),
                Out::Resume { session_id, seq } => {
                    gateway::resume(&connect.token().await?, &session_id, seq)
                }
                Out::Heartbeat { seq } => gateway::heartbeat(seq),
                Out::Ready { resumed } => {
                    backoff.reset();
                    info!(resumed, "QQ gateway session ready");
                    continue;
                }
                Out::Dispatch(dispatch) => {
                    if events.send(*dispatch).await.is_err() {
                        return Ok(Ended::Unheard);
                    }
                    continue;
                }
                Out::Reconnect => return Ok(Ended::Closed(None)),
            };
            socket.send(Message::text(frame)).await?;
        }
    }
}

async fn until(deadline: Option<std::time::Instant>) {
    match deadline {
        Some(deadline) => sleep_until(Instant::from_std(deadline)).await,
        None => std::future::pending().await,
    }
}

/// No wait right after a connection that worked, then 1, 2, 4… seconds,
/// up to a minute. QQ allows 1500 new sessions a day.
#[derive(Default)]
struct Backoff {
    failures: u32,
}

impl Backoff {
    fn reset(&mut self) {
        self.failures = 0;
    }

    fn next(&mut self) -> Duration {
        let delay = match self.failures {
            0 => Duration::ZERO,
            n => Duration::from_secs(1 << (n - 1).min(6)).min(MAX_BACKOFF),
        };
        self.failures += 1;
        delay
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};
    use tokio::net::{TcpListener, TcpStream};
    use tokio_tungstenite::WebSocketStream;
    use tokio_tungstenite::tungstenite::protocol::CloseFrame;

    use super::*;
    use crate::gateway::GROUP_AND_C2C;

    struct Fake {
        url: String,
    }

    impl Connect for Fake {
        async fn url(&self) -> Result<String, api::Error> {
            Ok(self.url.clone())
        }

        async fn token(&self) -> Result<String, api::Error> {
            Ok("t0".into())
        }
    }

    type Socket = WebSocketStream<TcpStream>;

    async fn listen() -> (TcpListener, Fake) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        (listener, Fake { url })
    }

    async fn accept(listener: &TcpListener) -> Socket {
        let (stream, _) = listener.accept().await.unwrap();
        tokio_tungstenite::accept_async(stream).await.unwrap()
    }

    async fn say(socket: &mut Socket, frame: Value) {
        socket.send(Message::text(frame.to_string())).await.unwrap();
    }

    async fn heard(socket: &mut Socket) -> Value {
        loop {
            if let Message::Text(text) = socket.next().await.unwrap().unwrap() {
                return serde_json::from_str(text.as_str()).unwrap();
            }
        }
    }

    async fn close(socket: &mut Socket, code: u16) {
        let frame = CloseFrame {
            code: code.into(),
            reason: "".into(),
        };
        socket.close(Some(frame)).await.unwrap();
        while let Some(Ok(_)) = socket.next().await {}
    }

    fn hello() -> Value {
        json!({ "op": 10, "d": { "heartbeat_interval": 300 } })
    }

    fn message(seq: u64) -> Value {
        json!({
            "op": 0, "s": seq, "t": "GROUP_MESSAGE_CREATE",
            "d": { "id": format!("m{seq}"), "group_openid": "G0A1", "author": { "member_openid": "M0A1" } }
        })
    }

    #[tokio::test]
    async fn resumes_after_a_drop_and_stops_when_banned() {
        let (listener, fake) = listen().await;
        let (events, mut received) = mpsc::channel(8);
        let server = async {
            let mut socket = accept(&listener).await;
            say(&mut socket, hello()).await;
            let identify = heard(&mut socket).await;
            assert_eq!(
                (identify["op"].as_u64(), identify["d"]["token"].as_str()),
                (Some(2), Some("QQBot t0"))
            );
            let ready = json!({ "op": 0, "s": 1, "t": "READY", "d": { "session_id": "S1" } });
            say(&mut socket, ready).await;
            say(&mut socket, message(2)).await;
            assert_eq!(heard(&mut socket).await, json!({ "op": 1, "d": 2 }));
            say(&mut socket, json!({ "op": 11 })).await;
            close(&mut socket, 4900).await;

            let mut socket = accept(&listener).await;
            say(&mut socket, hello()).await;
            let resume = heard(&mut socket).await;
            assert_eq!(
                resume,
                json!({ "op": 6, "d": { "token": "QQBot t0", "session_id": "S1", "seq": 2 } })
            );
            let resumed = json!({ "op": 0, "s": 3, "t": "RESUMED", "d": "" });
            say(&mut socket, resumed).await;
            say(&mut socket, message(4)).await;
            close(&mut socket, 4915).await;
        };
        let (ran, ()) = tokio::join!(run(&fake, GROUP_AND_C2C, events), server);
        assert_eq!(ran, Err(Fatal::Bot(4915)));
        let mut ids = Vec::new();
        while let Some(dispatch) = received.recv().await {
            ids.push(dispatch.data["id"].as_str().unwrap().to_owned());
        }
        assert_eq!(ids, ["m2", "m4"]);
    }

    #[tokio::test]
    async fn stops_when_nobody_listens() {
        let (listener, fake) = listen().await;
        let (events, received) = mpsc::channel(8);
        drop(received);
        let server = async {
            let mut socket = accept(&listener).await;
            say(&mut socket, hello()).await;
            heard(&mut socket).await;
            say(&mut socket, message(1)).await;
            while let Some(Ok(_)) = socket.next().await {}
        };
        let (ran, ()) = tokio::join!(run(&fake, GROUP_AND_C2C, events), server);
        assert_eq!(ran, Ok(()));
    }

    #[test]
    fn backoff() {
        let mut backoff = Backoff::default();
        let delays: Vec<u64> = (0..9).map(|_| backoff.next().as_secs()).collect();
        assert_eq!(delays, [0, 1, 2, 4, 8, 16, 32, 60, 60]);
        backoff.reset();
        assert_eq!(backoff.next(), Duration::ZERO);
    }
}
