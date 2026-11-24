//! wxdesk's messages as `Inbound`: see "Inbound" in docs/design/wechat.md.
//! A message is what the client's window showed of it: its text, with a
//! mention as `@name` and a four-per-em space; a quote as its sender's
//! name and text; a picture or file as its bytes, which the listener has
//! put in the content store.

use chrono::{DateTime, Utc};
use max_core::message::{
    MediaKind, MediaMeta, MediaRef, MentionTarget, Node, Platform, Role, Unsupported,
};
use max_db::platform::ConversationKind;
use wxdesk_proto::{Kind, Message};

use super::native_id;
use max::inbound::{Chat, InNode, Inbound, Person, Quote};

/// What WeChat puts after the name in a mention.
const AFTER_MENTION: char = '\u{2005}';

/// Who someone is when the window didn't show who sent it.
const SOMEONE: &str = "某人";

/// A message someone sent Max, or None for Max's own and the client's
/// lines, such as someone joining. `run` is the driver's, `me` what Max is
/// called there, and `media` where the picture or file it carries is.
#[must_use]
pub fn inbound(
    message: &Message,
    run: u64,
    me: &str,
    media: Option<MediaRef>,
    now: DateTime<Utc>,
) -> Option<Inbound> {
    if message.mine || message.kind == Kind::System {
        return None;
    }
    let kind = if message.group {
        ConversationKind::Group
    } else {
        ConversationKind::Direct
    };
    let name = message.sender.clone().unwrap_or_else(|| SOMEONE.to_owned());
    let nodes = match message.kind {
        Kind::Text => text(&message.text, me),
        Kind::Image => vec![InNode::Node(Node::Media {
            media,
            meta: meta(MediaKind::Image, message, None),
        })],
        Kind::File => {
            let name = message.text.lines().nth(1).map(str::to_owned);
            vec![InNode::Node(Node::Media {
                media,
                meta: meta(MediaKind::File, message, name),
            })]
        }
        Kind::Voice => unsupported("voice", "语音消息"),
        Kind::Sticker => unsupported("sticker", "动画表情"),
        Kind::System => return None,
    };
    let quote = message.quote.as_ref().map(|quote| Quote {
        quote_id: None,
        text: Some(quote.text.clone()).filter(|text| !text.trim().is_empty()),
        files: Vec::new(),
    });
    // The bytes are in the store; the payload keeps the rest.
    let mut raw = message.clone();
    if let Some(attachment) = &mut raw.attachment {
        attachment.data.clear();
    }
    Some(Inbound {
        platform: Platform::Wechat,
        chat: Chat {
            native_id: native_id(kind, &message.chat),
            kind,
        },
        native_id: format!("{run}-{}", message.seq),
        quote_id: None,
        sender: Person {
            native_user_id: name.clone(),
            name,
            role: message.group.then_some(Role::Member),
        },
        at: DateTime::from_timestamp(message.at, 0).unwrap_or(now),
        quote,
        nodes,
        raw: serde_json::to_value(raw).unwrap_or_default(),
    })
}

fn meta(kind: MediaKind, message: &Message, name: Option<String>) -> MediaMeta {
    let attachment = message.attachment.as_ref();
    MediaMeta {
        kind,
        mime: attachment.map(|a| a.mime.clone()),
        size: None,
        name: name.or_else(|| attachment.map(|a| a.name.clone())),
        description: None,
    }
}

fn unsupported(source: &str, description: &str) -> Vec<InNode> {
    vec![InNode::Node(Node::Unsupported(Unsupported {
        source: source.to_owned(),
        description: description.to_owned(),
    }))]
}

/// Text as nodes: `@name` and a four-per-em space is a mention, of Max
/// when the name is Max's, of everyone as `@所有人`.
fn text(text: &str, me: &str) -> Vec<InNode> {
    let mut nodes = Vec::new();
    let mut plain = String::new();
    let mut rest = text;
    while let Some(at) = rest.find('@') {
        let (before, from) = rest.split_at(at);
        plain.push_str(before);
        let name = from[1..]
            .split_once(AFTER_MENTION)
            .map(|(name, _)| name)
            .filter(|name| !name.is_empty() && !name.contains('\n') && name.chars().count() <= 32);
        let Some(name) = name else {
            plain.push('@');
            rest = &from[1..];
            continue;
        };
        if !plain.is_empty() {
            nodes.push(InNode::Node(Node::Text {
                text: std::mem::take(&mut plain),
            }));
        }
        nodes.push(if name == me {
            InNode::MentionMe {
                display: name.to_owned(),
            }
        } else if name == "所有人" {
            InNode::Node(Node::Mention {
                target: MentionTarget::All,
                display: name.to_owned(),
            })
        } else {
            InNode::Mention {
                user: name.to_owned(),
                display: name.to_owned(),
            }
        });
        rest = &from[1 + name.len() + AFTER_MENTION.len_utf8()..];
    }
    plain.push_str(rest);
    if !plain.is_empty() {
        nodes.push(InNode::Node(Node::Text { text: plain }));
    }
    nodes
}

#[cfg(test)]
mod tests;
