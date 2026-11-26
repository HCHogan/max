//! `ask` and `answer`: Max here asks Max in another conversation, and
//! answers what one asked it, in whichever turn it comes to know. The
//! conversation's actor sends each on its way. See "Asking another
//! conversation" in docs/design/jobs.md.

use max_core::ids::ConversationId;
use max_core::limits::{ASK_CHARS, ASK_DAYS, ASK_WAITING};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::tool::Tool;
use super::{Context, Failure};
use crate::conversation::Poster;

pub(super) struct Ask;
pub(super) struct Answer;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub(super) struct Asking {
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
pub(super) struct Answering {
    #[schemars(
        range(min = 1),
        description = "the question's number: 5 for ask#5, as in [ask#5 问] or under [等你回答的问题]"
    )]
    to: i64,
    #[schemars(length(min = 1, max = ASK_CHARS), description = "the answer")]
    text: String,
}

/// The conversation the question went to.
#[derive(Serialize, JsonSchema)]
pub(super) struct Asked {
    asked: String,
}

/// The conversation the answer went to.
#[derive(Serialize, JsonSchema)]
pub(super) struct Answered {
    to: String,
}

impl Tool for Ask {
    const NAME: &'static str = "ask";
    const DESCRIPTION: &'static str = "Asks Max in another conversation, one listed under [能问的会话], a question. Returns at once; the answer comes later as [回答], when Max there gives one.";

    type Args = Asking;
    type Output = Asked;

    fn guide() -> String {
        format!(
            "Asks Max in another conversation (another group, or a private chat) a question. Only those listed under [能问的会话] can be asked; to is the number, 9 for c#9. With no such block in the context, nobody can be asked from here.\n  \
            Max there answers by its own rules, with its own records, memory and tools; whether to answer and how much is its to decide. It doesn't see this conversation, nor you its, so question has to carry the background and what is asked in full, in at most {ASK_CHARS} characters; a [mention#…], a message number or a picture's handle from here means nothing there: say it with names and words.\n  \
            Neither the question nor the answer is sent to either chat; only the two Maxes see them. The people here don't know you asked: whether to say so, and how to pass the answer on, is yours to decide.\n  \
            Returns {{ asked: \"c#9 <name>\" }} at once, and you go on talking. When Max there answers, the answer appears among your new messages as [回答] c#9 <name>, with what you asked, in this turn or a later one: it may ask its own people first, and they may take hours or days to say. Until then the question waits there, for up to {ASK_DAYS} days, and each later turn of yours lists it under [问出去还没回的], so you can tell someone who asks that there is no answer yet; nothing tells you when the {ASK_DAYS} days run out. You hear [没答成], and why, only when Max there can't answer at all: it is stopped there (/stop), as you ask or while the question waits, or Max is restarting. Whether to ask again then is for you and the people here to judge; nothing asks again by itself. At most {ASK_WAITING} questions from here wait in one conversation at once; past that the call fails. A background agent of yours asks through the same tool, as anything in the VM does, and the answer comes to you: pass it on when you run the agent again."
        )
    }

    async fn run(context: &Context, Asking { to, question }: Asking) -> Result<Asked, Failure> {
        if question.trim().is_empty() {
            return Err(Failure::new("bad_arguments", "question is empty"));
        }
        let asked = conversation(context)?
            .ask(ConversationId::new(to), question)
            .await
            .map_err(|why| Failure::new("not_asked", why.to_string()))?;
        Ok(Asked { asked })
    }
}

impl Tool for Answer {
    const NAME: &'static str = "answer";
    const DESCRIPTION: &'static str = "Answers a question Max in another conversation asked here, in this turn or any later one; to is the question's number, 5 for ask#5.";

    type Args = Answering;
    type Output = Answered;

    fn guide() -> String {
        format!(
            "Answers a question Max in another conversation asked of you: one that comes among your new messages as [ask#5 问] c#7 <name> with the question, or one from an earlier turn, listed under [等你回答的问题]. to is its number, 5 for ask#5, and text is the answer, at most {ASK_CHARS} characters. What a background agent of yours asks you is its last words, answered by running it again, not with this.\n  \
            Another conversation's Max is not anyone here: it doesn't see this conversation, only your text. What may be said, and how much, is yours to judge by the rules and memory of this conversation; if it takes someone here to know, ask them in the chat and answer once they have said. If you'd rather not say, answer that.\n  \
            A question waits for up to {ASK_DAYS} days, across turns: what you haven't answered is listed under [等你回答的问题] in each later turn, so the answer can go when the person comes back to you, hours later or the next day. Neither the question nor your answer is sent to this chat, so the people here don't know anyone asked unless you say so. A question is answered once: for one answered already, or one that waited over {ASK_DAYS} days, the call fails and nothing is sent. Returns whom it went to: {{ to: \"c#7 <name>\" }}."
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
            .map_err(|why| Failure::new("not_answered", why.to_string()))?;
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
