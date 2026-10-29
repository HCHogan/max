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
use serde::Deserialize;
use serde_json::{Value, json};
use tracing::info;

use super::{Context, Failure, arguments};

/// QQ's longest mute: 30 days.
const LONGEST: i64 = 30 * 24 * 3600;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Args {
    member: i64,
    seconds: i64,
}

pub async fn run(context: &Context, args: Value) -> Result<Value, Failure> {
    let Args { member, seconds } = arguments("mute_member", args)?;
    let place = &context.place;
    let (Some(admin), Platform::Qq) = (&context.admin, place.platform) else {
        return Err(Failure::new("unavailable", "这里禁言不了。"));
    };
    let refused = |why: &str| Err(Failure::new("refused", why));
    let Some(group) = place.native_id.strip_prefix("group:") else {
        return refused("私聊里没有禁言");
    };
    if !(0..=LONGEST).contains(&seconds) {
        return Err(Failure::new(
            "bad_arguments",
            "seconds 要在 0 到 2592000（30 天）之间",
        ));
    }
    if PrincipalId(member) == place.me.principal {
        return refused("不能禁言你自己");
    }
    let mut conn = context.pool.acquire().await?;
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
            .with_timezone(&context.offset)
            .format("%Y-%m-%d %H:%M")
            .to_string()
    });
    Ok(json!({ "member": member, "until": until }))
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
