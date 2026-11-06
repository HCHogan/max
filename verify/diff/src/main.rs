//! Runs `max_core::segment::Chunker` and the Lean model on the same random
//! texts and compares their chunks. The Rust gets each text in random
//! pieces; the model gets it whole, which the model's `streaming` theorem
//! says is the same.
//!
//! `cargo run --release -- [texts] [seed]`, after `lake build` in `verify/`.

use std::fmt::Write as _;
use std::io::Write as _;
use std::process::{Command, Stdio};

use max_core::segment::Chunker;

/// What texts are made of: the markers the chunker looks for, pieces of
/// them, and the whitespace `trim` and `is_whitespace` see.
const TOKENS: &[&str] = &[
    "\n",
    "\n",
    "\n",
    "\n",
    "\r",
    "\r\n",
    " ",
    "  ",
    "\t",
    "\u{3000}",
    "\u{a0}",
    "\u{2028}",
    "一",
    "好",
    "a",
    "x",
    "`",
    "``",
    "```",
    "```rust",
    "  ```",
    "[split]",
    "[spl",
    "it]",
    "<think>",
    "</think>",
    "<th",
    "ink>",
    "# ",
    "## ",
    "###### ",
    "####### ",
    "#",
    "#\t",
    "---",
    "***",
    "___",
    "- - -",
    "-",
    "--",
    "[reply#3]",
    "[reply#",
    "3]",
    "[reply#3: 小明]",
    "[reply#3](x)",
    "[mention#12]",
    "[mention#12: 小明]",
    "[sticker#4.0]",
    "[sticker#4.70000]",
    "[image#5.0: 猫](3秒)",
    "[image#5.0](",
    "[image#5]",
    "[image#5.]",
    "[file#6.1]",
    "[video#7.0]",
    "[sticker#99999999999999999999.0]",
    "[face: 吃瓜]",
    "[unsend#7]",
    "[12:30 小明 #5]: ",
    "[",
    "]",
    "(",
    ")",
    ":",
    "#",
    ".",
    "0",
    "9",
    "=",
    "|",
    "1. ",
    "> ",
    "[silence]",
];

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().fold(String::new(), |mut s, b| {
        let _ = write!(s, "{b:02x}");
        s
    })
}

fn unhex(s: &str) -> String {
    let bytes = (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).expect("hex"))
        .collect();
    String::from_utf8(bytes).expect("UTF-8")
}

fn rust_chunks(text: &str, cuts: &[usize]) -> Vec<String> {
    let mut chunker = Chunker::default();
    let mut out = Vec::new();
    let mut from = 0;
    for &at in cuts {
        out.extend(chunker.push(&text[from..at]));
        from = at;
    }
    out.extend(chunker.push(&text[from..]));
    out.extend(chunker.finish());
    out
}

fn main() {
    let mut args = std::env::args().skip(1);
    let count: usize = args.next().map_or(100_000, |a| a.parse().expect("count"));
    let seed: u64 = args
        .next()
        .map_or(0x9e37_79b9_7f4a_7c15, |a| a.parse().expect("seed"));
    let model = concat!(env!("CARGO_MANIFEST_DIR"), "/../.lake/build/bin/chunker");

    let mut rng = Rng(seed.max(1));
    let texts: Vec<String> = (0..count)
        .map(|_| {
            let len = 1 + rng.below(60);
            (0..len).map(|_| TOKENS[rng.below(TOKENS.len())]).collect()
        })
        .collect();

    let mut child = Command::new(model)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap_or_else(|e| panic!("{model}: {e}; run `lake build` in verify/ first"));
    let mut stdin = child.stdin.take().expect("stdin");
    let input: String = texts.iter().map(|t| hex(t.as_bytes()) + "\n").collect();
    let writer = std::thread::spawn(move || stdin.write_all(input.as_bytes()));
    let output = child.wait_with_output().expect("model");
    writer.join().expect("writer").expect("write");
    assert!(output.status.success(), "the model failed");
    let lines: Vec<&str> = std::str::from_utf8(&output.stdout)
        .expect("UTF-8")
        .lines()
        .collect();
    assert_eq!(lines.len(), texts.len(), "one line per text");

    let mut differences = 0;
    for (text, line) in texts.iter().zip(&lines) {
        let model: Vec<String> = line
            .split(' ')
            .filter(|c| !c.is_empty())
            .map(unhex)
            .collect();
        let bounds: Vec<usize> = text.char_indices().map(|(at, _)| at).collect();
        let mut cuts: Vec<usize> = (0..rng.below(5))
            .map(|_| bounds[rng.below(bounds.len())])
            .collect();
        cuts.sort_unstable();
        let rust = rust_chunks(text, &cuts);
        if rust != model {
            differences += 1;
            if differences <= 5 {
                println!("text  {text:?}\ncuts  {cuts:?}\nrust  {rust:?}\nmodel {model:?}\n");
            }
        }
    }
    println!("{count} texts, seed {seed}: {differences} differences");
    if differences > 0 {
        std::process::exit(1);
    }
}
