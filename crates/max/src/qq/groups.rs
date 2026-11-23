//! Muting, as one of a group's admins: what QQ would refuse anyway is
//! refused here, with the reason, and the rest is asked of QQ straight
//! away, not through the sender. A mute leaves no row on the timeline, so
//! there is nothing to keep in order with what Max says, and doing one
//! twice does no harm. Whether Max is an admin isn't asked: QQ's refusal
//! comes back in words.

use chrono::{DateTime, FixedOffset, SecondsFormat, TimeDelta, Utc};
use max_core::message::Role;
use max_db::platform::Speaker;
use qqbot::api::{self, Mute, MuteOp};

use super::group;
use crate::conversation::Place;
use crate::service::Failure;

/// QQ's longest mute.
pub(super) const LONGEST: TimeDelta = TimeDelta::days(30);

pub(super) async fn mute(
    client: &qqbot::Client,
    place: &Place,
    member: &Speaker,
    until: Option<DateTime<Utc>>,
) -> Result<(), Failure> {
    let refused = |why: String| Err(Failure::new("refused", why));
    let Some(group) = group(&place.native_id) else {
        return refused("there is no muting in a private chat".to_owned());
    };
    if matches!(member.role, Some(Role::Owner | Role::Admin)) {
        return refused("QQ doesn't let a bot mute the owner or an admin".to_owned());
    }
    let openid = member.native_user_id.as_str();
    let mute = match until {
        None => Mute {
            op: MuteOp::Del,
            member_openid: openid,
            mute_expire_at: String::new(),
        },
        Some(until) if until - Utc::now() > LONGEST => {
            return refused(format!("QQ mutes for at most {} days", LONGEST.num_days()));
        }
        Some(until) => {
            // QQ adds a mute, or moves the end of one that runs.
            let muted = client.muted(group).await.map_err(|e| not_muted(&e))?;
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
    client.mute(group, &mute).await.map_err(|e| not_muted(&e))
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
