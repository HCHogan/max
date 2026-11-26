//! Max here asks Max in another conversation, and is asked by one: the
//! question's way between the actors, and the answer's way back. Neither
//! is said in a chat: each reaches Max as a wake's item. Nothing waits
//! and nothing is timed: a question Max here was shown is a row
//! (`max_db::questions`) until Max answers it, in the core that read it
//! or a later one, and the actors keep nothing of it. Who asks hears at
//! once when Max there can't be asked, and when `/stop` there ends what
//! waits. See "Asking another conversation" in docs/design/jobs.md.

use chrono::Utc;
use color_eyre::eyre::Result;
use max_core::ids::ConversationId;
use max_core::intent::Reason;
use max_core::limits::ASK_WAITING;
use max_db::links::{self, Peer};
use max_db::questions::{self, Taken};
use tracing::info;

use super::links::peer;
use super::{Conversation, Does};
use crate::conversation::notice::Notice;
use crate::conversation::{Answer, Heard, Question, Refusal, Refused, Signal, Unanswered};

/// What tells the asker of `taken` what Max in `by` `said` to it.
fn answered(by: Peer, taken: Taken, said: Result<String, Unanswered>) -> Signal {
    Signal::Heard {
        conversation: taken.asker,
        heard: Heard::Answered(Answer {
            by,
            question: taken.question,
            said,
        }),
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
    ) -> Result<Result<String, Refused>> {
        let here = self.place.conversation;
        let mut conn = self.shared.services.pool.acquire().await?;
        if !links::linked(&mut conn, here, to).await? {
            return Ok(Err(Refused::NotLinked(to)));
        }
        let waiting = questions::count(&mut conn, here, to, Utc::now()).await?;
        if waiting >= i64::from(ASK_WAITING) {
            return Ok(Err(Refused::TooMany(to)));
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
    /// in the running core or a new one, and waits from then until
    /// `answer` names it. Stopped, Max here isn't told, and the asker
    /// hears why.
    pub(super) async fn asked(&mut self, question: Question) -> Result<()> {
        if let Some(refused) = self.refuses(Does::STARTS) {
            let why = match refused {
                Refusal::Stopped => Unanswered::Stopped,
                Refusal::Stopping => Unanswered::Restarting,
            };
            self.tell(question.answered(Err(why)));
            return Ok(());
        }
        let conversation = self.place.conversation;
        let mut conn = self.shared.services.pool.acquire().await?;
        let number = questions::number(&mut conn).await?;
        drop(conn);
        let asker = question.from.conversation;
        info!(%conversation, from = %asker, question = number, "Max is asked from another conversation");
        let notice = Notice::Asked {
            number,
            from: &question.from,
            question: &question.text,
        };
        let item = notice.item(self.single());
        // Shown first and kept after: a core the question starts reads
        // what waits for its base context, which has this one among its
        // first inputs.
        if let Err(error) = self.wake_with(Reason::Asked, item).await {
            self.tell(question.answered(Err(Unanswered::NotStarted)));
            return Err(error);
        }
        let mut conn = self.shared.services.pool.acquire().await?;
        let text = &question.text;
        questions::keep(&mut conn, number, asker, conversation, text, Utc::now()).await?;
        Ok(())
    }

    /// `answer` to question `to`, whichever core was shown it: it goes
    /// to the conversation that asked. Whom it went to, or why it wasn't
    /// taken.
    pub(super) async fn answer_question(
        &mut self,
        to: i64,
        text: &str,
    ) -> Result<Result<String, Refused>> {
        let conversation = self.place.conversation;
        let mut conn = self.shared.services.pool.acquire().await?;
        let taken = questions::take(&mut conn, to, conversation, Utc::now()).await?;
        let Some(taken) = taken else {
            return Ok(Err(Refused::NoQuestion(to)));
        };
        let asker = peer(&mut conn, taken.asker).await?;
        let by = peer(&mut conn, conversation).await?;
        drop(conn);
        info!(%conversation, to = %taken.asker, question = to, "an answer to another conversation");
        self.tell(answered(by, taken, Ok(text.trim().to_owned())));
        Ok(Ok(asker.to_string()))
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

    /// `/stop`: what other conversations asked and Max here hasn't
    /// answered won't be answered, and each hears so.
    pub(super) async fn refuse_questions(&mut self) -> Result<()> {
        let conversation = self.place.conversation;
        let mut conn = self.shared.services.pool.acquire().await?;
        let waiting = questions::take_all(&mut conn, conversation, Utc::now()).await?;
        if waiting.is_empty() {
            return Ok(());
        }
        let by = peer(&mut conn, conversation).await?;
        drop(conn);
        for taken in waiting {
            self.tell(answered(by.clone(), taken, Err(Unanswered::Stopped)));
        }
        Ok(())
    }

    /// Sends `signal` to another conversation's actor, through the
    /// table, which is gone only as Max stops.
    fn tell(&self, signal: Signal) {
        let _ = self.shared.signals.send(signal);
    }
}
