//! `mute_member`: mutes someone in the group, or lifts it, as one of its
//! admins. See "群管理" under "QQ 官方机器人".
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
const PER_RUN: u32 = 5;

pub struct MuteMember;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Args {
    #[schemars(description = "[mention#编号] 里的数字")]
    member: i64,
    #[schemars(
        range(min = 0, max = LONGEST),
        description = format!("禁多少秒，0 是解除，最多 {} 天", LONGEST / DAY)
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
    const DESCRIPTION: &'static str = "在本群禁言一个普通成员，或者解除禁言；要你是群管理员。";
    const PER_RUN: Option<u32> = Some(PER_RUN);
    const JOB: bool = false;

    type Args = Args;
    type Output = Muted;

    fn guide() -> String {
        format!(
            "在本群禁言一个人，或者解除。member 是 [mention#编号] 里的数字；seconds 是从现在起禁多少秒，0 是解除，最多 {LONGEST}（{} 天）。禁不禁、禁多久由你判断：刷屏、广告、骂人，或者有人请你禁、理由正当时再用，禁完或解完在群里简短说一声。\n  \
            QQ 只让群管理员禁言普通成员：群主、管理员、你自己都禁不了，私聊里没有禁言；没在本群说过话的人也禁不了。对禁着的人再禁，是把结束时间改成从现在起 seconds 秒。\n  \
            QQ 办了才返回，until 是禁到几点，解除时是 null；办不了会抛错，说明原因。记录里不会多一行。一次运行最多 {PER_RUN} 次。",
            LONGEST / DAY
        )
    }

    async fn run(context: &Context, args: Args) -> Result<Muted, Failure> {
        mute(context, args).await
    }
}

async fn mute(context: &Context, Args { member, seconds }: Args) -> Result<Muted, Failure> {
    let place = &context.place;
    let (Some(admin), Platform::Qq) = (&context.services.admin, place.platform) else {
        return Err(Failure::new("unavailable", "这里禁言不了。"));
    };
    let refused = |why: &str| Err(Failure::new("refused", why));
    let Some(group) = place.native_id.strip_prefix("group:") else {
        return refused("私聊里没有禁言");
    };
    if PrincipalId(member) == place.me.principal {
        return refused("不能禁言你自己");
    }
    let mut conn = context.services.pool.acquire().await?;
    let speaker = platform::speaker(&mut conn, place.endpoint, PrincipalId(member)).await?;
    drop(conn);
    let Some(speaker) = speaker else {
        return Err(Failure::new(
            "not_found",
            format!("[mention#{member}] 没在本群说过话，禁言不了"),
        ));
    };
    if speaker.identity == place.me.identity {
        return refused("不能禁言你自己");
    }
    if matches!(speaker.role, Some(Role::Owner | Role::Admin)) {
        return refused("群主和管理员，QQ 不让机器人禁言");
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
            let muted = admin.muted(group).await.map_err(|e| not_muted(&e))?;
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
    admin
        .mute(group, &mute)
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
            "QQ 说机器人不是群管理员（40011030），禁言不了".to_owned()
        }
        api::Error::Api { code, message, .. } => format!("QQ 没办：{code} {message}"),
        error => format!("不知道 QQ 办成没有，再来一次也无妨：{error}"),
    };
    Failure::new("not_muted", why)
}

#[cfg(test)]
mod tests;
