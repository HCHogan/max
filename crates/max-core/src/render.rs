//! How timeline rows look to the model: one line each,
//! `[HH:MM 名字 #id]: 内容`. The tail, `[新消息]` blocks, intent and
//! historian all render rows with this, so a row reads the same everywhere.
//!
//! Placeholders follow the one grammar the segmenter parses: `[word#id]`,
//! optionally `: description`. Forms without an id (`[image: 一只猫]`) are
//! for reading only; the segmenter drops them when the model echoes one.

use std::collections::BTreeMap;

use chrono::FixedOffset;

use crate::faces;
use crate::ids::{FaceId, IdentityId, PrincipalId};
use crate::message::{Card, Content, Emote, MediaKind, MentionTarget, Message, Node, Platform};

/// Who is behind an account. The ledger stores accounts; the model sees
/// people.
pub trait People {
    fn principal(&self, identity: IdentityId) -> Option<PrincipalId>;
}

impl People for BTreeMap<IdentityId, PrincipalId> {
    fn principal(&self, identity: IdentityId) -> Option<PrincipalId> {
        self.get(&identity).copied()
    }
}

/// Something about a row the model should notice.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Mark {
    #[default]
    None,
    /// A trigger addressed to Max.
    MentionsYou,
    RepliesToYou,
    PokesYou,
    /// Max said it, but the platform refused it.
    NotSent,
    /// Max said it and crashed before hearing back from the platform.
    MaybeNotSent,
}

pub struct Render<'a, P> {
    pub people: &'a P,
    /// Local time, for HH:MM and dates.
    pub offset: FixedOffset,
}

impl<P: People> Render<'_, P> {
    pub fn line(&self, message: &Message, mark: Mark) -> String {
        self.header(message, mark) + &self.content(&message.content) + suffix(mark)
    }

    fn header(&self, message: &Message, mark: Mark) -> String {
        let time = message.at.with_timezone(&self.offset).format("%H:%M");
        let name = message.sender.name.replace(['\n', '\r'], " ");
        let note = match mark {
            Mark::MentionsYou => " @你",
            Mark::RepliesToYou => " 回复你",
            Mark::PokesYou => " 戳你",
            _ => "",
        };
        format!("[{time} {name} #{}{note}]: ", message.id)
    }

    /// A row's content on one line: line breaks become ` ⏎ `.
    pub fn content(&self, content: &Content) -> String {
        let text = match content {
            Content::Message { reply_to, nodes } => {
                reply_to
                    .map(|id| format!("[reply#{id}] "))
                    .unwrap_or_default()
                    + &self.nodes(nodes)
            }
            Content::Edit { target, nodes } => format!("[edit#{target}] {}", self.nodes(nodes)),
            Content::Unsend { target } => format!("[unsend#{target}]"),
            Content::React {
                target,
                emote,
                added,
            } => {
                let verb = if *added { "react" } else { "unreact" };
                format!("[{verb}#{target}: {}]", emote_name(emote).unwrap_or("表情"))
            }
            Content::Poke { target } => match self.people.principal(*target) {
                Some(principal) => format!("[poke#{principal}]"),
                None => "[poke]".to_owned(),
            },
        };
        text.trim().replace("\r\n", "\n").replace('\n', " ⏎ ")
    }

    fn nodes(&self, nodes: &[Node]) -> String {
        nodes.iter().map(|node| self.node(node)).collect()
    }

    fn node(&self, node: &Node) -> String {
        match node {
            Node::Text { text } => text.clone(),
            Node::Mention {
                target: MentionTarget::Identity(identity),
                display,
            } => match self.people.principal(*identity) {
                Some(principal) => format!("[mention#{principal}]"),
                None => format!("@{display}"),
            },
            Node::Mention {
                target: MentionTarget::All,
                display,
            } => format!("@{display}"),
            Node::Emote(emote) => match (emote.platform, emote.id.parse::<u32>()) {
                (Platform::Qq, Ok(id)) => labelled(&format!("face#{id}"), emote_name(emote)),
                _ => labelled("emote", emote_name(emote)),
            },
            Node::Media { meta, .. } => {
                let word = match meta.kind {
                    MediaKind::Image => "image",
                    MediaKind::Sticker => "sticker",
                    MediaKind::Video => "video",
                    MediaKind::Audio => "audio",
                    MediaKind::File => "file",
                };
                labelled(word, meta.description.as_deref().or(meta.name.as_deref()))
            }
            Node::Card(card) => card_line(card),
            Node::Forward(forward) => match forward.count {
                Some(count) => format!("[forward: {count} 条]"),
                None => "[forward]".to_owned(),
            },
            Node::Unsupported(unsupported) => format!("[{}]", unsupported.description),
        }
    }
}

fn suffix(mark: Mark) -> &'static str {
    match mark {
        Mark::NotSent => "（没发出去）",
        Mark::MaybeNotSent => "（可能没发出去）",
        _ => "",
    }
}

fn labelled(word: &str, label: Option<&str>) -> String {
    match label {
        Some(label) => format!("[{word}: {label}]"),
        None => format!("[{word}]"),
    }
}

/// A QQ reaction records only the QSid; the face table names it.
fn emote_name(emote: &Emote) -> Option<&str> {
    let curated = match emote.platform {
        Platform::Qq => emote.id.parse().ok().and_then(|id| faces::name(FaceId(id))),
        Platform::Matrix => None,
    };
    curated.or(emote.name.as_deref())
}

fn card_line(card: &Card) -> String {
    let subtitle = card
        .subtitle
        .as_ref()
        .map(|s| s.chars().take(80).collect::<String>());
    let mut parts: Vec<&str> = Vec::new();
    for part in [&card.tag, &card.title, &subtitle, &card.url]
        .into_iter()
        .flatten()
    {
        if parts.last() != Some(&part.as_str()) {
            parts.push(part);
        }
    }
    format!("[card: {}]", parts.join(" | "))
}

#[cfg(test)]
mod tests {
    use chrono::{TimeZone, Utc};
    use serde_json::Value;

    use super::*;
    use crate::ids::{ConversationId, MessageId};
    use crate::message::{ForwardRef, MediaMeta, Role, Sender, Unsupported};

    fn people() -> BTreeMap<IdentityId, PrincipalId> {
        [
            (IdentityId(1), PrincipalId(1)),
            (IdentityId(20), PrincipalId(12)),
        ]
        .into()
    }

    fn render(
        people: &BTreeMap<IdentityId, PrincipalId>,
    ) -> Render<'_, BTreeMap<IdentityId, PrincipalId>> {
        Render {
            people,
            offset: FixedOffset::east_opt(8 * 3600).unwrap(),
        }
    }

    fn message(id: i64, utc: (u32, u32, u32), name: &str, content: Content) -> Message {
        let (day, hour, minute) = utc;
        Message {
            id: MessageId(id),
            conversation: ConversationId(1),
            sender: Sender {
                identity: IdentityId(20),
                name: name.into(),
                role: Some(Role::Member),
            },
            at: Utc
                .with_ymd_and_hms(2026, 10, day, hour, minute, 0)
                .unwrap(),
            content,
            turn: None,
            raw: Value::Null,
        }
    }

    fn said(nodes: Vec<Node>) -> Content {
        Content::Message {
            reply_to: None,
            nodes,
        }
    }

    fn text(text: &str) -> Node {
        Node::Text { text: text.into() }
    }

    fn media(kind: MediaKind, description: Option<&str>) -> Node {
        Node::Media {
            media: None,
            meta: MediaMeta {
                kind,
                mime: None,
                size: None,
                name: None,
                description: description.map(Into::into),
            },
        }
    }

    #[test]
    fn a_day_of_rows() {
        let people = people();
        let rows = [
            message(100, (27, 15, 50), "小明", said(vec![text("晚安")])),
            message(
                101,
                (28, 1, 2),
                "小红\n换行名",
                said(vec![
                    Node::Mention {
                        target: MentionTarget::Identity(IdentityId(1)),
                        display: "Max".into(),
                    },
                    text(" 第一行\n第二行 "),
                    Node::Mention {
                        target: MentionTarget::Identity(IdentityId(99)),
                        display: "路人".into(),
                    },
                    Node::Mention {
                        target: MentionTarget::All,
                        display: "全体成员".into(),
                    },
                ]),
            ),
            message(
                102,
                (28, 1, 3),
                "Max",
                Content::Message {
                    reply_to: Some(MessageId(101)),
                    nodes: vec![
                        text("在"),
                        Node::Emote(Emote {
                            platform: Platform::Qq,
                            id: "271".into(),
                            name: None,
                        }),
                    ],
                },
            ),
            message(
                103,
                (28, 4, 30),
                "小明",
                said(vec![
                    media(MediaKind::Image, Some("一只猫")),
                    media(MediaKind::Sticker, None),
                    Node::Card(Card {
                        tag: Some("哔哩哔哩".into()),
                        title: Some("哔哩哔哩".into()),
                        subtitle: Some("简介".into()),
                        url: Some("https://b23.tv/x".into()),
                    }),
                    Node::Forward(ForwardRef {
                        native_id: "f".into(),
                        count: Some(3),
                    }),
                    Node::Unsupported(Unsupported {
                        source: "record".into(),
                        description: "语音消息".into(),
                    }),
                    Node::Emote(Emote {
                        platform: Platform::Matrix,
                        id: ":cat:".into(),
                        name: Some("cat".into()),
                    }),
                ]),
            ),
            message(
                104,
                (28, 4, 31),
                "小明",
                Content::Edit {
                    target: MessageId(103),
                    nodes: vec![text("改了")],
                },
            ),
            message(
                105,
                (28, 4, 31),
                "小明",
                Content::Unsend {
                    target: MessageId(103),
                },
            ),
            message(
                106,
                (28, 4, 32),
                "小红",
                Content::React {
                    target: MessageId(102),
                    emote: Emote {
                        platform: Platform::Qq,
                        id: "212".into(),
                        name: None,
                    },
                    added: true,
                },
            ),
            message(
                107,
                (28, 4, 32),
                "小红",
                Content::React {
                    target: MessageId(102),
                    emote: Emote {
                        platform: Platform::Qq,
                        id: "9999".into(),
                        name: None,
                    },
                    added: false,
                },
            ),
            message(
                108,
                (28, 4, 33),
                "小红",
                Content::Poke {
                    target: IdentityId(1),
                },
            ),
        ];
        let marks = [
            Mark::None,
            Mark::MentionsYou,
            Mark::NotSent,
            Mark::None,
            Mark::None,
            Mark::None,
            Mark::None,
            Mark::None,
            Mark::PokesYou,
        ];
        let render = render(&people);
        let lines: Vec<_> = rows
            .iter()
            .zip(marks)
            .map(|(row, mark)| render.line(row, mark))
            .collect();
        insta::assert_snapshot!(lines.join("\n"));
    }
}
