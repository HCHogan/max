//! `mute_member`: mutes someone in the group, or lifts it, as one of its
//! admins. See "Group management" in docs/design/platforms.md.
//!
//! Max's own rules are checked here: there is no muting in a private
//! chat, nor of Max, nor of someone who hasn't spoken in the group. The
//! platform's adapter checks its own, and does it. A mute leaves no row;
//! the log has it.

use chrono::{TimeDelta, Utc};
use max_core::ids::PrincipalId;
use max_db::platform::{self, ConversationKind};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use tracing::info;

use super::tool::Tool;
use super::{Context, Failure};

/// The `mute_member` tool.
#[derive(Debug)]
pub struct MuteMember;

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Args {
    #[schemars(description = "the number in [mention#number]")]
    member: i64,
    #[schemars(range(min = 0), description = "seconds to mute for; 0 lifts the mute")]
    seconds: i64,
}

#[derive(Debug, Serialize, JsonSchema)]
pub struct Muted {
    member: i64,
    /// None when lifted.
    until: Option<String>,
}

impl Tool for MuteMember {
    const NAME: &'static str = "mute_member";
    const DESCRIPTION: &'static str =
        "Mutes a member of this group, or lifts a mute; you have to be an admin of the group.";

    type Args = Args;
    type Output = Muted;

    fn guide() -> String {
        "Mutes someone in this group, or lifts a mute. member is the number in [mention#number]; seconds is how long from now, 0 lifts it. Whether to mute, and for how long, is yours to judge: for flooding, ads or abuse, or when someone asks and the reason is sound; say so briefly in the chat afterwards.\n  \
        Whom you can mute, and for how long at most, is the platform's to say: the system prompt has its rules. There is no muting in a private chat, nor of yourself, nor of anybody who hasn't spoken in this group. Muting someone already muted moves the end to seconds from now.\n  \
        It returns once the platform has done it: until is when the mute ends, null when lifted; if it doesn't, the call fails and says why. No row is added to the records."
            .to_owned()
    }

    async fn run(context: &Context, args: Args) -> Result<Muted, Failure> {
        mute(context, args).await
    }
}

async fn mute(context: &Context, Args { member, seconds }: Args) -> Result<Muted, Failure> {
    // A mute goes to the platform from here, not through the
    // conversation's actor, which then couldn't refuse it once Max is
    // stopped: it is asked.
    if let Some(conversation) = context.poster.as_ref() {
        let allowed = conversation.act_alone().await;
        allowed.map_err(|why| Failure::new("refused", why.to_string()))?;
    }
    let place = &context.place;
    let Some(adapter) = context.services.platforms.get(&place.platform) else {
        return Err(Failure::new("unavailable", "nobody can be muted from here"));
    };
    let refused = |why: &str| Err(Failure::new("refused", why));
    if place.kind == ConversationKind::Direct {
        return refused("there is no muting in a private chat");
    }
    if PrincipalId::new(member) == place.me.principal {
        return refused("you can't mute yourself");
    }
    let mut conn = context.services.pool.acquire().await?;
    let speaker = platform::speaker(&mut conn, place.endpoint, PrincipalId::new(member)).await?;
    drop(conn);
    let Some(speaker) = speaker else {
        return Err(Failure::new(
            "not_found",
            format!("[mention#{member}] hasn't spoken in this group, and can't be muted"),
        ));
    };
    if speaker.identity == place.me.identity {
        return refused("you can't mute yourself");
    }
    let until = if seconds > 0 {
        let after = TimeDelta::try_seconds(seconds);
        let until = after.and_then(|after| Utc::now().checked_add_signed(after));
        Some(until.ok_or_else(|| Failure::new("refused", "no mute is that long"))?)
    } else {
        None
    };
    adapter.mute(place, &speaker, until).await?;
    info!(conversation = %place.conversation, member, seconds, "muted");
    let until = until.map(|until| {
        until
            .with_timezone(&context.services.offset)
            .format("%Y-%m-%d %H:%M")
            .to_string()
    });
    Ok(Muted { member, until })
}
