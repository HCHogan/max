//! `recall_message`: takes back a message of the group, through the actor
//! and QQ's sender. See "Outbound" under "The official QQ bot".
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

pub struct RecallMessage;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Args {
    #[schemars(description = "the message's number: 123 for #123")]
    id: i64,
}

#[derive(Serialize, JsonSchema)]
pub struct Recalled {
    recalled: i64,
}

impl Tool for RecallMessage {
    const NAME: &'static str = "recall_message";
    const DESCRIPTION: &'static str = "Recalls a message sent in this chat within the last 2 minutes: your own, or an ordinary member's when you are an admin of the group.";

    type Args = Args;
    type Output = Recalled;

    fn guide() -> String {
        format!(
            "Recalls a message of this chat; id is the number in the #number at the start of its line. Whether to is yours to judge: for flooding, ads or what breaks the rules, or when someone asks and the reason is sound; say so briefly afterwards.\n  \
            QQ lets only messages sent within {} minutes be recalled: what you said yourself (a segment is a message, so a reply sent in several is recalled one at a time), and, when you are an admin of the group, an ordinary member's; the owner's and the admins' can't be. In a private chat only your own.\n  \
            It returns once QQ has recalled it; if QQ doesn't, the call fails and says why. The records gain a row of yours, [unsend#id], marked （没发出去） if QQ didn't recall it.",
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
    let (Some(poster), Platform::Qq) = (context.poster.as_ref(), place.platform) else {
        return Err(Failure::new(
            "unavailable",
            "messages can't be recalled from here",
        ));
    };
    let target = MessageId(id);
    let refused = |why: &str| Err(Failure::new("refused", why));
    let mut conn = context.services.pool.acquire().await?;
    let row = ledger::row(&mut conn, place.conversation, target).await?;
    let Some(row) = row.filter(|row| matches!(row.message.content, Content::Message { .. })) else {
        return Err(Failure::new(
            "not_found",
            format!("there is no message #{id} in this chat"),
        ));
    };
    if ledger::unsent(&mut conn, target).await? {
        return refused("it was recalled already");
    }
    if row.message.sender.identity == place.me.identity {
        match row.delivery {
            Some(Delivery::Failed) => return refused("it was never sent"),
            Some(Delivery::Unknown) => {
                return refused("it isn't known whether it was sent, so it can't be recalled");
            }
            Some(Delivery::Sent) | None => {}
        }
    } else if place.kind == ConversationKind::Direct {
        return refused("in a private chat only your own messages can be recalled");
    } else if matches!(row.message.sender.role, Some(Role::Owner | Role::Admin)) {
        return refused("QQ doesn't let a bot recall the owner's or an admin's message");
    }
    // Max's, still on its way out, counts from now.
    let native = ledger::native(&mut conn, target, row.endpoint).await?;
    drop(conn);
    let since = native.map_or_else(Utc::now, |(_, at)| at);
    if row.endpoint != place.endpoint || Utc::now() - since > WINDOW {
        return refused("it was sent over 2 minutes ago, and QQ no longer lets it be recalled");
    }
    poster
        .unsend(target)
        .await
        .map_err(|error| Failure::new("not_recalled", format!("not recalled: {error}")))?;
    Ok(())
}

#[cfg(test)]
mod tests;
