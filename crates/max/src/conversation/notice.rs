//! What maxx tells Max: notices only the model reads, each the item of a
//! wake and never a row of the timeline. A program's wake, which is how a
//! background command and a background agent say they ended, a word about
//! the VM, a question from another conversation, the answer to one put
//! to another, and why the classifier woke Max. How each is worded is here, in one place; the
//! prompt and the tools' guides describe them. The run's own two
//! reminders are in max-core, with the run.

use std::borrow::Cow;

use max_core::item::{Item, ItemKind};
use max_core::render::EXCERPT_CHARS;
use max_db::links::Peer;

use super::Unanswered;
use crate::tokens;

pub enum Notice<'a> {
    /// The classifier judged that Max should join in, and why.
    Judged { note: &'a str },
    /// A program in the group's VM ran `maxx wake`, the hour's `count`th.
    Woken { text: &'a str, count: usize },
    /// The VM service, on the group's VM.
    Vm { text: &'a str },
    /// Max in another conversation asks Max here: `answer` names
    /// `number` to answer it, while this core runs.
    Asked {
        number: u32,
        from: &'a Peer,
        question: &'a str,
    },
    /// What Max in the conversation `by` said to what Max here asked it,
    /// or why it says nothing: with the question again, since nothing
    /// here kept it, and the core that asked may be gone.
    Answered {
        by: &'a Peer,
        question: &'a str,
        said: &'a Result<String, Unanswered>,
    },
}

impl Notice<'_> {
    /// What Max is shown. A part that takes over `single` tokens shows
    /// its beginning.
    pub fn item(&self, single: u32) -> Item {
        let text = self.text(single);
        let tokens = tokens::count(&text);
        Item::new(ItemKind::user(text), tokens)
    }

    /// Its words. A part that takes over `single` tokens shows its
    /// beginning.
    pub fn text(&self, single: u32) -> String {
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
            Notice::Asked {
                number,
                from,
                question,
            } => {
                format!(
                    "[ask#{number} 问] {from}\n{}\n（那个会话的 Max 问你的：用 answer 回答，to 填 {number}，就在这一轮里答。这一轮结束还没答，它会收到一句没答成，要不要再问由它那边定。这个问题和你的回答都不会发到这边的聊天里）",
                    fitted(question, single),
                )
            }
            Notice::Answered { by, question, said } => {
                let question = fitted(question, single);
                match said {
                    Ok(answer) => format!(
                        "[回答] {by}\n问：{question}\n答：{}",
                        fitted(answer, single)
                    ),
                    Err(why) => format!("[没答成] {by}：{why}\n问：{question}"),
                }
            }
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
