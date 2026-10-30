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
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::tool::Tool;
use super::{Context, Failure};

/// How long QQ lets any message be recalled.
const WINDOW: TimeDelta = TimeDelta::minutes(2);
const PER_RUN: u32 = 10;

pub struct RecallMessage;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Args {
    #[schemars(description = "消息的编号，#123 就是 123")]
    id: i64,
}

#[derive(Serialize, JsonSchema)]
pub struct Recalled {
    recalled: i64,
}

impl Tool for RecallMessage {
    const NAME: &'static str = "recall_message";
    const DESCRIPTION: &'static str =
        "撤回本群发出 2 分钟内的一条消息：你自己的，或者你是群管理员时普通成员的。";
    const PER_RUN: Option<u32> = Some(PER_RUN);
    const JOB: bool = false;

    type Args = Args;
    type Output = Recalled;

    fn guide() -> String {
        format!(
            "撤回本群的一条消息，id 是行首 #编号 里的数字。撤不撤由你判断：刷屏、广告、违规内容，或者有人请你撤、理由正当时再用，撤完简短说一声。\n  \
            QQ 只让撤发出 {} 分钟内的：你自己说的（一段是一条，一次回复分成几段的要一段一段撤）；你是群管理员时还有普通成员的，群主和管理员的撤不了。私聊里只能撤你自己的。\n  \
            QQ 撤了才返回；撤不了会抛错，说明原因。记录里会多一行你的 [unsend#id]，QQ 没撤的标着（没发出去）。一次运行最多撤 {PER_RUN} 条。",
            WINDOW.num_minutes()
        )
    }

    async fn run(context: &Context, Args { id }: Args) -> Result<Recalled, Failure> {
        recall(context, id).await?;
        Ok(Recalled { recalled: id })
    }
}

async fn recall(context: &Context, id: i64) -> Result<(), Failure> {
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
    Ok(())
}

#[cfg(test)]
mod tests;
