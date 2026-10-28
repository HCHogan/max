//! How timeline rows look to the model: one line each,
//! `[HH:MM 名字 #id]: 内容`, with a date line when the day changes and a gap
//! line after a long silence. The tail, `[新消息]` blocks, intent and
//! historian all render rows with this, so a row reads the same everywhere.
//!
//! Placeholders follow the one grammar the segmenter parses: `[word#id]`,
//! optionally `: description`. Forms without an id (`[image: 一只猫]`) are
//! for reading only; the segmenter drops them when the model echoes one.

use std::collections::BTreeMap;
use std::fmt::Write;

use chrono::{DateTime, Datelike, FixedOffset, TimeDelta, Utc, Weekday};

use crate::faces;
use crate::ids::{FaceId, IdentityId, PrincipalId};
use crate::message::{Card, Content, Emote, MediaKind, MentionTarget, Message, Node, Platform};

/// A silence at least this long gets a gap line.
const GAP: TimeDelta = TimeDelta::hours(1);

/// Characters of an over-long row the model sees before reaching for
/// `context_read`.
pub const EXCERPT_CHARS: usize = 2000;

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
    /// Rows in order. `after` is when the row before them was sent, if one
    /// was already shown, so a date line appears only when the day changes.
    pub fn lines<'m>(
        &self,
        rows: impl IntoIterator<Item = (&'m Message, Mark)>,
        mut after: Option<DateTime<Utc>>,
    ) -> String {
        let mut out = String::new();
        for (message, mark) in rows {
            let local = message.at.with_timezone(&self.offset);
            match after.map(|at| at.with_timezone(&self.offset)) {
                Some(before) if before.date_naive() == local.date_naive() => {
                    let gap = message.at - before.to_utc();
                    if gap >= GAP {
                        let _ = writeln!(out, "--- 过了 {} 小时 ---", gap.num_hours());
                    }
                }
                _ => {
                    let date = local.date_naive();
                    let _ = writeln!(out, "--- {date} {} ---", weekday(date.weekday()));
                }
            }
            out.push_str(&self.line(message, mark));
            out.push('\n');
            after = Some(message.at);
        }
        out
    }

    pub fn line(&self, message: &Message, mark: Mark) -> String {
        self.header(message, mark) + &self.content(&message.content) + suffix(mark)
    }

    /// The line cut to [`EXCERPT_CHARS`], pointing at the full text.
    pub fn excerpt(&self, message: &Message, mark: Mark) -> String {
        let content: String = self
            .content(&message.content)
            .chars()
            .take(EXCERPT_CHARS)
            .collect();
        format!(
            "{}{content}…（太长，全文见 #{}，用 context_read 读）{}",
            self.header(message, mark),
            message.id,
            suffix(mark)
        )
    }

    fn header(&self, message: &Message, mark: Mark) -> String {
        let time = message.at.with_timezone(&self.offset).format("%H:%M");
        let name = message.sender.name.replace(['\n', '\r'], " ");
        let note = match mark {
            Mark::MentionsYou => " @你",
            Mark::RepliesToYou => " 回复你",
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
                (Platform::Qq | Platform::QqLegacy, Ok(id)) => {
                    labelled(&format!("face#{id}"), emote_name(emote))
                }
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

/// The face table's name for a QQ face, else what the platform called it.
fn emote_name(emote: &Emote) -> Option<&str> {
    let curated = match emote.platform {
        Platform::Qq | Platform::QqLegacy => {
            emote.id.parse().ok().and_then(|id| faces::name(FaceId(id)))
        }
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

pub(crate) fn weekday(day: Weekday) -> &'static str {
    match day {
        Weekday::Mon => "周一",
        Weekday::Tue => "周二",
        Weekday::Wed => "周三",
        Weekday::Thu => "周四",
        Weekday::Fri => "周五",
        Weekday::Sat => "周六",
        Weekday::Sun => "周日",
    }
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone;
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
        ];
        let marks = [
            Mark::None,
            Mark::MentionsYou,
            Mark::NotSent,
            Mark::None,
            Mark::None,
            Mark::None,
        ];
        insta::assert_snapshot!(render(&people).lines(rows.iter().zip(marks), None));
    }

    #[test]
    fn a_continued_block_repeats_no_date() {
        let people = people();
        let row = message(5, (28, 2, 0), "小明", said(vec![text("嗯")]));
        let before = Utc.with_ymd_and_hms(2026, 10, 28, 1, 30, 0).unwrap();
        assert_eq!(
            render(&people).lines([(&row, Mark::None)], Some(before)),
            "[10:00 小明 #5]: 嗯\n"
        );
    }

    #[test]
    fn excerpt() {
        let people = people();
        let long = "长".repeat(EXCERPT_CHARS + 10);
        let row = message(7, (28, 2, 0), "小明", said(vec![text(&long)]));
        let line = render(&people).excerpt(&row, Mark::RepliesToYou);
        assert!(line.starts_with("[10:00 小明 #7 回复你]: 长长"));
        assert!(line.ends_with("长…（太长，全文见 #7，用 context_read 读）"));
        assert_eq!(
            line.split('…')
                .next()
                .unwrap()
                .chars()
                .filter(|c| *c == '长')
                .count(),
            EXCERPT_CHARS
        );
    }
}
