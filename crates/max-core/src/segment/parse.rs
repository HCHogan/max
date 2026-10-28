//! What one chunk does. Every placeholder is `[word#id]`, optionally with a
//! `: description` and a `(attributes)` group glued on, the way the model
//! sees them in history (`[image#7405.0: 一只猫](29秒)`). Only the id is
//! trusted; the rest is consumed so that an echoed display form acts
//! instead of leaking. Anything that doesn't parse stays text. Code fences
//! are left alone.

use std::collections::BTreeSet;

use super::is_fence;
use crate::faces;
use crate::ids::{FaceId, MessageId, PrincipalId};
use crate::message::{Draft, DraftNode, OutboundMedia};

/// What one chunk of model output does.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    Say(Draft),
    /// `[silence:名字]`: no message, a reaction on `target`, or on the
    /// trigger when there is none.
    React {
        target: Option<MessageId>,
        face: FaceId,
    },
}

pub(super) fn parse(chunk: &str, known: &BTreeSet<PrincipalId>) -> Option<Action> {
    let mut parsed = Parsed::default();
    let mut in_fence = false;
    for (i, line) in chunk.split('\n').enumerate() {
        if i > 0 {
            parsed.text("\n");
        }
        if is_fence(line) {
            in_fence = !in_fence;
            parsed.text(line);
        } else if in_fence {
            parsed.text(line);
        } else {
            parsed.line(line, known);
        }
    }
    parsed.finish()
}

#[derive(Default)]
struct Parsed {
    reply_to: Option<MessageId>,
    nodes: Vec<DraftNode>,
    react: Option<String>,
}

impl Parsed {
    fn line(&mut self, line: &str, known: &BTreeSet<PrincipalId>) {
        let mut rest = line;
        while let Some(open) = rest.find('[') {
            self.text(&rest[..open]);
            rest = &rest[open..];
            match token(rest) {
                Some((token, len)) => {
                    self.apply(token, known);
                    rest = &rest[len..];
                }
                None => {
                    self.text("[");
                    rest = &rest[1..];
                }
            }
        }
        self.text(rest);
    }

    fn apply(&mut self, token: Token<'_>, known: &BTreeSet<PrincipalId>) {
        match token {
            Token::Reply(id) => {
                self.reply_to.get_or_insert(id);
            }
            Token::Mention(principal, _) if known.contains(&principal) => {
                self.nodes.push(DraftNode::Mention { principal });
            }
            Token::Mention(_, name) => {
                if let Some(name) = name {
                    self.text(&format!("@{name}"));
                }
            }
            Token::Face(face) => self.nodes.push(DraftNode::Face { face }),
            Token::Sticker(id) => self.nodes.push(DraftNode::Media {
                media: OutboundMedia::Sticker { id },
            }),
            Token::Image(message, index) => self.nodes.push(DraftNode::Media {
                media: OutboundMedia::Image { message, index },
            }),
            Token::Silence | Token::ToolCall => {}
            Token::SilenceFace(name) => {
                self.react.get_or_insert_with(|| name.to_owned());
            }
        }
    }

    fn text(&mut self, s: &str) {
        if s.is_empty() {
            return;
        }
        if let Some(DraftNode::Text { text }) = self.nodes.last_mut() {
            text.push_str(s);
        } else {
            self.nodes.push(DraftNode::Text { text: s.to_owned() });
        }
    }

    fn finish(mut self) -> Option<Action> {
        if let Some(DraftNode::Text { text }) = self.nodes.first_mut() {
            *text = text.trim_start().to_owned();
        }
        if let Some(DraftNode::Text { text }) = self.nodes.last_mut() {
            *text = text.trim_end().to_owned();
        }
        self.nodes
            .retain(|node| !matches!(node, DraftNode::Text { text } if text.is_empty()));
        if !self.nodes.is_empty() {
            return Some(Action::Say(Draft {
                reply_to: self.reply_to,
                nodes: self.nodes,
            }));
        }
        let face = faces::by_name(self.react.as_deref()?)?;
        Some(Action::React {
            target: self.reply_to,
            face,
        })
    }
}

enum Token<'a> {
    Reply(MessageId),
    /// With the name, if the model wrote `[mention#12: 名字]`.
    Mention(PrincipalId, Option<&'a str>),
    Face(FaceId),
    Sticker(i64),
    Image(MessageId, Option<u32>),
    Silence,
    SilenceFace(&'a str),
    /// A tool call written as text, such as `[find_stickers query="无语"]`.
    ToolCall,
}

/// The token `s` starts with, and its length in bytes.
fn token(s: &str) -> Option<(Token<'_>, usize)> {
    if s.starts_with("[silence]") {
        return Some((Token::Silence, "[silence]".len()));
    }
    if let Some(rest) = s.strip_prefix("[silence:") {
        let end = rest.find(']')?;
        let name = rest[..end].trim();
        return (!name.is_empty())
            .then_some((Token::SilenceFace(name), "[silence:".len() + end + 1));
    }
    placeholder(s).or_else(|| tool_call(s).map(|len| (Token::ToolCall, len)))
}

fn placeholder(s: &str) -> Option<(Token<'_>, usize)> {
    let body = s.strip_prefix('[')?;
    let hash = body.find('#')?;
    let (verb, rest) = (&body[..hash], &body[hash + 1..]);
    let (id, mut at) = digits(rest)?;
    let mut index = None;
    if verb == "image" && rest[at..].starts_with('.') {
        let (n, len) = digits(&rest[at + 1..])?;
        index = Some(u32::try_from(n).ok()?);
        at += 1 + len;
    }
    let (description, len) = closer(&rest[at..])?;
    let token = match verb {
        "reply" => Token::Reply(MessageId(id)),
        "mention" => Token::Mention(PrincipalId(id), description),
        "face" => Token::Face(FaceId(u32::try_from(id).ok()?)),
        "sticker" => Token::Sticker(id),
        "image" => Token::Image(MessageId(id), index),
        _ => return None,
    };
    Some((token, 1 + hash + 1 + at + len))
}

/// A run of ASCII digits and its length.
fn digits(s: &str) -> Option<(i64, usize)> {
    let len = s.bytes().take_while(u8::is_ascii_digit).count();
    Some((s[..len].parse().ok()?, len))
}

/// `]` or `: description]`, then an optional `(attributes)` group.
fn closer(s: &str) -> Option<(Option<&str>, usize)> {
    let (description, mut len) = if s.starts_with(']') {
        (None, 1)
    } else {
        let rest = s.strip_prefix(':')?;
        let end = rest.find(']')?;
        let description = rest[..end].trim();
        (
            (!description.is_empty()).then_some(description),
            1 + end + 1,
        )
    };
    if s[len..].starts_with('(')
        && let Some(end) = s[len..].find(')')
    {
        len += end + 1;
    }
    Some((description, len))
}

/// `[identifier<space>…]` with a `=` or a quote inside: no placeholder or
/// prose looks like that.
fn tool_call(s: &str) -> Option<usize> {
    let body = s.strip_prefix('[')?;
    let name = body
        .bytes()
        .take_while(|b| b.is_ascii_alphabetic() || *b == b'_')
        .count();
    let end = body.find(']')?;
    let inside = &body[..end];
    let spaced = inside[name..].starts_with(char::is_whitespace);
    let call_like = inside.contains(['=', '"', '“', '”']);
    (name > 0 && spaced && call_like).then_some(1 + end + 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed(chunk: &str) -> Option<Action> {
        parse(chunk, &[PrincipalId(12)].into())
    }

    fn say(chunk: &str) -> Draft {
        match parsed(chunk) {
            Some(Action::Say(draft)) => draft,
            other => panic!("{chunk:?} gave {other:?}"),
        }
    }

    fn text(s: &str) -> DraftNode {
        DraftNode::Text { text: s.into() }
    }

    #[test]
    fn plain_text_is_trimmed() {
        assert_eq!(
            say("  你好\n  "),
            Draft {
                reply_to: None,
                nodes: vec![text("你好")]
            }
        );
    }

    #[test]
    fn the_first_reply_wins_and_all_go() {
        let draft = say("[reply#7405] 好的 [reply#7406]");
        assert_eq!(draft.reply_to, Some(MessageId(7405)));
        assert_eq!(draft.nodes, vec![text("好的")]);
    }

    #[test]
    fn only_known_people_are_mentioned() {
        let draft = say("[mention#12] 你看 [mention#99: 小红] 和 [mention#98]");
        assert_eq!(
            draft.nodes,
            vec![
                DraftNode::Mention {
                    principal: PrincipalId(12)
                },
                text(" 你看 @小红 和")
            ]
        );
    }

    #[test]
    fn echoed_display_forms_act() {
        let draft = say("[face#271: 吃瓜][image#7405.1: 一只猫](3秒)[sticker#42: 柴犬]");
        assert_eq!(
            draft.nodes,
            vec![
                DraftNode::Face { face: FaceId(271) },
                DraftNode::Media {
                    media: OutboundMedia::Image {
                        message: MessageId(7405),
                        index: Some(1)
                    }
                },
                DraftNode::Media {
                    media: OutboundMedia::Sticker { id: 42 }
                },
            ]
        );
    }

    #[test]
    fn malformed_placeholders_stay_text() {
        let chunk = "[reply#abc] [face#] [image#5.] [mention#12 [unknown#3] [] [reply#1";
        assert_eq!(say(chunk).nodes, vec![text(chunk)]);
    }

    #[test]
    fn silence() {
        assert_eq!(parsed("[silence]"), None);
        assert_eq!(parsed("[reply#5]  [silence]"), None);
        assert_eq!(parsed("[silence:没有这个]"), None);
        assert_eq!(
            parsed("[reply#5] [silence:吃瓜]"),
            Some(Action::React {
                target: Some(MessageId(5)),
                face: FaceId(271)
            })
        );
        assert_eq!(
            parsed("[silence: 吃瓜 ]"),
            Some(Action::React {
                target: None,
                face: FaceId(271)
            })
        );
        assert_eq!(
            say("好 [silence] 的 [silence:吃瓜]").nodes,
            vec![text("好  的")]
        );
    }

    #[test]
    fn tool_calls_written_as_text_go() {
        assert_eq!(
            say("好的[find_stickers query=\"无语\"]").nodes,
            vec![text("好的")]
        );
        assert_eq!(
            say("[look up=“x”] 数组 [a b]").nodes,
            vec![text("数组 [a b]")]
        );
    }

    #[test]
    fn fences_are_left_alone() {
        let chunk = "看：\n```\nlet a = v[reply#3];\n[f x=\"1\"] [silence]\n```";
        assert_eq!(
            say(chunk),
            Draft {
                reply_to: None,
                nodes: vec![text(chunk)]
            }
        );
    }
}
