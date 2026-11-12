//! `ask` and `answer`: Max here asks Max in another conversation, and
//! answers what one asked it. The conversation's actor sends the question
//! on its way and keeps who waits. See "Asking another conversation" in
//! docs/rust-rewrite.md.

use max_core::ids::{ConversationId, Handle};
use max_core::limits::{self, ASK_CHARS};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::tool::Tool;
use super::{Context, Failure};
use crate::conversation::Poster;

pub struct Ask;
pub struct Answer;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Asking {
    #[schemars(
        range(min = 1),
        description = "the number of the conversation to ask: 9 for the c#9 listed under [能问的会话]"
    )]
    to: i64,
    #[schemars(
        length(min = 1, max = ASK_CHARS),
        description = "the question, with the background needed to answer it, in full: whoever is asked sees this text and nothing else of yours"
    )]
    question: String,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Answering {
    #[schemars(
        range(min = 1),
        description = "the question's number: 5 for [ask#5 问]"
    )]
    to: u32,
    #[schemars(length(min = 1, max = ASK_CHARS), description = "the answer")]
    text: String,
}

/// The question, which waits for the answer.
#[derive(Serialize, JsonSchema)]
pub struct Waiting {
    ask: String,
}

/// The conversation the answer went to.
#[derive(Serialize, JsonSchema)]
pub struct Answered {
    to: String,
}

impl Tool for Ask {
    const NAME: &'static str = "ask";
    const DESCRIPTION: &'static str = "Asks Max in another conversation, one listed under [能问的会话], a question. Returns its handle, ask#N, at once; the answer comes later as [ask#N 回答], or [ask#N 没答成] and why.";

    type Args = Asking;
    type Output = Waiting;

    fn guide() -> String {
        format!(
            "Asks Max in another conversation (another group, or a private chat) a question. Only those listed under [能问的会话] can be asked; to is the number, 9 for c#9. With no such block in the context, nobody can be asked from here.\n  \
            Max there answers by its own rules, with its own records, memory and tools; whether to answer and how much is its to decide. It doesn't see this conversation, nor you its, so question has to carry the background and what is asked in full, in at most {ASK_CHARS} characters; a [mention#…], a message number or a picture's handle from here means nothing there: say it with names and words.\n  \
            Neither the question nor the answer is sent to either chat; only the two Maxes see them. The people here don't know you asked: whether to say so, and how to pass the answer on, is yours to decide.\n  \
            Returns {{ ask: \"ask#3\" }} at once, and you go on talking. When it answers, the answer appears among your new messages as [ask#3 回答], with what you asked; if no answer comes, as [ask#3 没答成] and why. It may ask its own people first, and is waited for at most {} hours. A question that waits shows in status, its title starting with ?; to stop waiting, withdraw it with cancel. A background agent of yours asks through the same tool, as anything in the VM does, and its question and the answer are yours: tell it what was answered with max-agent steer.",
            limits::ASK_WAIT.as_secs() / 3600,
        )
    }

    async fn run(context: &Context, Asking { to, question }: Asking) -> Result<Waiting, Failure> {
        if question.trim().is_empty() {
            return Err(Failure::new("bad_arguments", "question is empty"));
        }
        let ask = conversation(context)?
            .ask(ConversationId(to), question)
            .await
            .map_err(|message| Failure::new("not_asked", message))?;
        Ok(Waiting {
            ask: Handle::Ask(ask).to_string(),
        })
    }
}

impl Tool for Answer {
    const NAME: &'static str = "answer";
    const DESCRIPTION: &'static str = "Answers a question Max in another conversation asked here; to is the question's number, 5 for [ask#5 问].";

    type Args = Answering;
    type Output = Answered;

    fn guide() -> String {
        format!(
            "Answers a question Max in another conversation asked of you, when your new messages have [ask#5 问] c#7 <name> and the question. to is that number, 5 for ask#5, and text is the answer, at most {ASK_CHARS} characters. What a background agent of yours asks you, [max-agent-3 问], is not answered with this but with max-agent steer.\n  \
            Another conversation's Max is not anyone here: it doesn't see this conversation, only your text. What may be said, and how much, is yours to judge by the rules and memory of this conversation; you may ask the people here first and answer once you know, and it waits at most {} hours. You may answer that you'd rather not say, or decline it with cancel, and the asker hears at once that no answer comes; left unanswered, it waits until its time is up.\n  \
            Neither the question nor your answer is sent to this chat, so the people here don't know anyone asked: whether to tell them is yours to decide. A question still unanswered when this turn ends is listed under [等你回答的问题] in the next. Questions are numbered here whichever way they go: one you asked yourself is answered to you, not by you. A question is answered once; if nobody waits any more (withdrawn, out of time, or Max has restarted), the call fails. Returns whom it went to: {{ to: \"c#7 <name>\" }}.",
            limits::ASK_WAIT.as_secs() / 3600,
        )
    }

    async fn run(
        context: &Context,
        Answering { to, text }: Answering,
    ) -> Result<Answered, Failure> {
        if text.trim().is_empty() {
            return Err(Failure::new("bad_arguments", "text is empty"));
        }
        let to = conversation(context)?
            .answer(to, text)
            .await
            .map_err(|message| Failure::new("not_answered", message))?;
        Ok(Answered { to })
    }
}

/// The conversation the call comes from: a turn's, or a program's.
fn conversation(context: &Context) -> Result<&Poster, Failure> {
    let here = context.poster.as_ref();
    here.ok_or_else(|| {
        Failure::new(
            "not_here",
            "another conversation can't be asked or answered from here",
        )
    })
}

#[cfg(test)]
mod tests;
