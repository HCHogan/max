//! What maxx tells Max: notices only the model reads, each the item of a
//! wake and never a row of the timeline. A program's wake, which is how a
//! background command and a background agent say they ended, a word about
//! the VM, and why the classifier woke Max. How each is worded is here,
//! in one place; the prompt and the tools' guides describe them. The run's own two
//! reminders are in max-core, with the run.

use std::borrow::Cow;

use max_core::item::{Item, ItemKind};
use max_core::render::EXCERPT_CHARS;

use crate::tokens;

pub(super) enum Notice<'a> {
    /// The classifier judged that Max should join in, and why.
    Judged { note: &'a str },
    /// A program in the group's VM ran `maxx wake`, the hour's `count`th.
    Woken { text: &'a str, count: usize },
    /// The VM service, on the group's VM.
    Vm { text: &'a str },
}

impl Notice<'_> {
    /// What Max is shown. A part that takes over `single` tokens shows
    /// its beginning.
    pub(super) fn item(&self, single: u32) -> Item {
        let text = self.text(single);
        let tokens = tokens::count(&text);
        Item::new(ItemKind::user(text), tokens)
    }

    /// Its words. A part that takes over `single` tokens shows its
    /// beginning.
    pub(super) fn text(&self, single: u32) -> String {
        match *self {
            Notice::Judged { note } => format!("[判定：{note}]"),
            // The count once there has been more than one this hour.
            Notice::Woken { text, count } => {
                let text = fitted(text.trim(), single);
                match count {
                    0 | 1 => format!("[max-wake] {text}"),
                    _ => format!("[max-wake] （这一小时第 {count} 次）{text}"),
                }
            }
            Notice::Vm { text } => format!("[VM] {text}"),
        }
    }
}

/// `words`, or their beginning, saying so, if they take over `single`
/// tokens.
fn fitted(words: &str, single: u32) -> Cow<'_, str> {
    if tokens::count(words) <= single {
        return words.into();
    }
    let end = words
        .char_indices()
        .nth(EXCERPT_CHARS)
        .map_or(words.len(), |(at, _)| at);
    format!("{}…（太长，只有开头）", &words[..end]).into()
}
