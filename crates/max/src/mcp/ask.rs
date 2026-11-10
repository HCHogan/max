//! `ask` and `answer`: Max here asks Max in another conversation, and
//! answers what one asked it. The conversation's actor sends the question
//! on its way and keeps who waits. See "Asking another conversation" in
//! docs/rust-rewrite.md.

use max_core::ids::{ConversationId, MessageId};
use max_core::limits::{self, ASK_CHARS};
use max_db::links;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::tool::Tool;
use super::{Context, Failure};
use crate::conversation::Poster;
use crate::job;

pub struct Ask;
pub struct Answer;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Asking {
    #[schemars(description = "要问的会话，[能问的会话] 里列着：c#9 或 9")]
    to: Handle,
    #[schemars(
        length(min = 1, max = ASK_CHARS),
        description = "问题，连同那边需要的背景写全：它看不到这边的对话"
    )]
    question: String,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Answering {
    #[schemars(description = "问你的那一行的消息编号：#501 或 501")]
    to: Handle,
    #[schemars(length(min = 1, max = ASK_CHARS), description = "回答")]
    text: String,
}

/// `c#9`, `#501`, `9` or 9.
#[derive(Deserialize, JsonSchema)]
#[serde(untagged)]
enum Handle {
    Text(String),
    Number(i64),
}

/// The job that waits for the answer.
#[derive(Serialize, JsonSchema)]
pub struct Waiting {
    job: String,
}

/// The conversation the answer went to.
#[derive(Serialize, JsonSchema)]
pub struct Answered {
    to: String,
}

impl Tool for Ask {
    const NAME: &'static str = "ask";
    const DESCRIPTION: &'static str = "问另一个会话里的 Max 一个问题，马上返回 job 编号；它的回答之后作为一行「系统发的」消息回到这里。";
    const JOB: bool = false;
    const PROGRAM: bool = false;

    type Args = Asking;
    type Output = Waiting;

    fn guide() -> String {
        format!(
            "问另一个会话（别的群或私聊）里的 Max 一个问题。只能问 [能问的会话] 里列着的，to 写 \"c#9\" 或 9；上下文里没有这一块，就是这里谁也问不了。\n  \
            那边的 Max 用它自己的记录、记忆和工具，按它那边的规矩回答，答不答、答多少由它定。它看不到这边的对话，你也看不到它那边的，所以 question 要把背景和要问的事写全，最多 {ASK_CHARS} 字；这边的 [mention#…]、消息编号、图片句柄到那边没有意义，用名字和文字说。\n  \
            问题和回答在两边的会话里都原样显示，两边的人都看得到。\n  \
            马上返回 {{ job: \"job#3\" }}，你接着聊。那边答了，你的新消息里会多一行「系统发的」`c#9 名字 answered:` 加回答，引用着你问的那一行，由你决定在这边怎么说；没答成是 `c#9 名字 didn't answer: 原因`。它可能要先问它那边的人，最多等 {} 小时。等着的问题在 agent_status 里，标题以 ? 开头；不想等了用 agent_cancel 撤回。",
            limits::JOB_TIME.as_secs() / 3600,
        )
    }

    async fn run(context: &Context, Asking { to, question }: Asking) -> Result<Waiting, Failure> {
        if question.trim().is_empty() {
            return Err(Failure::new("bad_arguments", "question 是空的"));
        }
        let to = to.conversation()?;
        let job = turn(context)?
            .ask(to, question)
            .await
            .map_err(|message| Failure::new("not_asked", message))?;
        Ok(Waiting {
            job: job::name(job),
        })
    }
}

impl Tool for Answer {
    const NAME: &'static str = "answer";
    const DESCRIPTION: &'static str =
        "回答别的会话的 Max 问这里的问题；to 是它问的那一行「系统发的」消息的编号。";
    const JOB: bool = false;
    const PROGRAM: bool = false;

    type Args = Answering;
    type Output = Answered;

    fn guide() -> String {
        format!(
            "回答别的会话的 Max 问你的问题。它问你时，你的新消息里会有一行「系统发的」`c#7 名字 asks:` 加问题；to 是那一行的消息编号（\"#501\" 或 501），text 是回答，最多 {ASK_CHARS} 字。\n  \
            问你的是那个会话的 Max，不是这边的人：它看不到这边的对话，只看得到你的 text。能说什么、说多少，按这边的规矩和记忆自己判断；要先问问这边的人也行，问到了再答，它最多等 {} 小时。不想答可以不答，也可以回一句不方便说。\n  \
            回答会原样显示在两边的会话里。一个问题只能答一次；对方不等了（撤回了、等到点了、Max 重启过）就报错，什么都不发。返回 {{ to: \"c#7 名字\" }}。",
            limits::JOB_TIME.as_secs() / 3600,
        )
    }

    async fn run(
        context: &Context,
        Answering { to, text }: Answering,
    ) -> Result<Answered, Failure> {
        if text.trim().is_empty() {
            return Err(Failure::new("bad_arguments", "text 是空的"));
        }
        let to = to.line()?;
        let to = turn(context)?
            .answer(to, text)
            .await
            .map_err(|message| Failure::new("not_answered", message))?;
        Ok(Answered { to })
    }
}

impl Handle {
    /// The conversation it names: `c#9`, `9` or 9.
    fn conversation(self) -> Result<ConversationId, Failure> {
        let named = match &self {
            Handle::Text(text) => links::named(text),
            Handle::Number(number) => (*number > 0).then_some(ConversationId(*number)),
        };
        named.ok_or_else(|| self.wrong("会话的编号，要 c#9 或 9"))
    }

    /// The line it names: `#501`, `501` or 501.
    fn line(self) -> Result<MessageId, Failure> {
        let named = match &self {
            Handle::Text(text) => {
                let digits = text.trim().trim_start_matches('#');
                let all_digits = !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit());
                digits.parse().ok().filter(|_| all_digits)
            }
            Handle::Number(number) => Some(*number),
        };
        match named {
            Some(id) if id > 0 => Ok(MessageId(id)),
            _ => Err(self.wrong("消息的编号，要 #501 或 501")),
        }
    }

    fn wrong(&self, what: &str) -> Failure {
        let given = match self {
            Handle::Text(text) => text.clone(),
            Handle::Number(number) => number.to_string(),
        };
        Failure::new("bad_arguments", format!("{given} 不是{what}"))
    }
}

/// The conversation of the turn that calls. Only a turn asks and answers:
/// a background agent has no core for an answer to wake, and a program
/// could ask in a loop, each time at the cost of a turn of the other
/// conversation's model, where a turn pays a step of its own for each.
fn turn(context: &Context) -> Result<&Poster, Failure> {
    match &context.caller {
        super::Caller::Turn(poster) => Ok(poster),
        _ => Err(Failure::new(
            "not_here",
            "只有 Max 自己的一轮能问别的会话、回答别的会话",
        )),
    }
}

#[cfg(test)]
mod tests;
