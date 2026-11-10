//! What maxx tells Max: notices only the model reads, each the item of a
//! wake and never a row of the timeline. A job's end, an agent's question,
//! a program's wake, a word about the VM, another conversation's question
//! and its answer, and why the classifier woke Max. How each is worded is
//! here, in one place; the prompt and the tools' guides describe them.
//! The run's own two reminders are in max-core, with the run.

use std::borrow::Cow;
use std::fmt::Write;

use max_core::item::{Item, ItemKind};
use max_core::limits;
use max_core::render::EXCERPT_CHARS;
use max_db::links::Peer;

use crate::job::{self, Finished, How};
use crate::tokens;

pub enum Notice<'a> {
    /// The classifier judged that Max should join in, and why.
    Judged { note: &'a str },
    /// Job `job` ended: how, and the agent's last words or the command's
    /// output; the whole is in its file.
    Ended {
        job: u32,
        title: &'a str,
        finished: &'a Finished,
    },
    /// The agent of job `job` asks Max, and waits for `agent_steer`.
    Asks {
        job: u32,
        title: &'a str,
        question: &'a str,
    },
    /// A program in the group's VM ran `maxx wake`, the hour's `count`th.
    Woken { text: &'a str, count: usize },
    /// The VM service, on the group's VM.
    Vm { text: &'a str },
    /// Max in `from` asks Max here, and waits for `answer` to name
    /// `number`.
    Asked {
        number: u32,
        from: &'a Peer,
        question: &'a str,
    },
    /// The wait of question job `job`, put to `to`, is over: the question
    /// again, since the core that asked may be gone, and the answer or why
    /// there is none.
    Answered {
        job: u32,
        to: &'a Peer,
        question: &'a str,
        answer: &'a Result<String, String>,
    },
}

/// How a question put to Max here is named to it.
pub fn ask_name(number: u32) -> String {
    format!("ask#{number}")
}

impl Notice<'_> {
    /// What Max is shown. A part that takes over `single` tokens shows
    /// its beginning.
    pub fn item(&self, single: u32) -> Item {
        let text = self.text(single);
        let tokens = tokens::count(&text);
        Item::new(ItemKind::user(text), tokens)
    }

    fn text(&self, single: u32) -> String {
        match *self {
            Notice::Judged { note } => format!("[判定：{note}]"),
            Notice::Ended {
                job,
                title,
                finished,
            } => ended(job, title, finished, single),
            Notice::Asks {
                job,
                title,
                question,
            } => format!(
                "[{} 问] {title}\n{}\n（它在等你答复：用 agent_steer 回答它，{} 分钟内没答复它就自己判断）",
                job::name(job),
                fitted(question.trim(), single),
                limits::QUESTION_WAIT.as_secs() / 60,
            ),
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
            } => format!(
                "[{} 问] {from}\n{}\n（那个会话的 Max 在等你回答：用 answer 回答，to 填 {number}；{} 小时内没答它就不等了。这个问题和你的回答都不会发到这边的聊天里）",
                ask_name(number),
                fitted(question, single),
                limits::JOB_TIME.as_secs() / 3600,
            ),
            Notice::Answered {
                job,
                to,
                question,
                answer,
            } => {
                let job = job::name(job);
                let question = fitted(question, single);
                match answer {
                    Ok(answer) => format!(
                        "[{job} 回答] {to}\n问：{question}\n答：{}",
                        fitted(answer, single)
                    ),
                    Err(why) => format!("[{job} 没答成] {to}：{why}\n问：{question}"),
                }
            }
        }
    }
}

fn ended(job: u32, title: &str, finished: &Finished, single: u32) -> String {
    let job = job::name(job);
    let mut text = match &finished.ending.how {
        How::Done => format!("[{job} 完成] {title}"),
        // Whether a command stopped is in its text: the guest may not have
        // said so.
        How::OutOfTime => format!("[{job} 到点了，下面是做到一半的] {title}"),
        How::Failed(why) => format!("[{job} 失败] {title}：{why}"),
    };
    let words = finished.ending.text.as_deref().map(str::trim);
    match words.filter(|words| !words.is_empty()) {
        Some(words) => {
            text.push('\n');
            text.push_str(&fitted(words, single));
        }
        // pi's session is there too, as JSONL.
        None if !matches!(finished.ending.how, How::Failed(_)) => {
            text += "\n（它没留下报告；做的过程在 /work/.max/jobs 里它的会话记录）";
        }
        None => {}
    }
    if let Some(file) = &finished.file {
        let _ = write!(text, "\n（全文在 {file}）");
    }
    match finished.ending.unsent {
        0 => {}
        1 => text += "\n（你最后补充的那条它没收到）",
        unsent => {
            let _ = write!(text, "\n（你最后补充的 {unsent} 条它没收到）");
        }
    }
    text
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
    use crate::job::Ending;

    fn finished(how: How, text: Option<&str>, file: Option<&str>) -> Finished {
        Finished {
            ending: Ending {
                how,
                text: text.map(str::to_owned),
                unsent: 0,
            },
            file: file.map(str::to_owned),
        }
    }

    fn ended(finished: &Finished) -> String {
        let notice = Notice::Ended {
            job: 3,
            title: "查票价",
            finished,
        };
        notice.text(2000)
    }

    #[test]
    fn a_report_says_how_the_job_ended() {
        let done = finished(
            How::Done,
            Some("结论：能。\n"),
            Some("/work/.max/jobs/job-3.md"),
        );
        assert_eq!(
            ended(&done),
            "[job#3 完成] 查票价\n结论：能。\n（全文在 /work/.max/jobs/job-3.md）"
        );
        let half = finished(How::OutOfTime, Some("查了一半"), None);
        assert_eq!(
            ended(&half),
            "[job#3 到点了，下面是做到一半的] 查票价\n查了一半"
        );
        let failed = finished(How::Failed("429".into()), None, None);
        assert_eq!(ended(&failed), "[job#3 失败] 查票价：429");
        let silent = finished(How::Done, Some("  "), None);
        assert_eq!(
            ended(&silent),
            "[job#3 完成] 查票价\n（它没留下报告；做的过程在 /work/.max/jobs 里它的会话记录）"
        );
        let cut = finished(How::OutOfTime, None, None);
        assert!(ended(&cut).ends_with("它的会话记录）"));
        let mut late = finished(How::Done, Some("好了"), None);
        late.ending.unsent = 2;
        assert_eq!(
            ended(&late),
            "[job#3 完成] 查票价\n好了\n（你最后补充的 2 条它没收到）"
        );
    }

    #[test]
    fn a_long_report_shows_its_beginning() {
        let long = "长".repeat(EXCERPT_CHARS * 3);
        let done = finished(How::Done, Some(&long), Some("/work/.max/jobs/job-3.md"));
        let text = ended(&done);
        assert!(text.contains("长…（太长，只有开头）\n（全文在 /work/.max/jobs/job-3.md）"));
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
