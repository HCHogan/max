//! Max here asks Max in another conversation, and is asked by one: the
//! question's way between the actors, and the answer's way back. Neither
//! is said in a chat: each reaches Max as a wake's item. Nothing waits:
//! who asks keeps nothing of the question, and who is asked keeps who
//! asked, which is all that lets its answer go back. See "Asking another
//! conversation" in docs/rust-rewrite.md.

use std::collections::BTreeMap;

use max_db::links;

use super::links::peer;
use super::*;
use crate::conversation::{Answer, Heard, Question};
use max_core::limits::{ASKED_KEPT, ASKED_LISTED};

/// What Max in other conversations asked Max here, by the number each
/// question got here, `ask#5`: the latest few dozen, each until it is
/// answered. Forgotten with the actor.
#[derive(Default)]
pub(super) struct Asked {
    kept: BTreeMap<u32, (Question, Instant)>,
    /// The last number given.
    last: u32,
}

impl Asked {
    /// Keeps `question`, asked now: its number. The oldest goes if that
    /// is one too many.
    fn keep(&mut self, question: Question) -> u32 {
        self.last += 1;
        self.kept.insert(self.last, (question, Instant::now()));
        while self.kept.len() > ASKED_KEPT {
            self.kept.pop_first();
        }
        self.last
    }

    /// For a new core, which saw none of them asked: a line for each
    /// question asked lately and not answered, the question on one line.
    pub(super) fn lines(&self) -> Vec<String> {
        let lately = self.kept.iter();
        lately
            .filter(|(_, (_, at))| at.elapsed() < ASKED_LISTED)
            .map(|(number, (question, _))| {
                let text = question.text.replace('\n', " ⏎ ");
                format!("ask#{number} {}：{text}", question.from)
            })
            .collect()
    }

    /// Every question kept, none of them kept any longer.
    fn take(&mut self) -> Vec<Question> {
        let kept = std::mem::take(&mut self.kept);
        kept.into_values().map(|(question, _)| question).collect()
    }
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
    /// it. Stopped, Max here isn't told, and the asker hears why.
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
        // Numbered, though not listed, before the wake: a core this wake
        // starts lists the questions kept, and reads this one once.
        let number = self.asked.last + 1;
        info!(%conversation, from = %question.from.conversation, question = number, "Max is asked from another conversation");
        let notice = Notice::Asked {
            number,
            from: &question.from,
            question: &question.text,
        };
        let item = notice.item(self.single());
        self.wake_with(Reason::Asked, item).await?;
        self.asked.keep(question);
        Ok(())
    }

    /// `answer` to question `to`: it goes to the conversation that asked.
    /// Whom it went to, or why it wasn't taken.
    pub(super) fn answer_question(&mut self, to: u32, text: &str) -> Result<String, String> {
        let Some((question, _)) = self.asked.kept.remove(&to) else {
            return Err(format!(
                "there is no ask#{to} to answer: no such question, or it was answered already, or it is older than the latest {ASKED_KEPT}, or Max has restarted since; nothing was sent"
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

    /// `/stop`: what other conversations asked won't be answered, and
    /// each hears so.
    pub(super) fn refuse_questions(&mut self) {
        for question in self.asked.take() {
            self.tell(question.answered(Err(STOPPED_THERE.to_owned())));
        }
    }

    /// What a new core is shown of the questions asked before it started.
    pub(super) fn questions_waiting(&self) -> Vec<String> {
        self.asked.lines()
    }

    /// Sends `signal` to another conversation's actor, through the
    /// table, which is gone only as Max stops.
    fn tell(&self, signal: Signal) {
        let _ = self.shared.signals.send(signal);
    }
}

/// Why a conversation that is stopped doesn't answer.
const STOPPED_THERE: &str = "Max is stopped there (/stop)";

#[cfg(test)]
mod tests;
