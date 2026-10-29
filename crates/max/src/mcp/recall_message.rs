//! `recall_message`: takes back a message of the group, through the actor
//! and QQ's sender. See "出站" under "QQ 官方机器人".
//!
//! What QQ would refuse anyway is refused here, with the reason, and
//! leaves no row: anything past QQ's two minutes, and the owner's and
//! admins' messages. Whether Max is an admin isn't asked: QQ's refusal
//! comes back in words.

use chrono::{TimeDelta, Utc};
use max_core::ids::MessageId;
use max_core::message::{Content, Platform, Role};
use max_db::ledger::{self, Delivery};
use max_db::platform::ConversationKind;
use serde::Deserialize;
use serde_json::{Value, json};

use super::{Context, Failure, arguments};

/// How long QQ lets any message be recalled.
const WINDOW: TimeDelta = TimeDelta::minutes(2);

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Args {
    id: i64,
}

pub async fn run(context: &Context, args: Value) -> Result<Value, Failure> {
    let Args { id } = arguments("recall_message", args)?;
    let place = &context.place;
    let (Some(poster), Platform::Qq) = (context.caller.poster(), place.platform) else {
        return Err(Failure::new("unavailable", "这里撤回不了消息。"));
    };
    let target = MessageId(id);
    let refused = |why: &str| Err(Failure::new("refused", why));
    let mut conn = context.services.pool.acquire().await?;
    let row = ledger::row(&mut conn, place.conversation, target).await?;
    let Some(row) = row.filter(|row| matches!(row.message.content, Content::Message { .. })) else {
        return Err(Failure::new(
            "not_found",
            format!("本群没有 #{id} 这条消息"),
        ));
    };
    if ledger::unsent(&mut conn, target).await? {
        return refused("这条已经撤回了");
    }
    if row.message.sender.identity == place.me.identity {
        match row.delivery {
            Some(Delivery::Failed) => return refused("这条本来就没发出去"),
            Some(Delivery::Unknown) => return refused("不知道这条发没发出去，撤不了"),
            Some(Delivery::Sent) | None => {}
        }
    } else if place.kind == ConversationKind::Direct {
        return refused("私聊里只能撤回你自己发的消息");
    } else if matches!(row.message.sender.role, Some(Role::Owner | Role::Admin)) {
        return refused("群主和管理员的消息，QQ 不让机器人撤");
    }
    // Max's, still on its way out, counts from now.
    let native = ledger::native(&mut conn, target, row.endpoint).await?;
    drop(conn);
    let since = native.map_or_else(Utc::now, |(_, at)| at);
    if row.endpoint != place.endpoint || Utc::now() - since > WINDOW {
        return refused("发出超过 2 分钟了，QQ 不让撤");
    }
    poster
        .unsend(target)
        .await
        .map_err(|error| Failure::new("not_recalled", format!("没撤回：{error}")))?;
    Ok(json!({ "recalled": id }))
}

#[cfg(test)]
mod tests;
