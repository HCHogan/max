//! QQ's messages as `Inbound`: see "Inbound" in docs/design/qq.md. qqbot
//! reads QQ's markup; here its mentions, faces and attachments become
//! nodes, with where to download each attachment, a merged forward
//! becomes Max's form of it (`forward`), and the quoted message is found
//! by its `msg_idx`, or by what QQ shows of it.

use chrono::{DateTime, Utc};
use max_core::message::{
    Emote, MediaKind, MediaMeta, MediaRef, MentionTarget, Node, Platform, Role,
};
use max_db::platform::ConversationKind;
use qqbot::content::{self, Segment};
use qqbot::event::{self, Attachment, AttachmentKind, Element, Message};
use qqbot::{Dispatch, Event};

use super::native_id;
use max::inbound::{Chat, InNode, Inbound, Person, Quote};

/// A message someone sent Max, or None for every other event.
pub fn inbound(dispatch: &mut Dispatch, now: DateTime<Utc>) -> Option<Inbound> {
    let (chat, message) = match &dispatch.event {
        Event::Group { message, .. } => (
            Chat {
                native_id: native_id(qqbot::Chat::Group(message.group_openid.as_deref()?)),
                kind: ConversationKind::Group,
            },
            message,
        ),
        Event::Private(message) => (
            Chat {
                native_id: native_id(qqbot::Chat::User(message.author.user_openid.as_deref()?)),
                kind: ConversationKind::Direct,
            },
            message,
        ),
        _ => return None,
    };
    let author = &message.author;
    let native_user_id = author
        .member_openid
        .clone()
        .or_else(|| author.user_openid.clone())
        .or_else(|| author.id.clone())?;
    let role = match author.role() {
        Some(event::Role::Owner) => Some(Role::Owner),
        Some(event::Role::Admin) => Some(Role::Admin),
        Some(event::Role::Member) => Some(Role::Member),
        None if chat.kind == ConversationKind::Group => Some(Role::Member),
        None => None,
    };
    let mut nodes = match message.forward() {
        Some(forward) => forward::nodes(&forward),
        None => content_nodes(&message.content, Some(message)),
    };
    nodes.extend(message.attachments.iter().map(attachment));
    let quote = message.quotes().map(|quote_id| Quote {
        quote_id: Some(quote_id.to_owned()),
        ..message.quoted().map(shown).unwrap_or_default()
    });
    let at = message
        .timestamp
        .as_deref()
        .and_then(|at| DateTime::parse_from_rfc3339(at).ok())
        .map_or(now, |at| at.to_utc());
    Some(Inbound {
        platform: Platform::Qq,
        chat,
        native_id: message.id.clone(),
        quote_id: message.msg_idx().map(str::to_owned),
        sender: Person {
            native_user_id,
            // A private message's author has no name at all; an empty one
            // is no name either.
            name: author
                .username
                .clone()
                .filter(|name| !name.trim().is_empty())
                .unwrap_or_else(|| "某人".into()),
            role,
        },
        at,
        quote,
        nodes,
        // The payload goes with the message, taken: nothing else reads it.
        raw: dispatch.data.take(),
    })
}

/// What QQ shows of a quoted message: its text, without mentions or
/// faces, and its files' names. A quoted message that quotes another or
/// holds a forward comes as a dump, of which only its own count, not what
/// it quotes in turn.
fn shown(quoted: &Element) -> Quote {
    let mut files: Vec<String> = quoted
        .attachments
        .iter()
        .filter_map(|attachment| attachment.filename.clone())
        .collect();
    let text = match quoted.dump() {
        Some(dump) => {
            let own = dump.messages.into_iter().next().unwrap_or_default();
            files.extend(own.files.into_iter().filter_map(|file| file.name));
            plain(own.text.as_deref().unwrap_or_default())
        }
        None => plain(quoted.content.as_deref().unwrap_or_default()),
    };
    Quote {
        quote_id: None,
        text: Some(text).filter(|text| !text.trim().is_empty()),
        files,
    }
}

/// Content's text alone, without mentions or faces.
fn plain(content: &str) -> String {
    content::parse(content)
        .into_iter()
        .filter_map(|segment| match segment {
            Segment::Text(text) => Some(text),
            _ => None,
        })
        .collect()
}

/// Content as nodes. A mention's name comes from `message`'s `mentions`;
/// without one, as in a forward, it is 某人.
fn content_nodes(content: &str, message: Option<&Message>) -> Vec<InNode> {
    content::parse(content)
        .into_iter()
        .map(|segment| match segment {
            Segment::Text(text) => InNode::Node(Node::Text { text }),
            Segment::AtAll => InNode::Node(Node::Mention {
                target: MentionTarget::All,
                display: "全体成员".into(),
            }),
            Segment::At(openid) => {
                let user = message.and_then(|message| message.mentioned(&openid));
                let display = user
                    .and_then(|user| user.username.clone())
                    .unwrap_or_else(|| "某人".into());
                match user {
                    Some(user) if user.is_you => InNode::MentionMe { display },
                    _ => InNode::Mention {
                        user: openid,
                        display,
                    },
                }
            }
            Segment::Face(face) => InNode::Node(Node::Emote(Emote {
                platform: Platform::Qq,
                id: face.id,
                name: face.name,
            })),
        })
        .collect()
}

fn attachment(attachment: &Attachment) -> InNode {
    let kind = match attachment.kind() {
        AttachmentKind::Picture => MediaKind::Image,
        AttachmentKind::Video => MediaKind::Video,
        AttachmentKind::Voice => MediaKind::Audio,
        AttachmentKind::File => MediaKind::File,
    };
    InNode::Node(Node::Media {
        media: attachment.download_url().map(MediaRef::Remote),
        meta: MediaMeta {
            kind,
            mime: attachment.content_type.clone(),
            size: attachment.size,
            name: attachment.filename.clone(),
            description: attachment
                .asr_refer_text
                .clone()
                .filter(|text| !text.trim().is_empty()),
        },
    })
}

mod forward;
#[cfg(test)]
mod tests;
