//! QQ's gateway as Max's intake. Messages go to the conversation table;
//! when Max stops, the session is saved to resume after the restart, so
//! QQ replays what was said in between. See "跨重启 Resume" under "QQ
//! 官方机器人" in docs/rust-rewrite.md.

use chrono::Utc;
use color_eyre::eyre::Result;
use max_core::message::Platform;
use max_db::PgPool;
use max_db::platform;
use qqbot::gateway::{GROUP_AND_C2C, Session};
use qqbot::{Dispatch, Event};
use tokio::sync::mpsc::{self, UnboundedSender};
use tokio_util::sync::CancellationToken;
use tracing::{debug, info, warn};

use super::inbound::inbound;
use crate::inbound::Inbound;

/// Until `stop`, or until QQ closes the gateway for good.
pub async fn listen(
    client: &qqbot::Client,
    pool: &PgPool,
    table: &UnboundedSender<Inbound>,
    stop: CancellationToken,
) -> Result<()> {
    let mut conn = pool.acquire().await?;
    let saved = platform::gateway_session(&mut conn, Platform::Qq).await?;
    drop(conn);
    let mut session = match saved {
        Some((session_id, seq)) => {
            info!(
                seq,
                "resuming the QQ gateway session saved at the last stop"
            );
            Session::resuming(GROUP_AND_C2C, session_id, seq)
        }
        None => Session::new(GROUP_AND_C2C),
    };
    let (events, mut received) = mpsc::unbounded_channel();
    let ended = {
        let gateway = qqbot::run(client, &mut session, events);
        tokio::pin!(gateway);
        loop {
            tokio::select! {
                ended = &mut gateway => break Some(ended),
                Some(dispatch) = received.recv() => forward(&dispatch, table),
                () = stop.cancelled() => break None,
            }
        }
    };
    // What the dropped connection received is in the channel still.
    while let Ok(dispatch) = received.try_recv() {
        forward(&dispatch, table);
    }
    if let Some((session_id, seq)) = session.resumable() {
        let mut conn = pool.acquire().await?;
        platform::save_gateway_session(&mut conn, Platform::Qq, session_id, seq, Utc::now())
            .await?;
        info!(seq, "saved the QQ gateway session to resume");
    }
    match ended {
        Some(Err(fatal)) => Err(fatal.into()),
        Some(Ok(())) | None => Ok(()),
    }
}

fn forward(dispatch: &Dispatch, table: &UnboundedSender<Inbound>) {
    if let Some(inbound) = inbound(dispatch, Utc::now()) {
        let _ = table.send(inbound);
        return;
    }
    match &dispatch.event {
        Event::Malformed(error) => {
            warn!(kind = dispatch.kind, %error, "a QQ event that doesn't parse");
        }
        Event::Other => debug!(kind = dispatch.kind, "a QQ event Max doesn't act on"),
        _ => {
            info!(kind = dispatch.kind, data = %dispatch.data, "a QQ event Max doesn't act on yet")
        }
    }
}
