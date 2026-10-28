//! The segmenter: the only place where model text becomes messages, for
//! replies and progress narration alike. In the Haskell version every
//! sender that kept its own copy of "turn text into messages" ended up
//! leaking a raw `[split]` or `[reply#id]` into the group.
//!
//! Text is cut into chunks, one message each, at blank lines and at
//! `[split]`, never inside a code fence. The cuts depend only on the text,
//! not on how it arrived: streamed in any pieces, it gives the same chunks
//! as all at once. (The Haskell version also released long paragraphs at
//! sentence ends while streaming, which made the result depend on timing.)

const SPLIT: &str = "[split]";

/// Cuts streamed text into chunks.
#[derive(Debug, Default)]
pub struct Chunker {
    /// Text after the last newline.
    partial: String,
    /// The complete lines of the chunk being built.
    lines: Vec<String>,
    in_fence: bool,
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
        if is_fence(line) {
            self.in_fence = !self.in_fence;
            self.lines.push(line.to_owned());
        } else if self.in_fence {
            self.lines.push(line.to_owned());
        } else if line.trim().is_empty() {
            self.cut(out);
        } else if line.contains(SPLIT) {
            let mut pieces = line.split(SPLIT);
            if let Some(first) = pieces.next() {
                self.lines.push(first.to_owned());
            }
            for piece in pieces {
                self.cut(out);
                self.lines.push(piece.to_owned());
            }
        } else {
            self.lines.push(line.to_owned());
        }
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
    fn crlf() {
        assert_eq!(chunks("一\r\n\r\n二\r\n"), ["一", "二"]);
    }

    /// Streaming in any two pieces gives the same chunks as all at once.
    #[test]
    fn streaming_is_invisible() {
        let text = "开头\n\n```py\nx = 1\n\ny = 2\n```\n中间[split]后面\n\n\n结尾";
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
