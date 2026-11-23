//! `recall_message`: takes back a message of the chat, through the actor
//! and the platform's sender. See "Group management" in
//! docs/design/platforms.md.
//!
//! What would be refused anyway is refused here, with the reason, and
//! leaves no row: by Max's rules, and by the platform's, which its adapter
//! checks (`Adapter::recallable`).

use chrono::Utc;
use max_core::ids::MessageId;
use max_core::message::Content;
use max_db::ledger::{self, Delivery};
use max_db::platform::ConversationKind;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::tool::Tool;
use super::{Context, Failure};

pub(super) struct RecallMessage;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub(super) struct Args {
    #[schemars(description = "the message's number: 123 for #123")]
    id: i64,
}

#[derive(Serialize, JsonSchema)]
pub(super) struct Recalled {
    recalled: i64,
}

impl Tool for RecallMessage {
    const NAME: &'static str = "recall_message";
    const DESCRIPTION: &'static str = "Recalls a message of this chat while the platform still lets it: your own, or someone else's when you are an admin of the group.";

    type Args = Args;
    type Output = Recalled;

    fn guide() -> String {
        "Recalls a message of this chat; id is the number in the #number at the start of its line. Whether to is yours to judge: for flooding, ads or what breaks the rules, or when someone asks and the reason is sound; say so briefly afterwards.\n  \
        What you said yourself can be recalled (a segment is a message, so a reply sent in several is recalled one at a time), and in a group, when you are its admin, others' too; in a private chat only your own. For how long, and whose, is the platform's to say: the system prompt has its rules.\n  \
        It returns once the platform has recalled it; if it doesn't, the call fails and says why. The records gain a row of yours, [unsend#id], marked （没发出去） if it wasn't recalled."
            .to_owned()
    }

    async fn run(context: &Context, Args { id }: Args) -> Result<Recalled, Failure> {
        recall(context, id).await?;
        Ok(Recalled { recalled: id })
    }
}

async fn recall(context: &Context, id: i64) -> Result<(), Failure> {
    let place = &context.place;
    let adapter = context.services.platforms.get(&place.platform);
    let (Some(poster), Some(adapter)) = (context.poster.as_ref(), adapter) else {
        return Err(Failure::new(
            "unavailable",
            "messages can't be recalled from here",
        ));
    };
    let target = MessageId::new(id);
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
    }
    if row.endpoint != place.endpoint {
        return refused("it was said in the chat this one goes on from, and can't be recalled");
    }
    // Max's, still on its way out, counts from now.
    let native = ledger::native(&mut conn, target, row.endpoint).await?;
    drop(conn);
    let sent = native.map_or_else(Utc::now, |(_, at)| at);
    adapter
        .recallable(place, &row.message, sent)
        .map_err(|why| Failure::new("refused", why))?;
    poster
        .unsend(target)
        .await
        .map_err(|error| Failure::new("not_recalled", format!("not recalled: {error}")))?;
    Ok(())
}
