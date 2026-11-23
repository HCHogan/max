//! A merged forward in Max's form. QQ sends no messages for it, only a
//! transcript it writes itself, which qqbot reads (`qqbot::transcript`).
//! Here it becomes a line for the forward and one for each of its
//! messages, a nickname and what it said. A message's later lines are
//! indented under it, as are the messages of a forward it holds. Its
//! pictures, videos and files become media nodes, downloaded as any
//! attachment is, while QQ's links still work.
//!
//! ```text
//! [forward: 群聊的聊天记录, 3 条]
//! 小明: 看这个
//!   第二行 [image#9.0]
//! 小红: [reply: 看这个] 好家伙
//! 小明: [forward: 群聊的聊天记录, 1 条]
//!   小刚: 早
//! ```

use max_core::message::{MediaKind, MediaMeta, MediaRef, Node};
use qqbot::transcript::{Entry, FileKind, Kind, Transcript};

use super::{content_nodes, plain};
use max::inbound::InNode;

/// How much of a quoted message's text its `[reply: …]` shows.
const QUOTE_CHARS: usize = 40;

/// The forward's nodes.
pub(super) fn nodes(forward: &Transcript) -> Vec<InNode> {
    let mut out = Out::default();
    out.text(&heading(forward));
    for entry in &forward.messages {
        out.entry(entry, 0);
    }
    out.nodes
}

/// `[forward: 群聊的聊天记录, 3 条]`, without the count when QQ left the
/// messages out.
fn heading(forward: &Transcript) -> String {
    let title = forward.title.as_deref().unwrap_or("聊天记录");
    match forward.messages.len() {
        0 => format!("[forward: {title}]"),
        n => format!("[forward: {title}, {n} 条]"),
    }
}

/// Nodes being written, adjacent text joined.
#[derive(Default)]
struct Out {
    nodes: Vec<InNode>,
}

impl Out {
    fn text(&mut self, text: &str) {
        if let Some(InNode::Node(Node::Text { text: last })) = self.nodes.last_mut() {
            last.push_str(text);
        } else if !text.is_empty() {
            self.nodes
                .push(InNode::Node(Node::Text { text: text.into() }));
        }
    }

    fn push(&mut self, node: InNode) {
        match node {
            InNode::Node(Node::Text { text }) => self.text(&text),
            node => self.nodes.push(node),
        }
    }

    /// A message on a line of its own, `depth` levels in.
    fn entry(&mut self, entry: &Entry, depth: usize) {
        let indent = "  ".repeat(depth);
        let sender = entry.sender.as_deref().unwrap_or("某人");
        self.text(&format!("\n{indent}{sender}:"));
        if let Some(quoted) = &entry.quoted {
            self.text(&format!(" [reply: {}]", quote(quoted)));
        }
        if let Some(text) = entry.text.as_deref().filter(|text| !text.is_empty()) {
            self.text(" ");
            let text = text.replace('\n', &format!("\n{indent}  "));
            for node in content_nodes(&text, None) {
                self.push(node);
            }
        }
        if let Kind::Forward(forward) = &entry.kind {
            self.text(&format!(" {}", heading(forward)));
        }
        for file in &entry.files {
            self.text(" ");
            self.push(InNode::Node(Node::Media {
                media: file.url.clone().map(MediaRef::Remote),
                meta: MediaMeta {
                    kind: match file.kind {
                        FileKind::Picture | FileKind::Animated => MediaKind::Image,
                        FileKind::Video => MediaKind::Video,
                        FileKind::Voice => MediaKind::Audio,
                        FileKind::File | FileKind::Other(_) => MediaKind::File,
                    },
                    mime: None,
                    size: None,
                    name: file.name.clone(),
                    description: None,
                },
            }));
        }
        if let Kind::Forward(forward) = &entry.kind {
            for held in &forward.messages {
                self.entry(held, depth + 1);
            }
        }
    }
}

/// A quoted message's text on one line, shortened, without its faces.
fn quote(entry: &Entry) -> String {
    let text = plain(entry.text.as_deref().unwrap_or_default());
    let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    match text.char_indices().nth(QUOTE_CHARS) {
        Some((end, _)) => format!("{}…", &text[..end]),
        None => text,
    }
}
