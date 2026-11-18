//! What one chunk does. Every placeholder is `[word#id]`, optionally with a
//! `: description` and a `(attributes)` group glued on, the way the model
//! sees them in history (`[mention#12: 小明]`). Only the id is trusted; the
//! rest is consumed so that an echoed display form acts instead of leaking.
//! Max writes quotes, mentions and pictures (`[sticker#7405.0]`, a chunk
//! of its own); forms that are only for reading (`[face: 吃瓜]`,
//! `[unsend#7405]`, `[video#7405.0]`) are dropped when echoed, and so is
//! a copied row header. Anything else that doesn't parse stays text, and a
//! marker among it whose id isn't one, `[reply#${id}]`, is noted, for a
//! program whose variable wasn't filled in. Code fences and inline code
//! spans are left alone: a placeholder there is Max showing what one looks
//! like.

use std::collections::BTreeSet;

use super::chunk::{self, Kind};
use crate::ids::{MessageId, PrincipalId};
use crate::message::{Draft, DraftNode};

/// The kinds of placeholder whose id Max fills in.
const MARKERS: [&str; 4] = ["reply", "mention", "sticker", "image"];

/// The message one chunk of model output says, if any, and the markers in
/// it whose id isn't one, which it has as text.
pub(super) fn parse(chunk: &str, known: &BTreeSet<PrincipalId>) -> Option<(Draft, Vec<String>)> {
    let mut parsed = Parsed::default();
    let mut in_fence = false;
    for (i, line) in chunk.split('\n').enumerate() {
        if i > 0 {
            parsed.text("\n");
        }
        // QQ shows a quote that starts the chunk as a reply, and what
        // follows it as the start of the text: a fence there opens.
        let line = if i == 0 { parsed.quote(line) } else { line };
        if chunk::is_fence(line.as_bytes()) {
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
    // At the end of a chunk when a picture follows it.
    let Some(close) = line
        .find("]: ")
        .or_else(|| line.strip_suffix("]:").map(str::len))
    else {
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
        line[close + "]:".len()..].trim_start_matches(' ')
    } else {
        line
    }
}

#[derive(Default)]
struct Parsed {
    reply_to: Option<MessageId>,
    nodes: Vec<DraftNode>,
    unfilled: Vec<String>,
}

impl Parsed {
    fn line(&mut self, line: &str, known: &BTreeSet<PrincipalId>) {
        let mut at = 0;
        for (start, end) in chunk::code_spans(line.as_bytes()) {
            self.placeholders(&line[at..start], known);
            self.text(&line[start..end]);
            at = end;
        }
        self.placeholders(&line[at..], known);
    }

    /// The line without the quote it starts with, if any, which the
    /// message replies to.
    fn quote<'a>(&mut self, line: &'a str) -> &'a str {
        let at = line.len() - line.trim_start().len();
        match chunk::placeholder(line.as_bytes(), at) {
            Some(p) if p.kind == Kind::Reply => {
                self.reply_to.get_or_insert(MessageId::new(p.id));
                &line[at + p.len..]
            }
            _ => line,
        }
    }

    fn placeholders(&mut self, line: &str, known: &BTreeSet<PrincipalId>) {
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
                    if let Some(marker) = unfilled(rest) {
                        self.unfilled.push(marker.to_owned());
                    }
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
            Token::Picture(message, ordinal) => {
                self.nodes.push(DraftNode::Picture { message, ordinal });
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

    fn finish(mut self) -> Option<(Draft, Vec<String>)> {
        if let Some(DraftNode::Text { text }) = self.nodes.first_mut() {
            *text = text.trim_start().to_owned();
        }
        if let Some(DraftNode::Text { text }) = self.nodes.last_mut() {
            *text = text.trim_end().to_owned();
        }
        self.nodes
            .retain(|node| !matches!(node, DraftNode::Text { text } if text.is_empty()));
        let draft = Draft {
            reply_to: self.reply_to,
            nodes: self.nodes,
        };
        (!draft.nodes.is_empty()).then_some((draft, self.unfilled))
    }
}

/// The marker `s` starts with, to its `]`, if it is a kind that carries an
/// id but isn't a placeholder: its id is missing or no number, as when a
/// program's variable wasn't filled in.
fn unfilled(s: &str) -> Option<&str> {
    let (word, _) = s.strip_prefix('[')?.split_once('#')?;
    let end = s.find(']')?;
    MARKERS.contains(&word).then(|| &s[..=end])
}

enum Token<'a> {
    Reply(MessageId),
    /// With the name, if the model wrote `[mention#12: 名字]`.
    Mention(PrincipalId, Option<&'a str>),
    /// A picture's or a sticker's handle.
    Picture(MessageId, u16),
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
    let p = chunk::placeholder(s.as_bytes(), 0)?;
    let token = match p.kind {
        Kind::Reply => Token::Reply(MessageId::new(p.id)),
        Kind::Mention => {
            let (from, to) = p.description;
            let description = s[from..to].trim();
            Token::Mention(
                PrincipalId::new(p.id),
                (!description.is_empty()).then_some(description),
            )
        }
        Kind::Picture => Token::Picture(MessageId::new(p.id), p.ordinal),
        Kind::Display => Token::Display,
    };
    Some((token, p.len))
}

/// An event placeholder or an id-less form; see `render`. Reactions and
/// pokes are no longer rendered, but a model may still write one, as old
/// summaries showed them.
fn display(s: &str) -> Option<usize> {
    const EVENTS: &[&str] = &["edit", "unsend", "react", "unreact", "poke"];
    const BARE: &[&str] = &[
        "image", "sticker", "video", "audio", "file", "forward", "card", "face", "emote", "poke",
    ];
    let bytes = s.as_bytes();
    let body = s.strip_prefix('[')?;
    let word_len = body.bytes().take_while(u8::is_ascii_lowercase).count();
    let word = &body[..word_len];
    let at = 1 + word_len;
    if bytes.get(at) == Some(&b'#') {
        let (_, id_len) = chunk::digits(bytes, at + 1)?;
        let (_, end) = chunk::closer(bytes, at + 1 + id_len)?;
        EVENTS.contains(&word).then_some(end)
    } else {
        let (_, end) = chunk::closer(bytes, at)?;
        BARE.contains(&word).then_some(end)
    }
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
        parse(chunk, &[PrincipalId::new(12)].into()).map(|(draft, _)| draft)
    }

    /// The markers in `chunk` whose id isn't one.
    fn unfilled_in(chunk: &str) -> Vec<String> {
        parse(chunk, &[PrincipalId::new(12)].into())
            .map(|(_, unfilled)| unfilled)
            .unwrap_or_default()
    }

    #[test]
    fn a_marker_without_its_id_is_noted() {
        assert_eq!(unfilled_in("[reply#] pong"), ["[reply#]"]);
        assert_eq!(
            unfilled_in("[reply#12] [mention#undefined] 好"),
            ["[mention#undefined]"]
        );
        assert_eq!(unfilled_in("[reply#${id}] 好"), ["[reply#${id}]"]);
        assert_eq!(
            unfilled_in("[image#NaN.0] [sticker#.1]"),
            ["[image#NaN.0]", "[sticker#.1]"]
        );
        assert_eq!(unfilled_in("引用写成 [reply#id]"), ["[reply#id]"]);
        // Still sent as written.
        assert_eq!(say("[reply#] pong").nodes, vec![text("[reply#] pong")]);
    }

    fn say(chunk: &str) -> Draft {
        parsed(chunk).unwrap_or_else(|| panic!("{chunk:?} said nothing"))
    }

    fn text(s: &str) -> DraftNode {
        DraftNode::Text { text: s.into() }
    }

    #[test]
    fn the_first_reply_wins_and_all_go() {
        let draft = say("[reply#7405] 好的 [reply#7406]");
        assert_eq!(draft.reply_to, Some(MessageId::new(7405)));
        assert_eq!(draft.nodes, vec![text("好的")]);
    }

    #[test]
    fn only_known_people_are_mentioned() {
        let draft = say("[mention#12] 你看 [mention#99: 小红] 和 [mention#98]");
        assert_eq!(
            draft.nodes,
            vec![
                DraftNode::Mention {
                    principal: PrincipalId::new(12)
                },
                text(" 你看 @小红 和")
            ]
        );
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
}
