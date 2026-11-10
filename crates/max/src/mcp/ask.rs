//! `ask` and `answer`: Max here asks Max in another conversation, and
//! answers what one asked it. The conversation's actor sends the question
//! on its way and keeps who waits. See "Asking another conversation" in
//! docs/rust-rewrite.md.

use max_core::ids::ConversationId;
use max_core::limits::{self, ASK_CHARS};
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
    #[schemars(
        range(min = 1),
        description = "要问的会话的编号：[能问的会话] 里的 c#9 就填 9"
    )]
    to: i64,
    #[schemars(
        length(min = 1, max = ASK_CHARS),
        description = "问题，连同那边需要的背景写全：它看不到这边的对话"
    )]
    question: String,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Answering {
    #[schemars(range(min = 1), description = "那个问题的编号：[ask#5 问] 就填 5")]
    to: u32,
    #[schemars(length(min = 1, max = ASK_CHARS), description = "回答")]
    text: String,
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
    const DESCRIPTION: &'static str = "问另一个会话里的 Max 一个问题，马上返回 job 编号；它的回答之后作为 [job#N 回答] 回到这里。";
    const JOB: bool = false;

    type Args = Asking;
    type Output = Waiting;

    fn guide() -> String {
        format!(
            "问另一个会话（别的群或私聊）里的 Max 一个问题。只能问 [能问的会话] 里列着的，to 填它的编号，c#9 就填 9；上下文里没有这一块，就是这里谁也问不了。\n  \
            那边的 Max 用它自己的记录、记忆和工具，按它那边的规矩回答，答不答、答多少由它定。它看不到这边的对话，你也看不到它那边的，所以 question 要把背景和要问的事写全，最多 {ASK_CHARS} 字；这边的 [mention#…]、消息编号、图片句柄到那边没有意义，用名字和文字说。\n  \
            问题和回答都不会发到任何一边的聊天里，只有两边的 Max 看得到：这边的人不知道你去问了，要不要说、怎么转述由你定。\n  \
            马上返回 {{ job: \"job#3\" }}，你接着聊。那边答了，回答作为 [job#3 回答] 出现在你的新消息里，带着你问的原话；没答成是 [job#3 没答成] 加原因。它可能要先问它那边的人，最多等 {} 小时。等着的问题在 agent_status 里，标题以 ? 开头；不想等了用 agent_cancel 撤回。",
            limits::JOB_TIME.as_secs() / 3600,
        )
    }

    async fn run(context: &Context, Asking { to, question }: Asking) -> Result<Waiting, Failure> {
        if question.trim().is_empty() {
            return Err(Failure::new("bad_arguments", "question 是空的"));
        }
        let job = conversation(context)?
            .ask(ConversationId(to), question)
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
        "回答别的会话的 Max 问这里的问题；to 是那个问题的编号，[ask#5 问] 就填 5。";
    const JOB: bool = false;

    type Args = Answering;
    type Output = Answered;

    fn guide() -> String {
        format!(
            "回答别的会话的 Max 问你的问题。它问你时，你的新消息里会有 [ask#5 问] c#7 名字 加问题；to 是那个编号，ask#5 就填 5，text 是回答，最多 {ASK_CHARS} 字。\n  \
            问你的是那个会话的 Max，不是这边的人：它看不到这边的对话，只看得到你的 text。能说什么、说多少，按这边的规矩和记忆自己判断；要先问问这边的人也行，问到了再答，它最多等 {} 小时。不想答可以不答，也可以回一句不方便说。\n  \
            问题和你的回答都不会发到这边的聊天里，这边的人不知道有人来问过，要不要说由你定。这一轮结束时还没答的，下一轮列在 [等你回答的问题] 里。一个问题只能答一次；对方不等了（撤回了、等到点了、Max 重启过）就报错。返回 {{ to: \"c#7 名字\" }}。",
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
        let to = conversation(context)?
            .answer(to, text)
            .await
            .map_err(|message| Failure::new("not_answered", message))?;
        Ok(Answered { to })
    }
}

/// The conversation the call comes from, a turn's or a program's.
fn conversation(context: &Context) -> Result<&Poster, Failure> {
    let here = context.caller.poster();
    here.ok_or_else(|| Failure::new("not_here", "这里问不了、也答不了别的会话"))
}

#[cfg(test)]
mod tests;
