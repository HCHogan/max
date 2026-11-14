//! `rows`: the conversation's timeline as data, for the programs Max
//! keeps in the group's VM. The system prompt doesn't declare it, as it
//! doesn't `say` and `wake`: a turn reads the timeline in its context,
//! and looks further back with `history`, which gives the rows as the
//! text a model reads. This gives each row as max's core has it
//! (`max_core::message::Message`), its content in nodes, with what the
//! ledger knows of it besides, so that a program can make of the
//! timeline what max's own projection makes of it. `maxx events --full`
//! carries the same for the rows as they come (vm/events.rs). See "Rows
//! as data" in docs/rust-rewrite.md.

use std::collections::BTreeMap;

use max_core::ids::{IdentityId, MessageId, PrincipalId};
use max_core::message::{Content, MentionTarget, Message, Node};
use max_db::ledger::{self, Delivery, Row};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::tool::Tool;
use super::{Context, Failure};
use crate::conversation::project;

/// How many rows a call reads: when it doesn't say, and at most.
const DEFAULT: usize = 100;
const MOST: usize = 1000;

pub struct Rows;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Args {
    #[schemars(description = "the rows after this message, 123 for #123: the first of them")]
    after: Option<i64>,
    #[schemars(description = "the rows before this message; without after, the newest of them")]
    before: Option<i64>,
    #[schemars(
        range(min = 1, max = MOST),
        description = format!("how many, {DEFAULT} by default")
    )]
    limit: Option<usize>,
}

#[derive(Serialize, JsonSchema)]
pub struct Read {
    /// In the timeline's order, each as [`data`] writes it.
    #[schemars(with = "Vec<Shape>")]
    rows: Vec<Value>,
    /// Whose each account in the rows is, as [`known`] writes them.
    people: BTreeMap<String, i64>,
    /// The timeline's last row; 0 while it has none.
    head: i64,
}

impl Tool for Rows {
    const NAME: &'static str = "rows";
    const DESCRIPTION: &'static str = "This chat's records as data, for a program: each row as it is stored, its content in nodes. history gives the same rows as the text a model reads.";
    const TURN: bool = false;

    type Args = Args;
    type Output = Read;

    fn guide() -> String {
        format!(
            "Reads this chat's records as data, for a program that makes its own text of them; to read them yourself, use history. rows are in order of time: with after, the first limit rows after that message, and so on from the last of them; without, the newest limit rows, before before if it is given. limit is {DEFAULT} by default and at most {MOST}. head is the last row there is.\n  \
            A row is {{id, conversation, at, sender: {{identity, name, role}}, content, turn, raw, command, delivery}}: at is UTC; turn is the turn of yours that said it; raw.said_by is program or host for a row of your account that you didn't say; command is true for a /command and its answer; delivery is sent, failed or unknown for what your account sent, once that is known.\n  \
            content is {{type: \"message\", reply_to, nodes}}, {{type: \"edit\", target, nodes}}, the new content of an earlier row, or {{type: \"unsend\", target}}. A node is {{type: \"text\", text}}; {{type: \"mention\", target: {{identity}} or \"all\", display}}; {{type: \"media\", media, meta: {{kind, mime, size, name, description}}}}, whose handle is kind#id.n, n counting the row's media from 0; {{type: \"emote\", platform, id, name}}; {{type: \"card\", tag, title, subtitle, url}}; {{type: \"forward\", native_id, count}}; or {{type: \"unsupported\", source, description}}.\n  \
            people has, for each identity among the senders and the mentioned, the person's number: what [mention#…] takes."
        )
    }

    async fn run(context: &Context, args: Args) -> Result<Read, Failure> {
        let conversation = context.place.conversation;
        let limit = i64::try_from(args.limit.unwrap_or(DEFAULT)).unwrap_or(i64::MAX);
        let from = args.after.map(|id| MessageId(id.saturating_add(1)));
        let until = args.before.map(MessageId);
        let mut conn = context.services.pool.acquire().await?;
        // On from a row, or the newest there are.
        let newest = args.after.is_none();
        let ids =
            ledger::stretch(&mut conn, conversation, (from, until), None, newest, limit).await?;
        let rows = ledger::picked(&mut conn, conversation, &ids).await?;
        let messages = rows.iter().map(|row| &row.message);
        let people = project::people(&mut conn, messages, &context.place).await?;
        let head = ledger::head(&mut conn, conversation).await?;
        Ok(Read {
            people: rows
                .iter()
                .flat_map(|row| known(&row.message, &people))
                .collect(),
            rows: rows.iter().map(data).collect(),
            head: head.map_or(0, |id| id.0),
        })
    }
}

/// What [`data`] writes, for the tool's schema: a row's own fields. What
/// its content is, the guide says. A test holds the two together.
#[derive(JsonSchema)]
#[expect(dead_code, reason = "a schema, never a value")]
struct Shape {
    id: i64,
    conversation: i64,
    sender: Sender,
    at: String,
    content: Map<String, Value>,
    turn: Option<i64>,
    raw: Option<Map<String, Value>>,
    command: bool,
    delivery: Option<String>,
}

#[derive(JsonSchema)]
#[expect(dead_code, reason = "a schema, never a value")]
struct Sender {
    identity: i64,
    name: String,
    role: Option<String>,
}

/// A row as a program reads it: the message as max's core writes it, and
/// what the ledger knows of the row besides. A guest's programs read
/// this, so a field that goes or changes its meaning is a change to the
/// contract with them (nix/contract.nix); one more isn't.
pub(crate) fn data(row: &Row) -> Value {
    let mut data = serde_json::to_value(&row.message).expect("a message is JSON");
    data["command"] = json!(row.command);
    data["delivery"] = json!(row.delivery.map(|delivery| match delivery {
        Delivery::Sent => "sent",
        Delivery::Failed => "failed",
        Delivery::Unknown => "unknown",
    }));
    data
}

/// The person behind each account `message` shows, its sender's and
/// those it mentions, of those `people` knows: an identity's number, as
/// the row has it, to the person's.
pub(crate) fn known(
    message: &Message,
    people: &BTreeMap<IdentityId, PrincipalId>,
) -> BTreeMap<String, i64> {
    let nodes = match &message.content {
        Content::Message { nodes, .. } | Content::Edit { nodes, .. } => &nodes[..],
        Content::Unsend { .. } => &[],
    };
    let mentioned = nodes.iter().filter_map(|node| match node {
        Node::Mention {
            target: MentionTarget::Identity(identity),
            ..
        } => Some(*identity),
        _ => None,
    });
    std::iter::once(message.sender.identity)
        .chain(mentioned)
        .filter_map(|identity| Some((identity.0.to_string(), people.get(&identity)?.0)))
        .collect()
}

#[cfg(test)]
mod tests;
