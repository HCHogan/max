//! What maxx tells Max: notices only the model reads, each the item of a
//! wake and never a row of the timeline. A program's wake, which is how a
//! background command and a background agent say they ended, a word about
//! the VM, a question from another conversation and its answer, and why
//! the classifier woke Max. How each is worded is here, in one place; the
//! prompt and the tools' guides describe them. The run's own two
//! reminders are in max-core, with the run.

use std::borrow::Cow;

use max_core::ids::Handle;
use max_core::item::{Item, ItemKind};
use max_core::limits;
use max_core::render::EXCERPT_CHARS;
use max_db::links::Peer;

use crate::tokens;

pub enum Notice<'a> {
    /// The classifier judged that Max should join in, and why.
    Judged { note: &'a str },
    /// A program in the group's VM ran `maxx wake`, the hour's `count`th.
    Woken { text: &'a str, count: usize },
    /// The VM service, on the group's VM.
    Vm { text: &'a str },
    /// Max in another conversation asks Max here, and waits for `answer`
    /// to name `number`.
    Asked {
        number: u32,
        from: &'a Peer,
        question: &'a str,
    },
    /// The wait of question `ask`, put to `to`, is over: the question
    /// again, since the core that asked may be gone, and the answer or why
    /// there is none.
    Answered {
        ask: u32,
        to: &'a Peer,
        question: &'a str,
        answer: &'a Result<String, String>,
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
                    "[{} 问] {from}\n{}\n（那个会话的 Max 在等你回答：用 answer 回答，to 填 {number}；{} 小时内没答它就不等了。这个问题和你的回答都不会发到这边的聊天里）",
                    Handle::Ask(number),
                    fitted(question, single),
                    limits::ASK_WAIT.as_secs() / 3600,
                )
            }
            Notice::Answered {
                ask,
                to,
                question,
                answer,
            } => {
                let ask = Handle::Ask(ask);
                let question = fitted(question, single);
                match answer {
                    Ok(answer) => format!(
                        "[{ask} 回答] {to}\n问：{question}\n答：{}",
                        fitted(answer, single)
                    ),
                    Err(why) => format!("[{ask} 没答成] {to}：{why}\n问：{question}"),
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_long_wake_shows_its_beginning() {
        let long = "长".repeat(EXCERPT_CHARS * 3);
        let text = Notice::Woken {
            text: &long,
            count: 1,
        }
        .text(2000);
        assert!(text.ends_with("长…（太长，只有开头）"), "{text}");
        let (excerpt, _) = text.split_once('…').unwrap();
        assert_eq!(
            excerpt.chars().filter(|c| *c == '长').count(),
            EXCERPT_CHARS
        );
    }

    #[test]
    fn the_first_wake_is_shown_as_it_is_and_the_rest_counted() {
        let woken = |text, count| Notice::Woken { text, count }.text(25_000);
        assert_eq!(woken("CI 挂了 2 个\n", 1), "[max-wake] CI 挂了 2 个");
        assert_eq!(woken("又挂了", 37), "[max-wake] （这一小时第 37 次）又挂了");
    }
}
