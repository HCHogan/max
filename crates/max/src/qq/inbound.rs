//! QQ's messages as `Inbound`: see "Inbound" under "The official QQ bot" in
//! docs/rust-rewrite.md. Text with `<@openid>` mentions and
//! `<faceType=…>` faces becomes nodes; attachments become media, with
//! where to download them; the
//! quoted message is found by its `msg_idx`, or by what QQ shows of it.

use chrono::{DateTime, Utc};
use max_core::message::{
    Emote, MediaKind, MediaMeta, MediaRef, MentionTarget, Node, Platform, Role,
};
use max_db::platform::ConversationKind;
use qqbot::event::{Attachment, Element, User};
use qqbot::{Dispatch, Event};

use crate::inbound::{Chat, InNode, Inbound, Person, Quote};

/// A message someone sent Max, or None for every other event.
pub fn inbound(dispatch: &mut Dispatch, now: DateTime<Utc>) -> Option<Inbound> {
    let (chat, message) = match &dispatch.event {
        Event::Group { message, .. } => (
            Chat {
                native_id: format!("group:{}", message.group_openid.as_deref()?),
                kind: ConversationKind::Group,
            },
            message,
        ),
        Event::Private(message) => (
            Chat {
                native_id: format!("c2c:{}", message.author.user_openid.as_deref()?),
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
    let role = match author.member_role.as_deref() {
        Some("owner") => Some(Role::Owner),
        Some("admin") => Some(Role::Admin),
        Some(_) => Some(Role::Member),
        None if chat.kind == ConversationKind::Group => Some(Role::Member),
        None => None,
    };
    let mut nodes = content_nodes(&message.content, &message.mentions);
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

/// How a quoted message that quotes another, or holds a forward, comes:
/// as a dump, not as its text.
///
/// ```text
/// === 消息 1 ===
/// [消息内容]   its text
/// [消息类型] 引用消息
/// [附件1] 类型:图片 文件名:0FD9….jpg 尺寸:3072x4096 大小:8.2MB URL:…
/// [关联消息]
/// --- 第1条 ---
///     [消息内容] what it quotes, indented
/// ```
const DUMP: &str = "=== 消息 1 ===";

/// What QQ shows of a quoted message: its text, without mentions or
/// faces, and its files' names. Of a dump, the quoted message's own: not
/// what it quotes in turn.
fn shown(quoted: &Element) -> Quote {
    let content = quoted.content.as_deref().unwrap_or_default();
    let mut files: Vec<String> = quoted
        .attachments
        .iter()
        .filter_map(|attachment| attachment.filename.clone())
        .collect();
    let text = match content.strip_prefix(DUMP) {
        Some(dump) => {
            let own = dump.split("\n[关联消息]").next().unwrap_or_default();
            files.extend(
                own.lines()
                    .filter(|line| line.starts_with("[附件"))
                    .filter_map(|line| line.split_once("文件名:"))
                    .filter_map(|(_, rest)| rest.split_whitespace().next())
                    .map(str::to_owned),
            );
            own.split_once("[消息内容]")
                .and_then(|(_, rest)| rest.split("\n[消息类型]").next())
                .unwrap_or_default()
        }
        None => content,
    };
    let text: String = content_nodes(text, &[])
        .into_iter()
        .filter_map(|node| match node {
            InNode::Node(Node::Text { text }) => Some(text),
            _ => None,
        })
        .collect();
    Quote {
        quote_id: None,
        text: Some(text).filter(|text| !text.trim().is_empty()),
        files,
    }
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
    // A voice message is SILK or AMR; QQ's WAV of it is what can be played.
    let url = match kind {
        MediaKind::Audio => attachment
            .voice_wav_url
            .as_ref()
            .or(attachment.url.as_ref()),
        _ => attachment.url.as_ref(),
    };
    InNode::Node(Node::Media {
        media: url.map(|url| MediaRef::Remote(https(url))),
        meta: MediaMeta {
            kind,
            mime,
            size: attachment.size,
            name: attachment.filename.clone(),
            description,
        },
    })
}

/// QQ sometimes leaves the scheme off an attachment's address.
fn https(url: &str) -> String {
    if url.contains("://") {
        url.to_owned()
    } else {
        format!("https://{}", url.trim_start_matches('/'))
    }
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
            out.push((buffer >> bits).to_le_bytes()[0]);
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests;
