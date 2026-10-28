//! QQ's messages as `Inbound`: see "入站" under "QQ 官方机器人" in
//! docs/rust-rewrite.md. Text with `<@openid>` mentions and
//! `<faceType=…>` faces becomes nodes; attachments become media; the
//! quoted message is found by its `msg_idx`, or by its text.

use chrono::{DateTime, Utc};
use max_core::message::{Emote, MediaKind, MediaMeta, MentionTarget, Node, Platform, Role};
use max_db::platform::ConversationKind;
use qqbot::event::{Attachment, Message, User};
use qqbot::{Dispatch, Event};

use crate::inbound::{Chat, InNode, Inbound, Person, Quote};

/// What a group message and a private one share.
struct Parts<'a> {
    chat: Chat,
    id: &'a str,
    author: &'a User,
    content: &'a str,
    attachments: &'a [Attachment],
    mentions: &'a [User],
    timestamp: Option<&'a str>,
    message: &'a dyn Message,
}

/// A message someone sent Max, or None for every other event.
pub fn inbound(dispatch: &Dispatch, now: DateTime<Utc>) -> Option<Inbound> {
    let parts = match &dispatch.event {
        Event::Group { message, .. } => Parts {
            chat: Chat {
                native_id: format!("group:{}", message.group_openid),
                kind: ConversationKind::Group,
            },
            id: &message.id,
            author: &message.author,
            content: &message.content,
            attachments: &message.attachments,
            mentions: &message.mentions,
            timestamp: message.timestamp.as_deref(),
            message,
        },
        Event::Private(message) => Parts {
            chat: Chat {
                native_id: format!("c2c:{}", message.author.user_openid.as_deref()?),
                kind: ConversationKind::Direct,
            },
            id: &message.id,
            author: &message.author,
            content: &message.content,
            attachments: &message.attachments,
            mentions: &[],
            timestamp: message.timestamp.as_deref(),
            message,
        },
        _ => return None,
    };
    let Parts {
        chat,
        id,
        author,
        content,
        attachments,
        mentions,
        timestamp,
        message,
    } = parts;
    let native_user_id = author
        .member_openid
        .clone()
        .or_else(|| author.user_openid.clone())
        .or_else(|| author.id.clone())?;
    let role = match author.member_role.as_deref() {
        Some("owner") => Some(Role::Owner),
        Some("admin") => Some(Role::Admin),
        Some(_) => Some(Role::Member),
        None if chat.kind == ConversationKind::Group => Some(Role::Member),
        None => None,
    };
    let mut nodes = content_nodes(content, mentions);
    nodes.extend(attachments.iter().map(attachment));
    let quote = message.quotes().map(|quote_id| Quote {
        quote_id: Some(quote_id.to_owned()),
        text: message.quoted().and_then(|quoted| quoted.content.clone()),
    });
    let at = timestamp
        .and_then(|at| DateTime::parse_from_rfc3339(at).ok())
        .map_or(now, |at| at.to_utc());
    Some(Inbound {
        platform: Platform::Qq,
        chat,
        native_id: id.to_owned(),
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
        raw: dispatch.data.clone(),
    })
}

/// Text, `<@openid>` and `<@all>` mentions, and `<faceType=…>` faces.
fn content_nodes(content: &str, mentions: &[User]) -> Vec<InNode> {
    let mut nodes = Vec::new();
    let mut text = String::new();
    let mut rest = content;
    while let Some(start) = rest.find('<') {
        let Some(len) = rest[start..].find('>') else {
            break;
        };
        let tag = &rest[start + 1..start + len];
        let node = if let Some(openid) = tag.strip_prefix('@') {
            Some(mention(openid, mentions))
        } else if tag.starts_with("faceType=") {
            Some(InNode::Node(Node::Emote(face(tag))))
        } else {
            None
        };
        let Some(node) = node else {
            // A < that starts no tag, such as in "a<b".
            text.push_str(&rest[..=start]);
            rest = &rest[start + 1..];
            continue;
        };
        text.push_str(&rest[..start]);
        if !text.is_empty() {
            nodes.push(InNode::Node(Node::Text {
                text: std::mem::take(&mut text),
            }));
        }
        nodes.push(node);
        rest = &rest[start + len + 1..];
    }
    text.push_str(rest);
    if !text.is_empty() {
        nodes.push(InNode::Node(Node::Text { text }));
    }
    nodes
}

fn mention(openid: &str, mentions: &[User]) -> InNode {
    if openid == "all" || openid == "everyone" {
        return InNode::Node(Node::Mention {
            target: MentionTarget::All,
            display: "全体成员".into(),
        });
    }
    let user = mentions.iter().find(|user| {
        [&user.member_openid, &user.id, &user.user_openid]
            .into_iter()
            .any(|id| id.as_deref() == Some(openid))
    });
    let display = user
        .and_then(|user| user.username.clone())
        .unwrap_or_else(|| "某人".into());
    match user {
        Some(user) if user.is_you => InNode::MentionMe { display },
        _ => InNode::Mention {
            user: openid.to_owned(),
            display,
        },
    }
}

/// `faceType=1,faceId="306",ext="<base64 of {"text":"牛气冲天"}>"`.
fn face(tag: &str) -> Emote {
    let field = |name: &str| {
        let start = tag.find(&format!("{name}=\""))? + name.len() + 2;
        let end = tag[start..].find('"')? + start;
        Some(&tag[start..end])
    };
    let name = field("ext")
        .and_then(base64)
        .and_then(|json| serde_json::from_slice::<serde_json::Value>(&json).ok())
        .and_then(|ext| ext["text"].as_str().map(str::to_owned))
        .filter(|name| !name.is_empty());
    Emote {
        platform: Platform::Qq,
        id: field("faceId").unwrap_or_default().to_owned(),
        name,
    }
}

fn attachment(attachment: &Attachment) -> InNode {
    let mime = attachment.content_type.clone();
    let kind = match mime.as_deref().unwrap_or_default() {
        mime if mime.starts_with("image/") => MediaKind::Image,
        mime if mime.starts_with("video/") => MediaKind::Video,
        mime if mime == "voice" || mime.starts_with("audio/") => MediaKind::Audio,
        _ => MediaKind::File,
    };
    let description = attachment
        .asr_refer_text
        .clone()
        .filter(|text| !text.trim().is_empty());
    InNode::Node(Node::Media {
        media: None,
        meta: MediaMeta {
            kind,
            mime,
            size: attachment.size,
            name: attachment.filename.clone(),
            description,
        },
    })
}

/// Standard base64, padded or not; None if it isn't.
fn base64(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    let (mut buffer, mut bits) = (0u32, 0);
    for byte in text.bytes().filter(|byte| *byte != b'=') {
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        };
        buffer = (buffer << 6) | u32::from(value);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buffer >> bits) as u8);
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests;
