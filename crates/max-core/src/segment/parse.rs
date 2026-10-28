//! What one chunk does. Every placeholder is `[word#id]`, optionally with a
//! `: description` and a `(attributes)` group glued on, the way the model
//! sees them in history (`[mention#12: 小明]`). Only the id is trusted; the
//! rest is consumed so that an echoed display form acts instead of leaking.
//! Max writes quotes and mentions; forms that are only for reading
//! (`[face: 吃瓜]`, `[unsend#7405]`, `[image#7405.0]` from old summaries)
//! are dropped when echoed, and so is a copied row header. Anything else
//! that doesn't parse stays text. Code fences are left alone.

use std::collections::BTreeSet;

use super::is_fence;
use crate::ids::{MessageId, PrincipalId};
use crate::message::{Draft, DraftNode};

/// The message one chunk of model output says, if any.
pub(super) fn parse(chunk: &str, known: &BTreeSet<PrincipalId>) -> Option<Draft> {
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
            let line = if i == 0 { without_header(line) } else { line };
            parsed.line(&restore_breaks(line), known);
        }
    }
    parsed.finish()
}

/// History shows a line break inside a row as ` ⏎ `, and models copy it.
fn restore_breaks(line: &str) -> String {
    let pieces: Vec<&str> = line.split('⏎').collect();
    let last = pieces.len() - 1;
    let trimmed: Vec<&str> = pieces
        .iter()
        .enumerate()
        .map(|(i, piece)| {
            let piece = if i > 0 {
                piece.trim_start_matches([' ', '\t'])
            } else {
                piece
            };
            if i < last {
                piece.trim_end_matches([' ', '\t'])
            } else {
                piece
            }
        })
        .collect();
    trimmed.join("\n")
}

/// The line without a row header, `[HH:MM 名字 #id]: `, copied from history.
fn without_header(line: &str) -> &str {
    let Some(close) = line.find("]: ") else {
        return line;
    };
    let header = line.as_bytes();
    let clock = header.len() > 7
        && header[0] == b'['
        && header[1..3].iter().all(u8::is_ascii_digit)
        && header[3] == b':'
        && header[4..6].iter().all(u8::is_ascii_digit)
        && header[6] == b' ';
    if clock && line[..close].contains(" #") {
        &line[close + "]: ".len()..]
    } else {
        line
    }
}

#[derive(Default)]
struct Parsed {
    reply_to: Option<MessageId>,
    nodes: Vec<DraftNode>,
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
            Token::Silence | Token::Display | Token::ToolCall => {}
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

    fn finish(mut self) -> Option<Draft> {
        if let Some(DraftNode::Text { text }) = self.nodes.first_mut() {
            *text = text.trim_start().to_owned();
        }
        if let Some(DraftNode::Text { text }) = self.nodes.last_mut() {
            *text = text.trim_end().to_owned();
        }
        self.nodes
            .retain(|node| !matches!(node, DraftNode::Text { text } if text.is_empty()));
        (!self.nodes.is_empty()).then_some(Draft {
            reply_to: self.reply_to,
            nodes: self.nodes,
        })
    }
}

enum Token<'a> {
    Reply(MessageId),
    /// With the name, if the model wrote `[mention#12: 名字]`.
    Mention(PrincipalId, Option<&'a str>),
    /// `[silence]`, or `[silence:名字]`, which used to react with a face.
    Silence,
    /// A form that is only for reading.
    Display,
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
        return Some((Token::Silence, "[silence:".len() + end + 1));
    }
    placeholder(s)
        .or_else(|| display(s).map(|len| (Token::Display, len)))
        .or_else(|| tool_call(s).map(|len| (Token::ToolCall, len)))
}

fn placeholder(s: &str) -> Option<(Token<'_>, usize)> {
    let body = s.strip_prefix('[')?;
    let hash = body.find('#')?;
    let (verb, rest) = (&body[..hash], &body[hash + 1..]);
    let (id, mut at) = digits(rest)?;
    if verb == "image" && rest[at..].starts_with('.') {
        let (_, len) = digits(&rest[at + 1..])?;
        at += 1 + len;
    }
    let (description, len) = closer(&rest[at..])?;
    let token = match verb {
        "reply" => Token::Reply(MessageId(id)),
        "mention" => Token::Mention(PrincipalId(id), description),
        "face" | "sticker" | "image" => Token::Display,
        _ => return None,
    };
    Some((token, 1 + hash + 1 + at + len))
}

/// An event placeholder or an id-less form; see `render`. Reactions and
/// pokes are no longer rendered, but old summaries still show them.
fn display(s: &str) -> Option<usize> {
    const EVENTS: &[&str] = &["edit", "unsend", "react", "unreact", "poke"];
    const BARE: &[&str] = &[
        "image", "sticker", "video", "audio", "file", "forward", "card", "face", "emote", "poke",
    ];
    let body = s.strip_prefix('[')?;
    let word_len = body.bytes().take_while(u8::is_ascii_lowercase).count();
    let (word, rest) = body.split_at(word_len);
    if let Some(id) = rest.strip_prefix('#') {
        let (_, id_len) = digits(id)?;
        let (_, len) = closer(&id[id_len..])?;
        EVENTS
            .contains(&word)
            .then_some(1 + word_len + 1 + id_len + len)
    } else {
        let (_, len) = closer(rest)?;
        BARE.contains(&word).then_some(1 + word_len + len)
    }
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

    fn parsed(chunk: &str) -> Option<Draft> {
        parse(chunk, &[PrincipalId(12)].into())
    }

    fn say(chunk: &str) -> Draft {
        parsed(chunk).unwrap_or_else(|| panic!("{chunk:?} said nothing"))
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
    fn faces_and_media_max_cant_send_go() {
        let draft =
            say("好[face#271: 吃瓜][image#7405.1: 一只猫](3秒)[sticker#42: 柴犬][face: 吃瓜]");
        assert_eq!(draft.nodes, vec![text("好")]);
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
        assert_eq!(parsed("[reply#5] [silence:吃瓜]"), None);
        assert_eq!(parsed("[silence:]"), None);
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
    fn echoes_of_history() {
        assert_eq!(
            say("第一行 ⏎ 第二行⏎第三行").nodes,
            vec![text("第一行\n第二行\n第三行")]
        );
        let draft = say("[09:03 Max #102 回复你]: [reply#101] 在");
        assert_eq!(
            (draft.reply_to, draft.nodes),
            (Some(MessageId(101)), vec![text("在")])
        );
        assert_eq!(say("[09:03] 说: 好").nodes, vec![text("[09:03] 说: 好")]);
        let echoed = "看[image: 一只猫][sticker] [unsend#3][react#2: 托腮][card: a | b][poke]图";
        assert_eq!(say(echoed).nodes, vec![text("看 图")]);
        assert_eq!(
            say("[edit] [video#3]").nodes,
            vec![text("[edit] [video#3]")]
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
