//! Max here asks Max in another conversation, and is asked by one: the
//! question's way between the actors. Neither the question nor the answer
//! is said in a chat: each reaches Max as a wake's item. See "Asking
//! another conversation" in docs/rust-rewrite.md.

use std::collections::BTreeMap;

use max_db::links::{self, Peer};
use tokio::sync::oneshot;

use super::links::peer;
use super::*;
use crate::conversation::Question;

/// What Max in other conversations asked Max here and still wait to
/// hear, by the number each question got here, `ask#5`: numbered with the
/// questions asked from here (`Jobs::next_ask`). Forgotten with the
/// actor.
#[derive(Default)]
pub(super) struct Asked {
    waiting: BTreeMap<u32, Waiting>,
}

/// A question, who asked it, and where the answer goes.
struct Waiting {
    text: String,
    from: Peer,
    answer: oneshot::Sender<Result<String, String>>,
}

impl Asked {
    /// Tells every conversation that waits that no answer comes, and why.
    pub(super) fn refuse(&mut self, why: &str) {
        for (_, waiting) in std::mem::take(&mut self.waiting) {
            let _ = waiting.answer.send(Err(why.to_owned()));
        }
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

    fn keep(&mut self, number: u32, waiting: Waiting) {
        // Those nobody waits on any more: withdrawn, or out of time.
        self.waiting
            .retain(|_, waiting| !waiting.answer.is_closed());
        self.waiting.insert(number, waiting);
    }
}

impl Conversation {
    /// `ask`: Max's question goes to the actor of conversation `to`, and
    /// a job waits for the answer. The question's number here, or why
    /// nothing was asked.
    pub(super) async fn ask(
        &mut self,
        to: ConversationId,
        question: &str,
    ) -> Result<Result<u32, String>> {
        let question = question.trim();
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
        info!(conversation = %here, ask, "a question to another conversation");
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
        self.asked.keep(number, Waiting { text, from, answer });
        Ok(())
    }

    /// `answer` to question `to`: it goes to the conversation that waits
    /// on it. Whom it went to, or why it wasn't taken.
    pub(super) fn answer_question(&mut self, to: u32, text: &str) -> Result<String, String> {
        let handle = Handle::Ask(to);
        if self.jobs.has(handle) {
            return Err(format!(
                "{handle} is a question asked from here: its answer comes here, so there is nothing to answer; to stop waiting for it, cancel it"
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
        let conversation = self.place.conversation;
        info!(%conversation, to = %waiting.from.conversation, question = to, "an answer to another conversation");
        Ok(waiting.from.to_string())
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

    /// Max won't answer question `number`, asked of it: whoever waits
    /// hears so at once, as if out of time. Whether someone waited.
    pub(super) fn decline(&mut self, number: u32) -> bool {
        let Some(waiting) = self.asked.waiting.remove(&number) else {
            return false;
        };
        waiting.answer.send(Err(DECLINED_THERE.to_owned())).is_ok()
    }

    /// What a new core is shown of the questions asked before it started.
    pub(super) fn questions_waiting(&self) -> Vec<String> {
        self.asked.lines()
    }
}

/// Why a question Max declined with `cancel` has no answer, as the asker
/// in another conversation hears it.
const DECLINED_THERE: &str = "Max there chose not to answer it";

/// Why a conversation that is stopped doesn't answer.
pub(super) const STOPPED_THERE: &str = "Max is stopped there (/stop)";

#[cfg(test)]
mod tests;
