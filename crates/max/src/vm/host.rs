//! The VM service's port in each group's VM, 7778 on the hybrid vsock. A
//! program there sends one line of JSON, `{"wake": "…"}` from max-wake or
//! `{"units": 2}` from max-units, and gets one back, `{"ok": true, "said":
//! "…"}`. Which group it comes from is the VM's own socket's to say, so
//! there is no token. See "常驻程序" in docs/rust-rewrite.md.

use std::time::Duration;

use max_core::ids::ConversationId;
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::mpsc::UnboundedSender;
use tokio::sync::oneshot;
use tokio::time::timeout;
use tokio_util::sync::CancellationToken;
use tracing::{debug, warn};

use super::{Internal, Signal};

/// The longest line a program may send; a wake's text is cut far shorter.
const LONGEST: u64 = 64 << 10;
/// How long a program has to send its line, and Max to answer it.
const WAIT: Duration = Duration::from_secs(10);

#[derive(Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case", deny_unknown_fields)]
enum Asked {
    Wake(String),
    Units(u32),
}

#[derive(Debug, PartialEq, Eq, Serialize)]
struct Answer {
    ok: bool,
    said: String,
}

impl Answer {
    fn refused(said: impl Into<String>) -> Self {
        Self {
            ok: false,
            said: said.into(),
        }
    }
}

/// Until `stop`: one call at a time. They are short, and only the
/// group's own programs could hold the next one up, for `WAIT` at most.
pub async fn serve(
    listener: UnixListener,
    conversation: ConversationId,
    signals: UnboundedSender<Signal>,
    service: UnboundedSender<Internal>,
    stop: CancellationToken,
) {
    loop {
        let stream = tokio::select! {
            () = stop.cancelled() => return,
            accepted = listener.accept() => match accepted {
                Ok((stream, _)) => stream,
                Err(error) => {
                    warn!(%conversation, %error, "the VM's port to the host stopped");
                    return;
                }
            },
        };
        if let Err(error) = call(stream, conversation, &signals, &service).await {
            debug!(%conversation, %error, "a program's call to the host failed");
        }
    }
}

async fn call(
    stream: UnixStream,
    conversation: ConversationId,
    signals: &UnboundedSender<Signal>,
    service: &UnboundedSender<Internal>,
) -> std::io::Result<()> {
    let (read, mut write) = stream.into_split();
    let mut line = String::new();
    let read = timeout(
        WAIT,
        BufReader::new(read.take(LONGEST)).read_line(&mut line),
    )
    .await;
    let answer = match read {
        Err(_) => Answer::refused("10 秒内没收到请求"),
        Ok(read) => match parse(read?, &line) {
            Ok(asked) => answered(asked, conversation, signals, service).await,
            Err(answer) => answer,
        },
    };
    let mut text = serde_json::to_string(&answer)?;
    text.push('\n');
    write.write_all(text.as_bytes()).await?;
    write.shutdown().await
}

/// The request in a line of `length` bytes, or why it isn't one.
fn parse(length: usize, line: &str) -> Result<Asked, Answer> {
    if length as u64 >= LONGEST {
        return Err(Answer::refused(format!(
            "请求太长了，最多 {} KiB",
            LONGEST >> 10
        )));
    }
    serde_json::from_str(line.trim())
        .map_err(|error| Answer::refused(format!("看不懂的请求：{error}")))
}

async fn answered(
    asked: Asked,
    conversation: ConversationId,
    signals: &UnboundedSender<Signal>,
    service: &UnboundedSender<Internal>,
) -> Answer {
    let (reply, said) = oneshot::channel();
    let sent = match asked {
        Asked::Wake(text) => signals
            .send(Signal::Wake {
                conversation,
                text,
                reply,
            })
            .is_ok(),
        Asked::Units(count) => service
            .send(Internal::Units {
                conversation,
                count,
                reply,
            })
            .is_ok(),
    };
    if !sent {
        return Answer::refused("Max 正在停");
    }
    match timeout(WAIT, said).await {
        Ok(Ok(Ok(said))) => Answer { ok: true, said },
        Ok(Ok(Err(said))) => Answer::refused(said),
        _ => Answer::refused("没等到 Max 的回答"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scope::Scope;

    #[test]
    fn a_line_is_a_wake_or_the_units() {
        assert_eq!(
            parse(30, "{\"wake\":\"CI 跑完了\"}\n"),
            Ok(Asked::Wake("CI 跑完了".into()))
        );
        assert_eq!(parse(12, "{\"units\":2}"), Ok(Asked::Units(2)));
        let refused = parse(10, "{\"sleep\":1}").unwrap_err();
        assert!(
            !refused.ok && refused.said.starts_with("看不懂的请求"),
            "{refused:?}"
        );
        let long = parse(LONGEST as usize, "").unwrap_err();
        assert_eq!(long.said, "请求太长了，最多 64 KiB");
    }

    #[tokio::test]
    async fn a_wake_is_answered_by_whoever_takes_the_signal() {
        // Short: a socket's path has a limit.
        let dir = std::env::temp_dir().join(format!("max-host-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("s");
        let _ = std::fs::remove_file(&path);
        let listener = UnixListener::bind(&path).unwrap();
        let (signals, mut taken) = tokio::sync::mpsc::unbounded_channel();
        let (service, _units) = tokio::sync::mpsc::unbounded_channel();
        let mut scope = Scope::new();
        scope.spawn(move |stop| serve(listener, ConversationId(7), signals, service, stop));
        scope.spawn(move |_| async move {
            while let Some(signal) = taken.recv().await {
                if let Signal::Wake {
                    conversation,
                    text,
                    reply,
                } = signal
                {
                    let _ = reply.send(Ok(format!("会话 {conversation}：{text}")));
                }
            }
        });
        let mut stream = UnixStream::connect(&path).await.unwrap();
        stream
            .write_all("{\"wake\":\"到点了\"}\n".as_bytes())
            .await
            .unwrap();
        let mut answer = String::new();
        stream.read_to_string(&mut answer).await.unwrap();
        assert_eq!(answer, "{\"ok\":true,\"said\":\"会话 7：到点了\"}\n");
        scope.close(Duration::from_secs(1)).await;
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
