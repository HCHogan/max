//! The segmenter: the only place where model text becomes messages, for
//! replies and progress narration alike. In the Haskell version every
//! sender that kept its own copy of "turn text into messages" ended up
//! leaking a raw `[split]` or `[reply#id]` into the group.
//!
//! Text is cut into chunks, one message each, at blank lines and at
//! `[split]`, never inside a code fence or an inline code span (Max writes
//! a placeholder there to show it, as on 10-30 `[mention#830]`, which went
//! out as a real @ and showed QQ's tag with the openid in it); a picture's
//! handle is a chunk of
//! its own, as QQ sends a picture on its own. The cuts depend only on the text,
//! not on how it arrived: streamed in any pieces, it gives the same chunks
//! as all at once. (The Haskell version also released long paragraphs at
//! sentence ends while streaming, which made the result depend on timing.)
//!
//! Once a line is a Markdown heading, the reply has turned into a document
//! and is sent by sections: a heading starts a message, and blank lines no
//! longer cut, so a section goes out whole, as QQ renders it. A thematic
//! break (`---`) cuts wherever it is and is never sent. On 10-30 a long
//! answer went out as a heading, a table and an empty-looking `---`, each
//! a message of its own. A line that starts with a quote, `[reply#id]`,
//! starts a message, and ends the document: Max is back to chatting. From
//! 11-02 to 11-04, three times a jab at someone written after a document's
//! last section went out inside that section, and so the whole section as
//! a reply to them.
//!
//! `<think>` spans are dropped before anything else, including everything
//! after an unclosed one: some relays put reasoning in the text.
//!
//! The chunker and the placeholders it looks for are in `chunk`, written
//! so that Aeneas can translate them to Lean, where `verify/` proves what
//! they do.

mod chunk;
mod parse;

use std::collections::BTreeSet;

use crate::ids::PrincipalId;
use crate::message::Draft;

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

/// Cuts streamed text into chunks: `chunk::Chunker`, over `str`.
#[derive(Debug, Default)]
pub struct Chunker(chunk::Chunker);

impl Chunker {
    /// Feeds more text; returns the chunks it completed.
    pub fn push(&mut self, delta: &str) -> Vec<String> {
        let mut out = Vec::new();
        self.0.push(delta.as_bytes(), &mut out);
        texts(out)
    }

    /// The end of the text; returns the remaining chunks. An unclosed fence
    /// runs to the end, so it comes out as one chunk.
    pub fn finish(mut self) -> Vec<String> {
        let mut out = Vec::new();
        self.0.finish(&mut out);
        texts(out)
    }
}

/// Chunks of UTF-8 are UTF-8: see `chunk`.
fn texts(chunks: Vec<Vec<u8>>) -> Vec<String> {
    chunks
        .into_iter()
        .map(|chunk| {
            String::from_utf8(chunk)
                .unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned())
        })
        .collect()
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
    fn a_document_goes_by_sections() {
        let text = "[reply#3] 先说结论：\n\n两样都行。\n\n---\n\n### 一、对比\n\n| 工具 | 用法 |\n| --- | --- |\n| nvd | diff |\n\n表格说明。\n\n\n### 二、列表\n1. 第一\n\n   - 细节\n2. 第二\n***\n收尾[split]另一条";
        assert_eq!(
            chunks(text),
            [
                "[reply#3] 先说结论：",
                "两样都行。",
                "### 一、对比\n\n| 工具 | 用法 |\n| --- | --- |\n| nvd | diff |\n\n表格说明。",
                "### 二、列表\n1. 第一\n\n   - 细节\n2. 第二",
                "收尾",
                "另一条"
            ]
        );
        // Not headings, or not breaks: cut at blank lines as before.
        assert_eq!(
            chunks("#123 呢\n\n#\n\n--\n\n- - x"),
            ["#123 呢", "#", "--", "- - x"]
        );
        assert_eq!(chunks("```\n---\n# 注释\n```"), ["```\n---\n# 注释\n```"]);
    }

    #[test]
    fn a_quote_starts_a_message_and_ends_the_document() {
        let text = "### 总结\n两样都行。\n\n[reply#7] 至于你，先去睡觉。\n\n别熬夜了。\n\n## 附录\n甲\n\n乙\n  [reply#8] 丙";
        assert_eq!(
            chunks(text),
            [
                "### 总结\n两样都行。",
                "[reply#7] 至于你，先去睡觉。",
                "别熬夜了。",
                "## 附录\n甲\n\n乙",
                "[reply#8] 丙"
            ]
        );
        // Without a document, a quote still starts a message, but only at
        // the start of a line, and only a real one.
        assert_eq!(chunks("一\n[reply#3] 二"), ["一", "[reply#3] 二"]);
        assert_eq!(chunks("一\n好[reply#3] 二"), ["一\n好[reply#3] 二"]);
        assert_eq!(chunks("一\n[reply#] 二"), ["一\n[reply#] 二"]);
        assert_eq!(
            chunks("```\n一\n[reply#3]\n```"),
            ["```\n一\n[reply#3]\n```"]
        );

        let mut segmenter = Segmenter::new(BTreeSet::new());
        let mut out = segmenter.push("### 总结\n两样都行。\n\n[reply#7] 至于你");
        out.extend(segmenter.finish());
        let quoted: Vec<_> = out.iter().map(|s| s.draft.reply_to).collect();
        assert_eq!(quoted, [None, Some(crate::ids::MessageId(7))]);
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
    fn code_spans_are_not_cut() {
        let text = "写 `[split]` 才分条，`[sticker#4.0]` 是表情包[split]完";
        assert_eq!(
            chunks(text),
            ["写 `[split]` 才分条，`[sticker#4.0]` 是表情包", "完"]
        );
        // Unclosed, or closed by a longer run: plain backticks.
        assert_eq!(chunks("`a``[split]b"), ["`a``", "b"]);
        assert_eq!(chunk::code_spans(b"``a`b`` `c`"), [(0, 7), (8, 11)]);
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
        let text = "<think>想\n\n想</think>开头\n\n```py\nx = 1\n\ny = 2\n```\n中间[split]后面[sticker#4.0: 狗]\n\n\n结尾\n---\n## 一\n\n甲\n\n### 二\n乙\n\n[reply#9] 回来\n\n聊天";
        let whole = chunks(text);
        assert_eq!(
            whole[whole.len() - 3..],
            ["### 二\n乙", "[reply#9] 回来", "聊天"]
        );
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
