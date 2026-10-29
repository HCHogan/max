//! The historian's prompt and its answer. The historian hands a model a
//! stretch of the ledger no summary covers yet; the model cuts it into
//! compartments and writes each one once, at three levels. See "historian"
//! and "衰减" in docs/rust-rewrite.md. Everything here is text in, text
//! out: the historian in `max` reads the rows and publishes.

use chrono::FixedOffset;
use serde::Deserialize;

use crate::ids::{MessageId, PrincipalId};
use crate::message::Role;
use crate::project::{Summary, roster_line, span};

/// How many of the latest summaries the model reads first.
pub const EARLIER: usize = 4;

/// What a compartment is about. The Haskell historian's kinds, so the
/// summaries imported from it keep theirs.
pub const KINDS: &[&str] = &[
    "max_interaction",
    "ambient",
    "mixed",
    "decision",
    "support",
    "social",
];

/// The longest each field may be, in characters. Past these the answer is
/// refused rather than cut, as a cut summary reads as a finished one.
pub const TITLE_CHARS: usize = 40;
pub const FULL_CHARS: usize = 4000;
pub const BRIEF_CHARS: usize = 1500;
pub const LINE_CHARS: usize = 150;

pub fn system() -> String {
    format!(
        "你是多人群聊 agent「maxx」的史官。它以前叫 Max，早先的摘要里写的 Max 就是它。给你一段群聊记录，把它切成几段，每段写一份摘要，供 maxx 以后回忆。摘要写一次，以后不再改；原始消息一直留着。

切分：
- 按话题和时间切：话题换了，或者中间隔了很久，就是新的一段。整段记录只聊了一件事，就只切一段。
- 段和段首尾相接，按顺序覆盖全部消息：第一段从第一条消息开始，最后一段到最后一条消息结束，每一段从上一段最后一条的下一条开始。
- first、last 是这一段第一条和最后一条消息的编号，也就是行首方括号里 # 后面的数字。

每段写：
- title：标题，不超过 20 字。
- kind：max_interaction（主要是在和 maxx 说话）、ambient（群友之间聊别的）、mixed（两者都有）、decision（做了决定）、support（求助和解答）、social（寒暄、玩笑、日常）。
- importance：1 到 100，以后还值不值得想起来。日常闲聊 10～30；有信息量的讨论 40～60；决定、约定和重要的事 70 以上。
- p1：完整经过，不超过 {FULL_CHARS} 字：谁说了什么、想做什么、定了什么、答应了什么、还有什么没解决。
- p2：简述，不超过 {BRIEF_CHARS} 字：关键事实、决定和没解决的事，单独读也看得懂。
- p3：一行，不超过 80 字：哪天聊了什么，一看就认得出是哪一段。

要求：
- 用记录里的语言写；人名、日期和术语照抄。
- 提到人用 [mention#12] 这样的写法，号码见\"这段里的人\"；maxx 自己就写 maxx。
- 分清谁说的：别把玩笑、猜测或某个人的说法写成事实。
- p2、p3 是 p1 的压缩，不加 p1 里没有的东西。
- 昨天、下周三这类相对的时间，按记录里的日期换成具体日期。

只输出一个 JSON 对象，不要其他内容：
{{\"compartments\": [{{\"first\": 123, \"last\": 140, \"title\": \"…\", \"kind\": \"social\", \"importance\": 30, \"p1\": \"…\", \"p2\": \"…\", \"p3\": \"…\"}}]}}"
    )
}

/// The model's input. Each argument is rendered already: the time line,
/// the latest summaries (for continuity), the roster of the stretch, and
/// its rows, oldest first.
pub fn user(now: &str, earlier: &str, people: &str, lines: &str) -> String {
    let or_none = |text: &str| {
        if text.trim().is_empty() {
            "（无）".to_string()
        } else {
            text.trim_end().to_string()
        }
    };
    format!(
        "{}\n\n[之前的摘要]\n{}\n\n[这段里的人]\n{}\n\n[聊天记录]\n{}",
        now.trim_end(),
        or_none(earlier),
        or_none(people),
        or_none(lines)
    )
}

/// The latest summaries at their brief level, oldest first: what the
/// stretch follows on from.
pub fn earlier(summaries: &[Summary], offset: FixedOffset) -> String {
    summaries
        .iter()
        .map(|summary| {
            let text = summary.brief.as_deref().unwrap_or(&summary.full);
            format!(
                "[summary#{} {}] {}\n{}",
                summary.id,
                span(summary, offset),
                summary.title,
                text.trim()
            )
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

/// One line of "这段里的人". maxx is marked as maxx, not as "you": the
/// historian isn't maxx.
pub fn person(principal: PrincipalId, name: &str, role: Option<Role>, is_max: bool) -> String {
    if is_max {
        let name = name.replace(['\n', '\r'], " ");
        format!("[mention#{principal}] {name}（就是 maxx）")
    } else {
        roster_line(principal, name, role, false)
    }
}

/// One summary as the model wrote it, checked.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Compartment {
    pub first: MessageId,
    pub last: MessageId,
    pub title: String,
    pub kind: String,
    pub importance: u8,
    pub full: String,
    pub brief: String,
    pub line: String,
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum Invalid {
    #[error("no JSON object of the expected shape: {0}")]
    Shape(String),
    #[error("no compartments")]
    Empty,
    #[error("compartment {index} starts at #{first}, not at #{expected}")]
    Start {
        index: usize,
        first: i64,
        expected: i64,
    },
    #[error(
        "compartment {index} ends at #{last}, which isn't a row of the stretch at or after its start"
    )]
    End { index: usize, last: i64 },
    #[error("the compartments stop at #{last}, short of #{expected}")]
    Short { last: i64, expected: i64 },
    #[error("compartment {index}: kind {kind:?} isn't one of the kinds")]
    Kind { index: usize, kind: String },
    #[error("compartment {index}: importance {importance} isn't 1 to 100")]
    Importance { index: usize, importance: i64 },
    #[error("compartment {index}: {field} is empty or longer than {limit} characters")]
    Length {
        index: usize,
        field: &'static str,
        limit: usize,
    },
}

#[derive(Deserialize)]
struct Answer {
    compartments: Vec<Raw>,
}

#[derive(Deserialize)]
struct Raw {
    first: i64,
    last: i64,
    title: String,
    kind: String,
    importance: i64,
    p1: String,
    p2: String,
    p3: String,
}

/// The answer for the stretch `ids`, oldest first: compartments that
/// follow each other with no gap and cover it all. The first `{` through
/// the last `}` is read, so fences and prose around the object don't
/// matter.
pub fn parse(text: &str, ids: &[MessageId]) -> Result<Vec<Compartment>, Invalid> {
    let object = text
        .find('{')
        .zip(text.rfind('}'))
        .and_then(|(start, end)| text.get(start..=end))
        .ok_or_else(|| Invalid::Shape("no object".into()))?;
    let answer: Answer =
        serde_json::from_str(object).map_err(|error| Invalid::Shape(error.to_string()))?;
    if answer.compartments.is_empty() {
        return Err(Invalid::Empty);
    }
    let mut next = 0;
    let mut out = Vec::new();
    for (index, raw) in answer.compartments.into_iter().enumerate() {
        let expected = ids.get(next).ok_or(Invalid::End {
            index,
            last: raw.last,
        })?;
        if raw.first != expected.0 {
            return Err(Invalid::Start {
                index,
                first: raw.first,
                expected: expected.0,
            });
        }
        let end = ids[next..]
            .iter()
            .position(|id| id.0 == raw.last)
            .ok_or(Invalid::End {
                index,
                last: raw.last,
            })?;
        next += end + 1;
        if !KINDS.contains(&raw.kind.as_str()) {
            return Err(Invalid::Kind {
                index,
                kind: raw.kind,
            });
        }
        let importance = u8::try_from(raw.importance)
            .ok()
            .filter(|importance| (1..=100).contains(importance))
            .ok_or(Invalid::Importance {
                index,
                importance: raw.importance,
            })?;
        let field = |text: String, field, limit| {
            let text = text.trim().to_string();
            if text.is_empty() || text.chars().count() > limit {
                return Err(Invalid::Length {
                    index,
                    field,
                    limit,
                });
            }
            Ok(text)
        };
        out.push(Compartment {
            first: MessageId(raw.first),
            last: MessageId(raw.last),
            title: field(raw.title, "title", TITLE_CHARS)?,
            kind: raw.kind,
            importance,
            full: field(raw.p1, "p1", FULL_CHARS)?,
            brief: field(raw.p2, "p2", BRIEF_CHARS)?,
            line: field(raw.p3.replace(['\n', '\r'], " "), "p3", LINE_CHARS)?,
        });
    }
    if let Some(expected) = ids.last()
        && next < ids.len()
    {
        let last = out.last().map_or(0, |compartment| compartment.last.0);
        return Err(Invalid::Short {
            last,
            expected: expected.0,
        });
    }
    Ok(out)
}

/// What to publish. The last of two or more compartments is dropped when
/// `keep_last` is false: nothing came after it yet, so where it ends is a
/// guess. The next capture reads it again with what follows.
pub fn settled(mut compartments: Vec<Compartment>, keep_last: bool) -> Vec<Compartment> {
    if !keep_last && compartments.len() >= 2 {
        compartments.pop();
    }
    compartments
}

#[cfg(test)]
mod tests;
