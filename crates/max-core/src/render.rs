//! How timeline rows look to the model: one line each,
//! `[HH:MM 名字 #id]: 内容`, with a date line when the day changes and a gap
//! line after a long silence. The tail, `[新消息]` blocks, intent and
//! `history` all render rows with this, so a row reads the same
//! everywhere.
//!
//! Placeholders follow the one grammar the segmenter parses: `[word#id]`,
//! optionally `: description`. A medium's id is its handle, the message's
//! id and which medium of it, from 0: `[image#103.0: 一只猫]`. Forms
//! without an id (`[face: 吃瓜]`) are for reading only, as is a medium's in
//! the text stored for search; the segmenter drops them when the model
//! echoes one.

use std::collections::BTreeMap;
use std::time::Duration;

use chrono::{DateTime, Datelike, FixedOffset, TimeDelta, Utc, Weekday};

use crate::ids::{IdentityId, MessageId, PrincipalId};
use crate::message::{Card, Content, MediaKind, MediaMeta, MentionTarget, Message, Node};

/// A silence at least this long gets a gap line.
const GAP: TimeDelta = TimeDelta::hours(1);

/// Characters of an over-long row the model sees before reaching for
/// `history`.
pub const EXCERPT_CHARS: usize = 2000;

/// How a line names a person, up to their number: `[mention#12]`.
const MENTION: &str = "[mention#";

/// A person named in a rendered line, or in text that copies one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Mention {
    /// Where the marker starts.
    pub start: usize,
    /// Where its number ends: at the `]`, when the marker is whole.
    pub end: usize,
    pub principal: PrincipalId,
}

/// The markers in `text`, in order, closed or not: `[mention#` and a
/// number. The segmenter reads what the model writes by a grammar of its
/// own, in `segment::chunk`, which `verify/` proves things of.
pub fn mentions(text: &str) -> impl Iterator<Item = Mention> + '_ {
    text.match_indices(MENTION)
        .filter_map(move |(start, marker)| {
            let number = start + marker.len();
            let rest = &text[number..];
            let digits = rest
                .find(|c: char| !c.is_ascii_digit())
                .unwrap_or(rest.len());
            Some(Mention {
                start,
                end: number + digits,
                principal: PrincipalId::new(rest[..digits].parse().ok()?),
            })
        })
}

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
    /// A tool called from the group's VM said it: a program Max keeps
    /// there, or a turn's own, which the host doesn't tell apart.
    Program,
    /// maxx said it on Max's account: a command's answer, or a notice
    /// that a trigger went unanswered.
    Host,
}

#[derive(Debug)]
pub struct Render<'a, P> {
    pub people: &'a P,
    /// Local time, for HH:MM and dates.
    pub offset: FixedOffset,
}

impl<P: People> Render<'_, P> {
    /// Rows' lines, already rendered, in order. `after` is when the row
    /// before them was sent, if one was already shown, so a date line
    /// appears only when the day changes; a gap line follows a long
    /// silence.
    #[must_use]
    pub fn joined(&self, lines: &[(&Message, String)], mut after: Option<DateTime<Utc>>) -> String {
        let mut out = String::new();
        for (message, line) in lines {
            if let Some(separator) = self.separator(after, message.at) {
                out.push_str(&separator);
                out.push('\n');
            }
            out.push_str(line);
            out.push('\n');
            after = Some(message.at);
        }
        out
    }

    /// The line before a row sent `at`: a date line when the day changes
    /// since `after`, a gap line after a long silence, otherwise none.
    #[must_use]
    pub fn separator(&self, after: Option<DateTime<Utc>>, at: DateTime<Utc>) -> Option<String> {
        let local = at.with_timezone(&self.offset);
        match after.map(|at| at.with_timezone(&self.offset)) {
            Some(before) if before.date_naive() == local.date_naive() => {
                let gap = at - before.to_utc();
                (gap >= GAP).then(|| format!("--- 过了 {} 小时 ---", gap.num_hours()))
            }
            _ => {
                let date = local.date_naive();
                Some(format!("--- {date} {} ---", weekday(date.weekday())))
            }
        }
    }

    #[must_use]
    pub fn line(&self, message: &Message, mark: Mark) -> String {
        let content = self.content_of(Some(message.id), &message.content);
        self.header(message, mark) + &content + suffix(mark)
    }

    /// The line cut to [`EXCERPT_CHARS`], pointing at the full text.
    #[must_use]
    pub fn excerpt(&self, message: &Message, mark: Mark) -> String {
        let content: String = self
            .content_of(Some(message.id), &message.content)
            .chars()
            .take(EXCERPT_CHARS)
            .collect();
        format!(
            "{}{content}…（太长，全文见 #{}，用 history 读）{}",
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
            Mark::Program => " 程序发的",
            Mark::Host => " 系统发的",
            _ => "",
        };
        format!("[{time} {name} #{}{note}]: ", message.id)
    }

    /// A row's content on one line, for search: line breaks become ` ⏎ `,
    /// and media have no handles, since the row has no id yet.
    #[must_use]
    pub fn content(&self, content: &Content) -> String {
        self.content_of(None, content)
    }

    /// A stored row's content, as its line shows it after the header.
    #[must_use]
    pub fn body(&self, message: &Message) -> String {
        self.content_of(Some(message.id), &message.content)
    }

    fn content_of(&self, id: Option<MessageId>, content: &Content) -> String {
        let text = match content {
            Content::Message { reply_to, nodes } => {
                reply_to
                    .map(|id| format!("[reply#{id}] "))
                    .unwrap_or_default()
                    + &self.nodes(id, nodes)
            }
            Content::Edit { target, nodes } => {
                format!("[edit#{target}] {}", self.nodes(id, nodes))
            }
            Content::Unsend { target } => format!("[unsend#{target}]"),
        };
        text.trim().replace("\r\n", "\n").replace('\n', " ⏎ ")
    }

    fn nodes(&self, id: Option<MessageId>, nodes: &[Node]) -> String {
        let mut ordinal = 0;
        let mut out = String::new();
        for node in nodes {
            match node {
                Node::Media { meta, .. } => {
                    out += &medium(id.map(|id| (id, ordinal)), meta);
                    ordinal += 1;
                }
                node => out += &self.node(node),
            }
        }
        out
    }

    fn node(&self, node: &Node) -> String {
        match node {
            Node::Text { text } => text.clone(),
            Node::Mention {
                target: MentionTarget::Identity(identity),
                display,
            } => match self.people.principal(*identity) {
                Some(principal) => format!("{MENTION}{principal}]"),
                None => format!("@{display}"),
            },
            Node::Mention {
                target: MentionTarget::All,
                display,
            } => format!("@{display}"),
            // Max can't send faces, so the model gets no id to copy.
            Node::Emote(emote) => labelled("face", emote.name.as_deref()),
            Node::Media { meta, .. } => medium(None, meta),
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

/// A medium, with its handle when the row has an id.
fn medium(handle: Option<(MessageId, u16)>, meta: &MediaMeta) -> String {
    let word = meta.kind.as_str();
    let word = match handle {
        Some((id, ordinal)) => format!("{word}#{id}.{ordinal}"),
        None => word.to_owned(),
    };
    // A picture's or a recording's file name is a hash QQ made up; a
    // file's is what it is.
    let label = match meta.kind {
        MediaKind::File => meta.description.as_deref().or(meta.name.as_deref()),
        _ => meta.description.as_deref(),
    };
    labelled(&word, label)
}

fn labelled(word: &str, label: Option<&str>) -> String {
    match label {
        Some(label) => format!("[{word}: {label}]"),
        None => format!("[{word}]"),
    }
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

/// `2026-10-03 周六 14:02`, in local time.
#[must_use]
pub fn moment(at: DateTime<Utc>, offset: FixedOffset) -> String {
    let local = at.with_timezone(&offset);
    let date = local.date_naive();
    format!(
        "{date} {} {}",
        weekday(date.weekday()),
        local.format("%H:%M")
    )
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

/// A span of time, as the prompt and the notices say it: `两小时`, or
/// `90 分钟`.
#[must_use]
pub fn span(time: Duration) -> String {
    let minutes = time.as_secs() / 60;
    match minutes {
        120 => "两小时".to_owned(),
        _ if minutes > 0 && minutes.is_multiple_of(60) => format!("{} 小时", minutes / 60),
        _ => format!("{minutes} 分钟"),
    }
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone;
    use serde_json::Value;

    use super::*;
    use crate::ids::{ConversationId, MessageId};
    use crate::message::{Emote, ForwardRef, MediaMeta, Platform, Role, Sender, Unsupported};

    fn people() -> BTreeMap<IdentityId, PrincipalId> {
        [
            (IdentityId::new(1), PrincipalId::new(1)),
            (IdentityId::new(20), PrincipalId::new(12)),
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
            id: MessageId::new(id),
            conversation: ConversationId::new(1),
            sender: Sender {
                identity: IdentityId::new(20),
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
                        target: MentionTarget::Identity(IdentityId::new(1)),
                        display: "Max".into(),
                    },
                    text(" 第一行\n第二行 "),
                    Node::Mention {
                        target: MentionTarget::Identity(IdentityId::new(99)),
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
                    reply_to: Some(MessageId::new(101)),
                    nodes: vec![
                        text("在"),
                        Node::Emote(Emote {
                            platform: Platform::Qq,
                            id: "271".into(),
                            name: Some("吃瓜".into()),
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
                ]),
            ),
            message(
                104,
                (28, 4, 31),
                "小明",
                Content::Edit {
                    target: MessageId::new(103),
                    nodes: vec![text("改了")],
                },
            ),
            message(
                105,
                (28, 4, 31),
                "小明",
                Content::Unsend {
                    target: MessageId::new(103),
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
        let render = render(&people);
        let lines: Vec<_> = rows
            .iter()
            .zip(marks)
            .map(|(row, mark)| (row, render.line(row, mark)))
            .collect();
        insta::assert_snapshot!(render.joined(&lines, None));
    }
}
