//! `mute_member`: mutes someone in the group, or lifts it, as one of its
//! admins. See "Group management" under "The official QQ bot".
//!
//! What QQ would refuse anyway is refused here, with the reason: a private
//! chat, Max itself, and the owner and admins as their latest message here
//! shows them. Whether Max is an admin isn't asked: QQ's refusal comes
//! back in words. A mute leaves no row; the log has it.

use chrono::{FixedOffset, SecondsFormat, TimeDelta, Utc};
use max_core::ids::PrincipalId;
use max_core::message::{Platform, Role};
use max_db::platform;
use qqbot::api::{self, Mute, MuteOp};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use tracing::info;

use super::tool::Tool;
use super::{Context, Failure};

/// QQ's longest mute: 30 days.
const LONGEST: i64 = 30 * DAY;
const DAY: i64 = 24 * 3600;

pub struct MuteMember;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Args {
    #[schemars(description = "the number in [mention#number]")]
    member: i64,
    #[schemars(
        range(min = 0, max = LONGEST),
        description = format!("seconds to mute for; 0 lifts the mute; at most {} days", LONGEST / DAY)
    )]
    seconds: i64,
}

#[derive(Serialize, JsonSchema)]
pub struct Muted {
    member: i64,
    /// None when lifted.
    until: Option<String>,
}

impl Tool for MuteMember {
    const NAME: &'static str = "mute_member";
    const DESCRIPTION: &'static str = "Mutes an ordinary member of this group, or lifts a mute; you have to be an admin of the group.";

    type Args = Args;
    type Output = Muted;

    fn guide() -> String {
        format!(
            "Mutes someone in this group, or lifts a mute. member is the number in [mention#number]; seconds is how long from now, 0 lifts it, at most {LONGEST} ({} days). Whether to mute, and for how long, is yours to judge: for flooding, ads or abuse, or when someone asks and the reason is sound; say so briefly in the chat afterwards.\n  \
            QQ lets only a group's admins mute, and only ordinary members: the owner, the admins and yourself can't be muted, there is no muting in a private chat, and nobody who hasn't spoken in this group can be muted. Muting someone already muted moves the end to seconds from now.\n  \
            It returns once QQ has done it: until is when the mute ends, null when lifted; if QQ doesn't, the call fails and says why. No row is added to the records.",
            LONGEST / DAY
        )
    }

    async fn run(context: &Context, args: Args) -> Result<Muted, Failure> {
        mute(context, args).await
    }
}

async fn mute(context: &Context, Args { member, seconds }: Args) -> Result<Muted, Failure> {
    // A mute goes to QQ from here, not through the conversation's actor,
    // which then couldn't refuse it once Max is stopped: it is asked.
    if let Some(conversation) = context.poster.as_ref() {
        let allowed = conversation.act_alone().await;
        allowed.map_err(|why| Failure::new("refused", why))?;
    }
    let place = &context.place;
    let (Some(qq), Platform::Qq) = (&context.services.groups, place.platform) else {
        return Err(Failure::new("unavailable", "nobody can be muted from here"));
    };
    let refused = |why: &str| Err(Failure::new("refused", why));
    let Some(group) = place.native_id.strip_prefix("group:") else {
        return refused("there is no muting in a private chat");
    };
    if PrincipalId(member) == place.me.principal {
        return refused("you can't mute yourself");
    }
    let mut conn = context.services.pool.acquire().await?;
    let speaker = platform::speaker(&mut conn, place.endpoint, PrincipalId(member)).await?;
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
    if matches!(speaker.role, Some(Role::Owner | Role::Admin)) {
        return refused("QQ doesn't let a bot mute the owner or an admin");
    }
    let openid = speaker.native_user_id.as_str();
    let until = (seconds > 0).then(|| Utc::now() + TimeDelta::seconds(seconds));
    let mute = match until {
        None => Mute {
            op: MuteOp::Del,
            member_openid: openid,
            mute_expire_at: String::new(),
        },
        Some(until) => {
            // QQ adds a mute, or moves the end of one that runs.
            let muted = qq.muted(group).await.map_err(|e| not_muted(&e))?;
            let running = muted.iter().any(|muted| muted.member_openid == openid);
            Mute {
                op: if running { MuteOp::Update } else { MuteOp::Add },
                member_openid: openid,
                mute_expire_at: until
                    .with_timezone(&qq_time())
                    .to_rfc3339_opts(SecondsFormat::Secs, false),
            }
        }
    };
    qq.mute(group, &mute)
        .await
        .map_err(|error| not_muted(&error))?;
    info!(conversation = %place.conversation, member, seconds, "muted");
    let until = until.map(|until| {
        until
            .with_timezone(&context.services.offset)
            .format("%Y-%m-%d %H:%M")
            .to_string()
    });
    Ok(Muted { member, until })
}

/// The time zone QQ shows and was tried with.
fn qq_time() -> FixedOffset {
    FixedOffset::east_opt(8 * 3600).expect("+08:00 is in range")
}

/// What QQ's refusal, or its silence, tells Max.
fn not_muted(error: &api::Error) -> Failure {
    let why = match error {
        api::Error::Api { code: 40011030, .. } => {
            "QQ says the bot isn't an admin of the group (40011030), so it can't mute".to_owned()
        }
        api::Error::Api { code, message, .. } => format!("QQ refused: {code} {message}"),
        error => format!("it isn't known whether QQ did it; doing it again does no harm: {error}"),
    };
    Failure::new("not_muted", why)
}

#[cfg(test)]
mod tests;
