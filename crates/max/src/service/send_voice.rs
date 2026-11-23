//! `send_voice`: an audio file a program made in /work, sent to its chat
//! as a voice message. See "Sending voice messages" in
//! docs/design/media.md.

use chrono::Utc;
use max_core::limits::SENT_VOICE_BYTES;
use max_core::message::{Draft, DraftNode};
use max_db::media::{self, Blob};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use tokio::task::spawn_blocking;

use super::send_file::keep;
use super::tool::Tool;
use super::work::{beneath_work, open};
use super::{Context, Failure, internal};

pub(super) struct SendVoice;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub(super) struct Args {
    #[schemars(
        length(min = 1),
        description = "a path under /work; a relative one is from /work"
    )]
    path: String,
}

#[derive(Serialize, JsonSchema)]
pub(super) struct Sent {
    handle: String,
}

impl Tool for SendVoice {
    const NAME: &'static str = "send_voice";
    const DESCRIPTION: &'static str =
        "Sends an audio file under /work to this chat as a voice message.";

    type Args = Args;
    type Output = Sent;

    fn guide() -> String {
        format!(
            "Sends an audio file under /work to this chat as a voice message, which shows as a bar people tap to hear. MP3, WAV or Ogg; ffmpeg converts anything else. At most {} MiB, and not empty; no symlink on the path.\n  \
            It returns once the audio is stored and queued, and handle is its handle; the upload goes on after that. The records keep the audio, as [audio#…], and nothing of what it says. If it doesn't go out, as when the platform can't make the audio out, its row in the records is marked （没发出去）.",
            SENT_VOICE_BYTES >> 20
        )
    }

    async fn run(context: &Context, args: Args) -> Result<Sent, Failure> {
        send(context, args).await
    }
}

async fn send(context: &Context, Args { path }: Args) -> Result<Sent, Failure> {
    let (Some(work), Some(store), Some(poster)) = (
        &context.work,
        &context.services.store,
        context.poster.as_ref(),
    ) else {
        return Err(Failure::new(
            "unavailable",
            "voice messages can't be sent from here",
        ));
    };
    let relative = beneath_work(&path)?;
    let work = work.clone();
    let opened = relative.clone();
    let (file, _) = spawn_blocking(move || open(&work, &opened, SENT_VOICE_BYTES))
        .await
        .map_err(|_| internal())??;
    let (sha256, size) = keep(store, file, &relative, SENT_VOICE_BYTES).await?;
    let blob = Blob {
        sha256: sha256.clone(),
        mime: None,
        size,
        width: None,
        height: None,
        model_sha256: None,
    };
    let mut conn = context.services.pool.acquire().await?;
    media::remember(&mut conn, &blob, Utc::now()).await?;
    drop(conn);
    let draft = Draft {
        reply_to: None,
        nodes: vec![DraftNode::Voice { sha256, size }],
    };
    let id = poster
        .queue(draft)
        .await
        .map_err(|error| Failure::new("not_sent", format!("not sent: {error}")))?;
    Ok(Sent {
        handle: format!("audio#{id}.0"),
    })
}
