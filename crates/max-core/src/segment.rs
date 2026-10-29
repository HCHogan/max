//! The segmenter: the only place where model text becomes messages, for
//! replies and progress narration alike. In the Haskell version every
//! sender that kept its own copy of "turn text into messages" ended up
//! leaking a raw `[split]` or `[reply#id]` into the group.
//!
//! Text is cut into chunks, one message each, at blank lines and at
//! `[split]`, never inside a code fence; a picture's handle is a chunk of
//! its own, as QQ sends a picture on its own. The cuts depend only on the text,
//! not on how it arrived: streamed in any pieces, it gives the same chunks
//! as all at once. (The Haskell version also released long paragraphs at
//! sentence ends while streaming, which made the result depend on timing.)
//!
//! `<think>` spans are dropped before anything else, including everything
//! after an unclosed one: some relays put reasoning in the text.

mod parse;

use std::collections::BTreeSet;

use crate::ids::PrincipalId;
use crate::message::Draft;

const SPLIT: &str = "[split]";

/// One message's worth of model output.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Segment {
    /// The chunk as the model wrote it. When a model call is cut off, the
    /// sources of the segments that went out are what Max said.
    pub source: String,
    pub draft: Draft,
}

/// Streamed model text in, messages to say out.
#[derive(Debug)]
pub struct Segmenter {
    chunker: Chunker,
    /// The people in the roster the model was shown. A handle outside it is
    /// made up and doesn't become a real mention.
    known: BTreeSet<PrincipalId>,
}

impl Segmenter {
    pub fn new(known: BTreeSet<PrincipalId>) -> Self {
        Self {
            chunker: Chunker::default(),
            known,
        }
    }

    pub fn push(&mut self, delta: &str) -> Vec<Segment> {
        let chunks = self.chunker.push(delta);
        self.parse(chunks)
    }

    pub fn finish(mut self) -> Vec<Segment> {
        let chunks = std::mem::take(&mut self.chunker).finish();
        self.parse(chunks)
    }

    fn parse(&self, chunks: Vec<String>) -> Vec<Segment> {
        chunks
            .into_iter()
            .filter_map(|source| {
                let draft = parse::parse(&source, &self.known)?;
                Some(Segment { source, draft })
            })
            .collect()
    }
}

/// Cuts streamed text into chunks.
#[derive(Debug, Default)]
pub struct Chunker {
    /// Text after the last newline.
    partial: String,
    /// The complete lines of the chunk being built.
    lines: Vec<String>,
    in_fence: bool,
    thinking: bool,
}

impl Chunker {
    /// Feeds more text; returns the chunks it completed.
    pub fn push(&mut self, delta: &str) -> Vec<String> {
        let mut out = Vec::new();
        self.partial.push_str(delta);
        while let Some(end) = self.partial.find('\n') {
            let line: String = self.partial.drain(..=end).collect();
            self.line(line.trim_end_matches(['\n', '\r']), &mut out);
        }
        out
    }

    /// The end of the text; returns the remaining chunks. An unclosed fence
    /// runs to the end, so it comes out as one chunk.
    pub fn finish(mut self) -> Vec<String> {
        let mut out = Vec::new();
        let rest = std::mem::take(&mut self.partial);
        if !rest.is_empty() {
            self.line(&rest, &mut out);
        }
        self.cut(&mut out);
        out
    }

    fn line(&mut self, line: &str, out: &mut Vec<String>) {
        let Some(line) = self.unthink(line) else {
            return;
        };
        let line = line.as_str();
        if is_fence(line) {
            self.in_fence = !self.in_fence;
            self.lines.push(line.to_owned());
        } else if self.in_fence {
            self.lines.push(line.to_owned());
        } else if line.trim().is_empty() {
            self.cut(out);
        } else {
            let mut rest = line;
            while let Some((at, len, picture)) = next_cut(rest) {
                self.lines.push(rest[..at].to_owned());
                self.cut(out);
                if picture {
                    self.lines.push(rest[at..at + len].to_owned());
                    self.cut(out);
                }
                rest = &rest[at + len..];
            }
            self.lines.push(rest.to_owned());
        }
    }

    /// The part of a line outside `<think>` spans; None for a line wholly
    /// inside one.
    fn unthink(&mut self, line: &str) -> Option<String> {
        const OPEN: &str = "<think>";
        const CLOSE: &str = "</think>";
        if !self.thinking && !line.contains(OPEN) {
            return Some(line.to_owned());
        }
        let mut visible = String::new();
        let mut tagged = false;
        let mut rest = line;
        loop {
            let tag = if self.thinking { CLOSE } else { OPEN };
            let Some(at) = rest.find(tag) else {
                if !self.thinking {
                    visible.push_str(rest);
                }
                break;
            };
            if !self.thinking {
                visible.push_str(&rest[..at]);
            }
            rest = &rest[at + tag.len()..];
            self.thinking = !self.thinking;
            tagged = true;
        }
        (tagged || !self.thinking).then_some(visible)
    }

    fn cut(&mut self, out: &mut Vec<String>) {
        let text = self.lines.join("\n");
        self.lines.clear();
        let text = text.trim();
        if !text.is_empty() {
            out.push(text.to_owned());
        }
    }
}

pub(crate) fn is_fence(line: &str) -> bool {
    line.trim_start().starts_with("```")
}

/// The next cut in a line outside a fence: where, how long, and whether
/// it is a picture's handle rather than a `[split]`.
fn next_cut(line: &str) -> Option<(usize, usize, bool)> {
    let split = line.find(SPLIT).map(|at| (at, SPLIT.len(), false));
    let picture = line
        .match_indices('[')
        .find_map(|(at, _)| Some((at, parse::picture(&line[at..])?, true)));
    split.into_iter().chain(picture).min()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chunks(text: &str) -> Vec<String> {
        let mut chunker = Chunker::default();
        let mut out = chunker.push(text);
        out.extend(chunker.finish());
        out
    }

    #[test]
    fn blank_lines_cut() {
        assert_eq!(
            chunks("一\n\n二\n第二行\n\n\n三\n"),
            ["一", "二\n第二行", "三"]
        );
        assert_eq!(chunks("  \n\n  "), Vec::<String>::new());
    }

    #[test]
    fn split_cuts_anywhere_on_a_line() {
        assert_eq!(chunks("一[split]二\n三[split]"), ["一", "二\n三"]);
        assert_eq!(chunks("[split][split]一[split]  [split]二"), ["一", "二"]);
    }

    #[test]
    fn pictures_are_chunks_of_their_own() {
        let text = "看这个[image#5.0: 一只猫](3秒)好笑吧\n[sticker#6.1]\n[video#7.0] 呢";
        assert_eq!(
            chunks(text),
            [
                "看这个",
                "[image#5.0: 一只猫](3秒)",
                "好笑吧",
                "[sticker#6.1]",
                "[video#7.0] 呢"
            ]
        );
        assert_eq!(
            chunks("```\n[sticker#6.1]\n```"),
            ["```\n[sticker#6.1]\n```"]
        );
        assert_eq!(chunks("[image#5] [split]x"), ["[image#5]", "x"]);
    }

    #[test]
    fn fences_are_not_cut() {
        let text = "看：\n```rust\nfn a() {}\n\nfn b() {} // [split]\n```\n\n完";
        assert_eq!(
            chunks(text),
            [
                "看：\n```rust\nfn a() {}\n\nfn b() {} // [split]\n```",
                "完"
            ]
        );
    }

    #[test]
    fn an_unclosed_fence_runs_to_the_end() {
        assert_eq!(chunks("一\n\n```\na\n\nb"), ["一", "```\na\n\nb"]);
    }

    #[test]
    fn think_spans_go() {
        assert_eq!(
            chunks("<think>嗯\n\n想想</think>好的\n\n二"),
            ["好的", "二"]
        );
        assert_eq!(
            chunks("一<think>x</think>二<think>y</think>\n三"),
            ["一二\n三"]
        );
        assert_eq!(chunks("答案\n\n<think>没想完\n\n还在想"), ["答案"]);
    }

    #[test]
    fn crlf() {
        assert_eq!(chunks("一\r\n\r\n二\r\n"), ["一", "二"]);
    }

    /// Streaming in any two pieces gives the same chunks as all at once.
    #[test]
    fn streaming_is_invisible() {
        let text = "<think>想\n\n想</think>开头\n\n```py\nx = 1\n\ny = 2\n```\n中间[split]后面[sticker#4.0: 狗]\n\n\n结尾";
        let whole = chunks(text);
        for (at, _) in text.char_indices() {
            let mut chunker = Chunker::default();
            let mut out = chunker.push(&text[..at]);
            out.extend(chunker.push(&text[at..]));
            out.extend(chunker.finish());
            assert_eq!(out, whole, "split at byte {at}");
        }
        let mut chunker = Chunker::default();
        let mut out = Vec::new();
        for c in text.chars() {
            out.extend(chunker.push(c.encode_utf8(&mut [0; 4])));
        }
        out.extend(chunker.finish());
        assert_eq!(out, whole, "one char at a time");
    }

    #[test]
    fn segmenter() {
        use crate::ids::MessageId;
        use crate::message::DraftNode;

        let mut segmenter = Segmenter::new([PrincipalId(12)].into());
        let mut out =
            segmenter.push("[reply#3] 第一条\n\n[silence]\n\n[mention#12] 第二[sticker#4.0]");
        out.extend(segmenter.finish());
        let sources: Vec<_> = out.iter().map(|s| s.source.as_str()).collect();
        assert_eq!(
            sources,
            ["[reply#3] 第一条", "[mention#12] 第二", "[sticker#4.0]"]
        );
        let picture = DraftNode::Picture {
            message: MessageId(4),
            ordinal: 0,
        };
        assert_eq!(out[2].draft.nodes, [picture]);
        assert_eq!(
            out[0].draft,
            Draft {
                reply_to: Some(MessageId(3)),
                nodes: vec![DraftNode::Text {
                    text: "第一条".into()
                }],
            }
        );
    }

    /// A chunk is released as soon as the blank line after it arrives.
    #[test]
    fn chunks_come_out_early() {
        let mut chunker = Chunker::default();
        assert!(chunker.push("一\n").is_empty());
        assert_eq!(chunker.push("\n二"), ["一"]);
        assert!(chunker.push("[spl").is_empty());
        assert!(chunker.push("it]三").is_empty());
        assert_eq!(chunker.push("\n"), ["二"]);
        assert_eq!(chunker.finish(), ["三"]);
    }
}
