//! wxdesk as Max's intake: messages go to the conversation table. The
//! connection is kept until max stops, connected again 5 seconds after it
//! drops; what is said while it is down waits in wxdesk. See "Connection"
//! in docs/design/wechat.md.

use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use chrono::Utc;
use color_eyre::eyre::Result;
use max_core::message::MediaRef;
use tokio::sync::mpsc::UnboundedSender;
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};
use wxdesk_proto::{FromDriver, Message};

use super::inbound::inbound;
use super::link::Link;
use max::inbound::Inbound;
use max::media::store::Store;

const AGAIN: Duration = Duration::from_secs(5);

/// Until `stop`.
///
/// # Errors
///
/// Never: WeChat doesn't shut Max out for good, and wxdesk is tried again
/// until it answers.
pub async fn listen(
    link: &Link,
    store: Option<&Store>,
    me: &str,
    table: &UnboundedSender<Inbound>,
    stop: CancellationToken,
) -> Result<()> {
    loop {
        tokio::select! {
            () = connection(link, store, me, table) => {}
            () = stop.cancelled() => break,
        }
        link.lost().await;
        tokio::select! {
            () = tokio::time::sleep(AGAIN) => {}
            () = stop.cancelled() => break,
        }
    }
    link.lost().await;
    Ok(())
}

/// One connection to wxdesk, until it drops.
async fn connection(
    link: &Link,
    store: Option<&Store>,
    me: &str,
    table: &UnboundedSender<Inbound>,
) {
    let (mut events, commands) = match wxdesk_proto::connect(&link.address, Some(&link.token)).await
    {
        Ok(connected) => connected,
        Err(error) => {
            warn!(%error, "couldn't reach WeChat's driver");
            return;
        }
    };
    let mut commands = Some(commands);
    let mut run = None;
    loop {
        let event = match events.next().await {
            Ok(Some(event)) => event,
            Ok(None) => {
                warn!("WeChat's driver hung up");
                return;
            }
            Err(error) => {
                warn!(%error, "WeChat's driver said something that isn't its protocol");
                return;
            }
        };
        match event {
            FromDriver::Hello {
                run: this,
                me: theirs,
                logged_in,
                ..
            } => {
                info!(logged_in, "connected to WeChat's driver");
                if theirs.as_deref().is_some_and(|theirs| theirs != me) {
                    warn!(theirs, me, "WeChat's driver knows Max by another name");
                }
                if !logged_in {
                    warn!("WeChat isn't logged in");
                }
                run = Some(this);
                // Commands go once the connection is taken.
                if let Some(commands) = commands.take() {
                    link.connected(commands).await;
                }
            }
            FromDriver::State { logged_in } => {
                if logged_in {
                    info!("WeChat is logged in again");
                } else {
                    warn!("WeChat logged out: it needs logging in through VNC");
                }
            }
            FromDriver::Message(message) => {
                let Some(run) = run else { continue };
                let media = stored(store, &message).await;
                if let Some(inbound) = inbound(&message, run, me, media, Utc::now()) {
                    let _ = table.send(inbound);
                }
            }
            FromDriver::Done { id, error } => link.answered(id, error),
        }
    }
}

/// The picture or file `message` carries, put in the store.
async fn stored(store: Option<&Store>, message: &Message) -> Option<MediaRef> {
    let attachment = message.attachment.as_ref()?;
    let store = store?;
    let bytes = match STANDARD.decode(&attachment.data) {
        Ok(bytes) => bytes,
        Err(error) => {
            warn!(seq = message.seq, %error, "an attachment that isn't base64");
            return None;
        }
    };
    match store.put(bytes).await {
        Ok(sha256) => Some(MediaRef::Blob(sha256)),
        Err(error) => {
            warn!(seq = message.seq, %error, "couldn't store an attachment");
            None
        }
    }
}
