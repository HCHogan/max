//! The chunker, over UTF-8 bytes. It is written in the part of Rust that
//! Aeneas translates to Lean, so that what it does can be proven there:
//! loops over indices with flags rather than `break`, no closures or
//! iterator adapters, no `str` methods, byte strings written where they are
//! used rather than as constants, and no `?`, `RangeInclusive::contains`
//! or derived `Default`, which Aeneas leaves as axioms.
//!
//! Every position it cuts at is next to an ASCII marker or a whole
//! whitespace character, so the pieces of UTF-8 it cuts are UTF-8.

#![expect(
    clippy::question_mark,
    clippy::manual_range_contains,
    clippy::derivable_impls,
    reason = "Aeneas translates `?`, `RangeInclusive::contains` and a derived `Default` to axioms"
)]

/// Whether `pat` is in `s` at `at`.
fn starts_at(s: &[u8], at: usize, pat: &[u8]) -> bool {
    if at > s.len() || s.len() - at < pat.len() {
        return false;
    }
    let mut i = 0;
    let mut same = true;
    while same && i < pat.len() {
        same = s[at + i] == pat[i];
        i += 1;
    }
    same
}

/// `s[from..].find(pat)`, as a position in `s`.
fn find(s: &[u8], from: usize, pat: &[u8]) -> Option<usize> {
    let mut i = from;
    let mut found = false;
    while !found && i < s.len() {
        if starts_at(s, i, pat) {
            found = true;
        } else {
            i += 1;
        }
    }
    if found { Some(i) } else { None }
}

/// Whether `s[from..to]` is `word`.
fn is_word(s: &[u8], from: usize, to: usize, word: &[u8]) -> bool {
    to - from == word.len() && starts_at(s, from, word)
}

fn is_ascii_space(b: u8) -> bool {
    (0x09 <= b && b <= 0x0d) || b == 0x20
}

/// Whether three bytes are a whitespace character: U+1680, U+2000 to
/// U+200A, U+2028, U+2029, U+202F, U+205F or U+3000.
fn is_wide_space(b: u8, c: u8, d: u8) -> bool {
    (b == 0xe1 && c == 0x9a && d == 0x80)
        || (b == 0xe2
            && c == 0x80
            && ((0x80 <= d && d <= 0x8a) || d == 0xa8 || d == 0xa9 || d == 0xaf))
        || (b == 0xe2 && c == 0x81 && d == 0x9f)
        || (b == 0xe3 && c == 0x80 && d == 0x80)
}

/// The length of the whitespace character at `i`, or 0. Whitespace is
/// `char::is_whitespace`'s, Unicode's `White_Space`.
fn space_at(s: &[u8], i: usize) -> usize {
    if i >= s.len() {
        return 0;
    }
    let b = s[i];
    if is_ascii_space(b) {
        return 1;
    }
    if b == 0xc2 && i + 1 < s.len() && (s[i + 1] == 0x85 || s[i + 1] == 0xa0) {
        return 2;
    }
    if i + 2 < s.len() && is_wide_space(b, s[i + 1], s[i + 2]) {
        return 3;
    }
    0
}

/// The length of the whitespace character that ends at `j`, or 0.
fn space_before(s: &[u8], j: usize) -> usize {
    if j == 0 || j > s.len() {
        return 0;
    }
    let b = s[j - 1];
    if is_ascii_space(b) {
        return 1;
    }
    if j >= 2 && s[j - 2] == 0xc2 && (b == 0x85 || b == 0xa0) {
        return 2;
    }
    if j >= 3 && is_wide_space(s[j - 3], s[j - 2], b) {
        return 3;
    }
    0
}

/// `s[from..].trim_start()`, as a position in `s`.
fn skip_space(s: &[u8], from: usize) -> usize {
    let mut a = from;
    let mut moving = true;
    while moving && a < s.len() {
        let n = space_at(s, a);
        if n == 0 {
            moving = false;
        } else {
            a += n;
        }
    }
    a
}

/// `s[from..to].trim()`, as positions in `s`.
fn trim(s: &[u8], from: usize, to: usize) -> (usize, usize) {
    let mut a = from;
    let mut moving = true;
    while moving && a < to {
        let n = space_at(s, a);
        if n == 0 {
            moving = false;
        } else {
            a += n;
        }
    }
    let mut b = to;
    moving = true;
    while moving && b > a {
        let n = space_before(s, b);
        if n == 0 {
            moving = false;
        } else {
            b -= n;
        }
    }
    (a, b)
}

/// Whether `s[from..to]` is all whitespace.
fn is_blank(s: &[u8], from: usize, to: usize) -> bool {
    let (a, b) = trim(s, from, to);
    a == b
}

// Placeholders.

/// What a placeholder is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Kind {
    Reply,
    Mention,
    /// A picture's or a sticker's handle, which Max can send.
    Picture,
    /// A form that is only for reading.
    Display,
}

/// `[word#id]`, optionally with a `: description` and a `(attributes)`
/// group glued on.
pub(super) struct Placeholder {
    pub(super) kind: Kind,
    pub(super) id: i64,
    /// A picture's place in its message, after the id: `[image#id.0]`.
    pub(super) ordinal: u16,
    /// Where the description is, untrimmed: from after the `:` to the `]`.
    pub(super) description: (usize, usize),
    pub(super) len: usize,
}

/// The run of ASCII digits at `at`, if it fits an `i64`: its value and
/// length.
pub(super) fn digits(s: &[u8], at: usize) -> Option<(i64, usize)> {
    /// `i64::MAX` is this and 7.
    const TENTH: i64 = 922_337_203_685_477_580;
    let mut n = 0;
    let mut len = 0;
    let mut fits = true;
    while at + len < s.len() && b'0' <= s[at + len] && s[at + len] <= b'9' {
        let d = (s[at + len] - b'0') as i64;
        if fits {
            if n > TENTH || (n == TENTH && d > 7) {
                fits = false;
            } else {
                n = n * 10 + d;
            }
        }
        len += 1;
    }
    if len == 0 || !fits {
        None
    } else {
        Some((n, len))
    }
}

/// `]` or `: description]` at `at`, then an optional `(attributes)` group:
/// where the `]` is, and where the group ends.
pub(super) fn closer(s: &[u8], at: usize) -> Option<(usize, usize)> {
    if at >= s.len() {
        return None;
    }
    let mut close = at;
    if s[at] == b':' {
        let Some(end) = find(s, at + 1, b"]") else {
            return None;
        };
        close = end;
    } else if s[at] != b']' {
        return None;
    }
    let mut end = close + 1;
    if end < s.len()
        && s[end] == b'('
        && let Some(paren) = find(s, end, b")")
    {
        end = paren + 1;
    }
    Some((close, end))
}

fn is_medium(s: &[u8], from: usize, to: usize) -> bool {
    is_word(s, from, to, b"image")
        || is_word(s, from, to, b"sticker")
        || is_word(s, from, to, b"video")
        || is_word(s, from, to, b"audio")
        || is_word(s, from, to, b"file")
}

/// The placeholder at `at`, if one is there.
pub(super) fn placeholder(s: &[u8], at: usize) -> Option<Placeholder> {
    if at >= s.len() || s[at] != b'[' {
        return None;
    }
    let body = at + 1;
    let Some(hash) = find(s, body, b"#") else {
        return None;
    };
    let Some((id, n)) = digits(s, hash + 1) else {
        return None;
    };
    let medium = is_medium(s, body, hash);
    let mut pos = hash + 1 + n;
    let mut ordinal = 0;
    let mut has_ordinal = false;
    if medium && pos < s.len() && s[pos] == b'.' {
        let Some((k, len)) = digits(s, pos + 1) else {
            return None;
        };
        if k <= 0xffff {
            #[expect(
                clippy::cast_possible_truncation,
                clippy::cast_sign_loss,
                reason = "it is from 0 to 0xffff"
            )]
            let small = k as u16;
            ordinal = small;
            has_ordinal = true;
        }
        pos = pos + 1 + len;
    }
    let Some((close, end)) = closer(s, pos) else {
        return None;
    };
    let kind = if is_word(s, body, hash, b"reply") {
        Kind::Reply
    } else if is_word(s, body, hash, b"mention") {
        Kind::Mention
    } else if (is_word(s, body, hash, b"image") || is_word(s, body, hash, b"sticker"))
        && has_ordinal
    {
        Kind::Picture
    } else if is_word(s, body, hash, b"face") || medium {
        Kind::Display
    } else {
        return None;
    };
    let description = if s[pos] == b':' {
        (pos + 1, close)
    } else {
        (close, close)
    };
    Some(Placeholder {
        kind,
        id,
        ordinal,
        description,
        len: end - at,
    })
}

/// The length of the quote, `[reply#id]`, at `at`, if one is there.
fn quote(s: &[u8], at: usize) -> Option<usize> {
    match placeholder(s, at) {
        Some(Placeholder {
            kind: Kind::Reply,
            len,
            ..
        }) => Some(len),
        _ => None,
    }
}

/// The length of the picture's handle at `at`, if one is there.
fn picture(s: &[u8], at: usize) -> Option<usize> {
    match placeholder(s, at) {
        Some(Placeholder {
            kind: Kind::Picture,
            len,
            ..
        }) => Some(len),
        _ => None,
    }
}

// Lines.

/// Three backticks or more, after any whitespace.
pub(super) fn is_fence(line: &[u8]) -> bool {
    ticks_at(line, skip_space(line, 0)) >= 3
}

/// `### 标题`: one to six `#`, a space, then something.
fn is_heading(line: &[u8]) -> bool {
    let mut marks = 0;
    while marks < line.len() && line[marks] == b'#' {
        marks += 1;
    }
    if marks < 1 || marks > 6 || marks >= line.len() {
        return false;
    }
    (line[marks] == b' ' || line[marks] == b'\t') && !is_blank(line, marks, line.len())
}

/// `---`, `***`, `___`, spaces allowed between.
fn is_break(line: &[u8]) -> bool {
    let mut i = 0;
    let mut count = 0;
    let mut first = 0;
    let mut same = true;
    while i < line.len() {
        let n = space_at(line, i);
        if n > 0 {
            i += n;
        } else {
            if count == 0 {
                first = line[i];
            } else if line[i] != first {
                same = false;
            }
            count += 1;
            i += 1;
        }
    }
    count >= 3 && same && (first == b'-' || first == b'*' || first == b'_')
}

/// The length of the run of backticks at `at`.
fn ticks_at(s: &[u8], at: usize) -> usize {
    let mut n = 0;
    while at + n < s.len() && s[at + n] == b'`' {
        n += 1;
    }
    n
}

/// Where a run of `ticks` backticks closes, looking from `from`: the end of
/// the next run of exactly as many.
fn closing(s: &[u8], ticks: usize, from: usize) -> Option<usize> {
    let mut j = from;
    let mut found = false;
    let mut end = 0;
    while !found && j < s.len() {
        if s[j] == b'`' {
            let n = ticks_at(s, j);
            if n == ticks {
                found = true;
                end = j + n;
            } else {
                j += n;
            }
        } else {
            j += 1;
        }
    }
    if found { Some(end) } else { None }
}

/// The inline code spans in a line, backticks included: a run of backticks
/// up to the next run of as many, as in CommonMark. What is in one is shown
/// as written.
pub(super) fn code_spans(s: &[u8]) -> Vec<(usize, usize)> {
    let mut spans = Vec::new();
    let mut i = 0;
    while i < s.len() {
        if s[i] == b'`' {
            let ticks = ticks_at(s, i);
            match closing(s, ticks, i + ticks) {
                Some(end) => {
                    spans.push((i, end));
                    i = end;
                }
                None => i += ticks,
            }
        } else {
            i += 1;
        }
    }
    spans
}

fn outside(spans: &[(usize, usize)], at: usize) -> bool {
    let mut i = 0;
    let mut out = true;
    while out && i < spans.len() {
        let (a, b) = spans[i];
        out = !(a <= at && at < b);
        i += 1;
    }
    out
}

/// The next cut in a line outside a fence and its code spans: where, how
/// long, and whether it is a picture's handle rather than a `[split]`.
fn next_cut(line: &[u8]) -> Option<(usize, usize, bool)> {
    let spans = code_spans(line);
    let mut split = 0;
    let mut has_split = false;
    while !has_split && split < line.len() {
        if starts_at(line, split, b"[split]") && outside(&spans, split) {
            has_split = true;
        } else {
            split += 1;
        }
    }
    let mut pic = 0;
    let mut pic_len = 0;
    let mut has_pic = false;
    while !has_pic && pic < line.len() {
        let found = if line[pic] == b'[' && outside(&spans, pic) {
            picture(line, pic)
        } else {
            None
        };
        match found {
            Some(len) => {
                has_pic = true;
                pic_len = len;
            }
            None => pic += 1,
        }
    }
    if has_pic && (!has_split || pic < split) {
        Some((pic, pic_len, true))
    } else if has_split {
        Some((split, 7, false))
    } else {
        None
    }
}

/// Cuts streamed text into chunks.
#[derive(Debug)]
pub(super) struct Chunker {
    /// Text after the last newline.
    partial: Vec<u8>,
    /// The complete lines of the chunk being built.
    lines: Vec<Vec<u8>>,
    in_fence: bool,
    thinking: bool,
    /// A heading came: cut at headings, not at blank lines.
    sections: bool,
}

impl Default for Chunker {
    fn default() -> Self {
        Self {
            partial: Vec::new(),
            lines: Vec::new(),
            in_fence: false,
            thinking: false,
            sections: false,
        }
    }
}

impl Chunker {
    /// Feeds more text; the chunks it completes go to `out`.
    pub(super) fn push(&mut self, delta: &[u8], out: &mut Vec<Vec<u8>>) {
        let mut i = 0;
        while i < delta.len() {
            if delta[i] == b'\n' {
                let line = self.take_line();
                out.extend_from_slice(&self.line(&line));
            } else {
                self.partial.push(delta[i]);
            }
            i += 1;
        }
    }

    /// The end of the text; the remaining chunks go to `out`. An unclosed
    /// fence runs to the end, so it comes out as one chunk.
    pub(super) fn finish(&mut self, out: &mut Vec<Vec<u8>>) {
        let mut chunks = Vec::new();
        if !self.partial.is_empty() {
            let mut rest = Vec::new();
            rest.extend_from_slice(&self.partial);
            self.partial = Vec::new();
            chunks = self.line(&rest);
        }
        self.cut(&mut chunks);
        out.extend_from_slice(&chunks);
    }

    /// The line in `partial`, without the `\r`s it ends with.
    fn take_line(&mut self) -> Vec<u8> {
        let mut end = self.partial.len();
        while end > 0 && self.partial[end - 1] == b'\r' {
            end -= 1;
        }
        let mut line = Vec::new();
        line.extend_from_slice(&self.partial[..end]);
        self.partial = Vec::new();
        line
    }

    /// The chunks a line completes. `push` and `finish` copy them into the
    /// caller's `out`, which nothing else touches, so `verify/` can prove
    /// that the chunker only appends to it. They copy, as Aeneas doesn't
    /// know `Vec::append`.
    fn line(&mut self, raw: &[u8]) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        if let Some(line) = self.unthink(raw) {
            self.classify(&line, &mut out);
        }
        out
    }

    fn classify(&mut self, line: &[u8], out: &mut Vec<Vec<u8>>) {
        if self.in_fence {
            if is_fence(line) {
                self.in_fence = false;
            }
            self.push_line(line);
        } else {
            let mut start = 0;
            let mut done = false;
            while !done {
                match self.message_line(&line[start..], out) {
                    Some(end) => start += end,
                    None => done = true,
                }
            }
        }
    }

    /// A line outside a fence, up to the first `[split]` or picture's
    /// handle in it. Either starts a message, and QQ shows what follows it
    /// as the start of one, so that is judged as a line of its own: where
    /// it starts, if there is one.
    fn message_line(&mut self, line: &[u8], out: &mut Vec<Vec<u8>>) -> Option<usize> {
        // A quote that starts a line starts a message too. QQ shows it as a
        // reply and what follows it as the start of the text, which is
        // what is a fence, a heading or a break.
        let at = skip_space(line, 0);
        let mut shown = 0;
        if let Some(len) = quote(line, at) {
            self.cut(out);
            self.sections = false;
            shown = skip_space(line, at + len);
        }
        let text = &line[shown..];
        if is_fence(text) {
            self.in_fence = true;
            self.push_line(line);
            None
        } else if is_break(text) {
            self.cut(out);
            None
        } else if is_blank(line, 0, line.len()) {
            if !self.sections {
                self.cut(out);
            } else if self.last_nonempty() {
                self.lines.push(Vec::new());
            }
            None
        } else {
            if is_heading(text) {
                self.cut(out);
                self.sections = true;
            }
            match next_cut(line) {
                None => {
                    self.push_line(line);
                    None
                }
                Some((at, len, pic)) => {
                    self.push_line(&line[..at]);
                    self.cut(out);
                    if pic {
                        self.push_line(&line[at..at + len]);
                        self.cut(out);
                    }
                    Some(at + len)
                }
            }
        }
    }

    /// The part of a line outside `<think>` spans; None for a line wholly
    /// inside one.
    fn unthink(&mut self, line: &[u8]) -> Option<Vec<u8>> {
        let mut visible = Vec::new();
        if !self.thinking && find(line, 0, b"<think>").is_none() {
            visible.extend_from_slice(line);
            return Some(visible);
        }
        let mut tagged = false;
        let mut at = 0;
        let mut done = false;
        while !done {
            let found = if self.thinking {
                find(line, at, b"</think>")
            } else {
                find(line, at, b"<think>")
            };
            match found {
                None => {
                    if !self.thinking {
                        visible.extend_from_slice(&line[at..]);
                    }
                    done = true;
                }
                Some(p) => {
                    if !self.thinking {
                        visible.extend_from_slice(&line[at..p]);
                    }
                    at = p + if self.thinking { 8 } else { 7 };
                    self.thinking = !self.thinking;
                    tagged = true;
                }
            }
        }
        if tagged || !self.thinking {
            Some(visible)
        } else {
            None
        }
    }

    fn last_nonempty(&self) -> bool {
        let n = self.lines.len();
        n > 0 && !self.lines[n - 1].is_empty()
    }

    fn push_line(&mut self, line: &[u8]) {
        let mut copy = Vec::new();
        copy.extend_from_slice(line);
        self.lines.push(copy);
    }

    fn cut(&mut self, out: &mut Vec<Vec<u8>>) {
        let mut text = Vec::new();
        let mut i = 0;
        while i < self.lines.len() {
            if i > 0 {
                text.push(b'\n');
            }
            text.extend_from_slice(&self.lines[i]);
            i += 1;
        }
        self.lines = Vec::new();
        let (a, b) = trim(&text, 0, text.len());
        if a < b {
            let mut chunk = Vec::new();
            chunk.extend_from_slice(&text[a..b]);
            out.push(chunk);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn whitespace_is_unicodes() {
        let mut buf = [0; 4];
        for c in (0..=0x10_ffff).filter_map(char::from_u32) {
            let s = c.encode_utf8(&mut buf).as_bytes();
            let len = if c.is_whitespace() { s.len() } else { 0 };
            assert_eq!(
                (space_at(s, 0), space_before(s, s.len())),
                (len, len),
                "{c:?}"
            );
        }
    }

    #[test]
    fn ids_fit_an_i64() {
        assert_eq!(digits(b"9223372036854775807]", 0), Some((i64::MAX, 19)));
        assert_eq!(digits(b"9223372036854775808]", 0), None);
        assert_eq!(digits(b"]", 0), None);
    }

    #[test]
    fn pictures() {
        let handle = "[image#7405.1: 猫]";
        assert_eq!(
            picture(format!("{handle}x").as_bytes(), 0),
            Some(handle.len())
        );
        assert_eq!(picture("[image#7405: 猫]".as_bytes(), 0), None);
        assert_eq!(picture(b"[video#7405.0]", 0), None);
        assert_eq!(picture(b"[image#1.65536]", 0), None);
    }
}
