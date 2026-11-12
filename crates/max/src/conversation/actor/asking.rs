//! Max here asks Max in another conversation, and is asked by one: the
//! question's way between the actors, and the answer's way back. Neither
//! is said in a chat: each reaches Max as a wake's item. Nothing waits
//! and nothing is timed: who asks keeps nothing of the question, and who
//! is asked keeps it for as long as the core that read it runs. When
//! that core ends with the question unanswered, the asker hears so, as
//! it does when Max is stopped there; whether to ask again is the
//! asker's to judge. See "Asking another conversation" in
//! docs/rust-rewrite.md.

use std::collections::BTreeMap;

use max_db::links;

use super::links::peer;
use super::*;
use crate::conversation::{Answer, Heard, Question};

/// What Max in other conversations asked the core that runs here, by the
/// number each question got, `ask#5`: each until it is answered, or the
/// core ends.
#[derive(Default)]
pub(super) struct Asked {
    kept: BTreeMap<u32, Question>,
    /// The last number given: they go on from core to core, while max
    /// runs.
    last: u32,
}

impl Conversation {
    /// `ask`: Max's question goes to the actor of conversation `to`.
    /// Whom it went to, or why nothing was asked. What comes of it comes
    /// as a wake: the answer, or why there is none; or nothing.
    pub(super) async fn ask(
        &mut self,
        to: ConversationId,
        question: &str,
    ) -> Result<Result<String, String>> {
        let here = self.place.conversation;
        let mut conn = self.shared.services.pool.acquire().await?;
        // A conversation there is no edge to and one that doesn't exist
        // are refused alike: asking tells nothing of which there are.
        if !links::linked(&mut conn, here, to).await? {
            return Ok(Err(format!(
                "can't ask c#{to}: there is no link from here to it, or no such conversation; whom Max here may ask is listed under [能问的会话]"
            )));
        }
        let from = peer(&mut conn, here).await?;
        let to = peer(&mut conn, to).await?;
        drop(conn);
        let asked = to.to_string();
        let question = Question {
            from,
            to,
            text: question.trim().to_owned(),
        };
        info!(conversation = %here, to = %question.to.conversation, "a question to another conversation");
        self.tell(Signal::Heard {
            conversation: question.to.conversation,
            heard: Heard::Asked(question),
        });
        Ok(Ok(asked))
    }

    /// Max in another conversation asks Max here: the question wakes Max,
    /// in the running core or a new one, and is kept until `answer` names
    /// it or that core ends. Stopped, Max here isn't told, and the asker
    /// hears why.
    pub(super) async fn asked(&mut self, question: Question) -> Result<()> {
        if let Some(refused) = self.refuses(Does::STARTS) {
            let why = match refused {
                Refusal::Stopped => STOPPED_THERE,
                Refusal::Stopping => "Max is restarting there",
            };
            self.tell(question.answered(Err(why.to_owned())));
            return Ok(());
        }
        let conversation = self.place.conversation;
        self.asked.last += 1;
        let number = self.asked.last;
        info!(%conversation, from = %question.from.conversation, question = number, "Max is asked from another conversation");
        let notice = Notice::Asked {
            number,
            from: &question.from,
            question: &question.text,
        };
        let item = notice.item(self.single());
        // Kept first: if the wake fails, the asker hears with the rest.
        self.asked.kept.insert(number, question);
        self.wake_with(Reason::Asked, item).await
    }

    /// `answer` to question `to`: it goes to the conversation that asked.
    /// Whom it went to, or why it wasn't taken.
    pub(super) fn answer_question(&mut self, to: u32, text: &str) -> Result<String, String> {
        let Some(question) = self.asked.kept.remove(&to) else {
            return Err(format!(
                "there is no ask#{to} to answer: no such question, or it was answered already, or it was asked in an earlier turn, which ended without answering it; nothing was sent"
            ));
        };
        let asker = question.from.to_string();
        let conversation = self.place.conversation;
        info!(%conversation, to = %question.from.conversation, question = to, "an answer to another conversation");
        self.tell(question.answered(Ok(text.trim().to_owned())));
        Ok(asker)
    }

    /// Max in another conversation answered what Max here asked it, or
    /// there is no answer and it can be told why: Max hears it, in the
    /// running core or a new one. Stopped, it doesn't.
    pub(super) async fn answered(&mut self, answer: Answer) -> Result<()> {
        if self.refuses(Does::STARTS).is_some() {
            return Ok(());
        }
        let conversation = self.place.conversation;
        info!(%conversation, by = %answer.by.conversation, answered = answer.said.is_ok(), "an answer from another conversation");
        let notice = Notice::Answered {
            by: &answer.by,
            question: &answer.question,
            said: &answer.said,
        };
        let item = notice.item(self.single());
        self.wake_with(Reason::Answered, item).await
    }

    /// What other conversations asked and Max hasn't answered won't be
    /// answered, and each hears `why`: `/stop`, or the core that read
    /// them ended.
    pub(super) fn refuse_questions(&mut self, why: &str) {
        for question in std::mem::take(&mut self.asked.kept).into_values() {
            self.tell(question.answered(Err(why.to_owned())));
        }
    }

    /// Sends `signal` to another conversation's actor, through the
    /// table, which is gone only as Max stops.
    fn tell(&self, signal: Signal) {
        let _ = self.shared.signals.send(signal);
    }
}

/// Why a conversation that is stopped doesn't answer...
pub(super) const STOPPED_THERE: &str = "Max is stopped there (/stop)";
/// ...and one whose core ended with the question still there: its idle
/// window ran out, or the turn was killed or failed.
pub(super) const TURN_OVER: &str = "Max there ended its turn without answering";

#[cfg(test)]
mod tests;
