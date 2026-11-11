//! Max here asks Max in another conversation, and is asked by one: the
//! question's way between the two actors. Neither the question nor the
//! answer is said in a chat: each reaches the other side's Max as a wake's
//! item, as a job's report does. See "Asking another conversation" in
//! docs/rust-rewrite.md.

use std::collections::BTreeMap;

use max_db::links::{self, Peer};
use tokio::sync::oneshot;

use super::links::peer;
use super::*;
use crate::conversation::Question;

/// What Max in other conversations asked Max here and still waits to
/// hear, by the number each question got here, `ask#5`: numbered with the
/// questions Max here asks (`Jobs::next_ask`). Forgotten with the actor.
#[derive(Default)]
pub(super) struct Asked {
    waiting: BTreeMap<u32, Waiting>,
}

/// A question, who waits on it, and where its answer goes.
struct Waiting {
    from: Peer,
    text: String,
    answer: oneshot::Sender<Result<String, String>>,
}

impl Asked {
    /// Tells everyone who waits that no answer comes, and why.
    pub(super) fn refuse(&mut self, why: &str) {
        for (_, waiting) in std::mem::take(&mut self.waiting) {
            let _ = waiting.answer.send(Err(why.to_owned()));
        }
    }

    /// Whether someone still waits for Max here to answer `ask#number`.
    pub(super) fn waits(&self, number: u32) -> bool {
        let waiting = self.waiting.get(&number);
        waiting.is_some_and(|waiting| !waiting.answer.is_closed())
    }

    /// For a new core, which saw none of them asked: a line for each
    /// question someone still waits on, the question on one line.
    pub(super) fn lines(&self) -> Vec<String> {
        let waiting = self.waiting.iter();
        waiting
            .filter(|(_, waiting)| !waiting.answer.is_closed())
            .map(|(number, waiting)| {
                let text = waiting.text.replace('\n', " ⏎ ");
                format!("{} {}：{text}", Handle::Ask(*number), waiting.from)
            })
            .collect()
    }
}

impl Conversation {
    /// Max's `ask`: the question goes to that conversation's actor, and a
    /// job waits for the answer. The question's number here, or why
    /// nothing was asked.
    pub(super) async fn ask(
        &mut self,
        to: ConversationId,
        question: &str,
    ) -> Result<Result<u32, String>> {
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
        let question = question.trim();
        let (answer, answered) = oneshot::channel();
        let asked = Signal::Ask {
            conversation: to.conversation,
            question: Question {
                from,
                text: question.to_owned(),
                answer,
            },
        };
        // The table is gone only as Max stops: the wait then ends at once.
        let _ = self.shared.signals.send(asked);
        let ask = self.question_job(to, question, answered);
        info!(conversation = %here, ask, "Max asks another conversation");
        Ok(Ok(ask))
    }

    /// Max in another conversation asks Max here: the question wakes Max,
    /// in the running core or a new one, and the asker waits until
    /// `answer` names it. Stopped, Max here isn't told.
    pub(super) async fn take_question(&mut self, question: Question) -> Result<()> {
        if let Some(refused) = self.refuses(None, Does::STARTS) {
            question.refuse(match refused {
                Refusal::Stopped => STOPPED_THERE,
                _ => "Max is restarting there",
            });
            return Ok(());
        }
        let Question { from, text, answer } = question;
        let number = self.jobs.next_ask();
        info!(conversation = %self.place.conversation, from = %from.conversation, question = number, "Max is asked from another conversation");
        let notice = Notice::Asked {
            number,
            from: &from,
            question: &text,
        };
        let item = notice.item(self.single());
        // Before it is kept: a core this wake starts lists the questions
        // kept, and reads this one once.
        self.wake_with(Reason::Asked, item).await?;
        // Those nobody waits on any more: withdrawn, or out of time.
        let waiting = &mut self.asked.waiting;
        waiting.retain(|_, waiting| !waiting.answer.is_closed());
        waiting.insert(number, Waiting { from, text, answer });
        Ok(())
    }

    /// Max's `answer` to question `to`: it goes to whoever waits on it.
    /// Whom it went to, or why it wasn't taken.
    pub(super) fn answer_question(&mut self, to: u32, text: &str) -> Result<String, String> {
        let handle = Handle::Ask(to);
        if self.jobs.has(handle) {
            return Err(format!(
                "{handle} is a question you asked: its answer comes to you, so there is nothing to answer; to stop waiting for it, cancel it"
            ));
        }
        let nobody = || {
            format!(
                "nobody waits for an answer to {handle}: there is no such question, or it was answered, withdrawn or out of time, or Max has restarted since; nothing was sent"
            )
        };
        let waiting = self.asked.waiting.remove(&to).ok_or_else(nobody)?;
        let sent = waiting.answer.send(Ok(text.trim().to_owned()));
        sent.map_err(|_| nobody())?;
        let from = waiting.from;
        info!(conversation = %self.place.conversation, to = %from.conversation, question = to, "Max answers another conversation");
        Ok(from.to_string())
    }

    /// The wait of question `ask`, which Max here asked, is over: Max
    /// hears what was answered, or that nothing was and why, in the
    /// running core or a new one.
    pub(super) async fn question_answered(
        &mut self,
        ask: u32,
        answer: Result<String, String>,
    ) -> Result<()> {
        // Withdrawn since.
        let Some((to, question)) = self.question_over(ask) else {
            return Ok(());
        };
        info!(conversation = %self.place.conversation, ask, answered = answer.is_ok(), "a question's wait is over");
        let notice = Notice::Answered {
            ask,
            to: &to,
            question: &question,
            answer: &answer,
        };
        let item = notice.item(self.single());
        let job = Handle::Ask(ask);
        self.wake_with(Reason::Job { job }, item).await
    }

    /// What a new core is shown of the questions asked before it started.
    pub(super) fn questions_waiting(&self) -> Vec<String> {
        self.asked.lines()
    }
}

/// Why a conversation that is stopped doesn't answer.
pub(super) const STOPPED_THERE: &str = "Max is stopped there (/stop)";

#[cfg(test)]
mod tests;
