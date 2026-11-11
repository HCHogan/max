//! Max here asks Max in another conversation, and is asked by one, or
//! by a background agent here, which may also ask another conversation:
//! the question's way between the actors. Neither the question nor the
//! answer is said in a chat: each reaches Max as a wake's item, as a job's
//! report does, and an agent as a steer. See "Asking another conversation"
//! and "Background agents" in docs/rust-rewrite.md.

use std::collections::BTreeMap;

use max_db::links::{self, Peer};
use tokio::sync::oneshot;

use super::jobs::AgentWaits;
use super::links::peer;
use super::*;
use crate::conversation::Question;
use crate::conversation::notice::Asker;

/// What Max in other conversations, or agents here, asked Max here and
/// still wait to hear, by the number each question got here, `ask#5`:
/// numbered with the questions asked from here (`Jobs::next_ask`).
/// Forgotten with the actor.
#[derive(Default)]
pub(super) struct Asked {
    waiting: BTreeMap<u32, Waiting>,
}

/// A question, and who waits on it.
struct Waiting {
    text: String,
    from: From,
}

/// Who asked, and where the answer goes.
enum From {
    Peer {
        peer: Peer,
        answer: oneshot::Sender<Result<String, String>>,
    },
    Agent {
        waits: AgentWaits,
        title: String,
    },
}

impl From {
    fn gone(&self) -> bool {
        match self {
            From::Peer { answer, .. } => answer.is_closed(),
            From::Agent { waits, .. } => waits.gone(),
        }
    }

    fn asker(&self) -> Asker<'_> {
        match self {
            From::Peer { peer, .. } => Asker::Peer(peer),
            From::Agent { waits, title } => Asker::Agent(waits.agent, title),
        }
    }
}

impl Asked {
    /// Tells every other conversation that waits that no answer comes,
    /// and why; the agents here end with Max.
    pub(super) fn refuse(&mut self, why: &str) {
        for (_, waiting) in std::mem::take(&mut self.waiting) {
            if let From::Peer { answer, .. } = waiting.from {
                let _ = answer.send(Err(why.to_owned()));
            }
        }
    }

    /// Whether someone still waits for Max here to answer `ask#number`.
    pub(super) fn waits(&self, number: u32) -> bool {
        let waiting = self.waiting.get(&number);
        waiting.is_some_and(|waiting| !waiting.from.gone())
    }

    /// Agent `agent` is over: it waits for nothing.
    pub(super) fn forget(&mut self, agent: u32) {
        self.waiting.retain(|_, waiting| match &waiting.from {
            From::Agent { waits, .. } => waits.agent != agent,
            From::Peer { .. } => true,
        });
    }

    /// For a new core, which saw none of them asked: a line for each
    /// question someone still waits on, the question on one line.
    pub(super) fn lines(&self) -> Vec<String> {
        let waiting = self.waiting.iter();
        waiting
            .filter(|(_, waiting)| !waiting.from.gone())
            .map(|(number, waiting)| {
                let text = waiting.text.replace('\n', " ⏎ ");
                let from = waiting.from.asker();
                format!("{} {from}：{text}", Handle::Ask(*number))
            })
            .collect()
    }

    fn keep(&mut self, number: u32, waiting: Waiting) {
        // Those nobody waits on any more: withdrawn, or out of time.
        self.waiting.retain(|_, waiting| !waiting.from.gone());
        self.waiting.insert(number, waiting);
    }
}

impl Conversation {
    /// `ask`: Max's, or agent `by`'s, question goes to the actor of
    /// conversation `to`, and a job waits for the answer; an agent's with
    /// no `to` wakes Max here. The question's number here, or why nothing
    /// was asked.
    pub(super) async fn ask(
        &mut self,
        to: Option<ConversationId>,
        question: &str,
        by: Option<u32>,
    ) -> Result<Result<u32, String>> {
        let question = question.trim();
        let by = match by.map(|agent| (agent, self.agent_waits(agent))) {
            None => None,
            Some((_, Some(waits))) => Some(waits),
            // Cancelled meanwhile.
            Some((agent, None)) => {
                return Ok(Err(format!("{} has ended", Handle::Agent(agent))));
            }
        };
        let Some(to) = to else {
            let Some((waits, title)) = by else {
                return Ok(Err(
                    "to is missing: the number of the conversation to ask, 9 for c#9 under [能问的会话]".into(),
                ));
            };
            return self.agent_asks(waits, title, question).await.map(Ok);
        };
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
        let by = by.map(|(waits, _)| waits);
        let agent = by.as_ref().map(|waits| waits.agent);
        let ask = self.question_job(to, question, answered, by);
        info!(conversation = %here, ask, ?agent, "a question to another conversation");
        Ok(Ok(ask))
    }

    /// An agent asks Max here: the question wakes Max, in the running
    /// core or a new one, and the agent hears the answer as a steer once
    /// `answer` names it.
    async fn agent_asks(
        &mut self,
        waits: AgentWaits,
        title: String,
        question: &str,
    ) -> Result<u32> {
        let number = self.jobs.next_ask();
        let agent = Handle::Agent(waits.agent);
        info!(conversation = %self.place.conversation, %agent, question = number, "an agent asks Max");
        let from = From::Agent { waits, title };
        let notice = Notice::Asked {
            number,
            from: from.asker(),
            question,
        };
        let item = notice.item(self.single());
        // Before it is kept, as another conversation's.
        self.wake_with(Reason::Job { job: agent }, item).await?;
        let text = question.to_owned();
        self.asked.keep(number, Waiting { text, from });
        Ok(number)
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
        let from = From::Peer { peer: from, answer };
        let notice = Notice::Asked {
            number,
            from: from.asker(),
            question: &text,
        };
        let item = notice.item(self.single());
        // Before it is kept: a core this wake starts lists the questions
        // kept, and reads this one once.
        self.wake_with(Reason::Asked, item).await?;
        self.asked.keep(number, Waiting { text, from });
        Ok(())
    }

    /// `answer` to question `to`, Max's or agent `by`'s: it goes to
    /// whoever waits on it. Whom it went to, or why it wasn't taken.
    pub(super) fn answer_question(
        &mut self,
        to: u32,
        text: &str,
        by: Option<u32>,
    ) -> Result<String, String> {
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
        let waiting = self.asked.waiting.get(&to).ok_or_else(nobody)?;
        if let (Some(by), From::Agent { waits, .. }) = (by, &waiting.from)
            && waits.agent == by
        {
            return Err(format!(
                "{handle} is your own question: its answer comes to you"
            ));
        }
        let Some(Waiting {
            text: question,
            from,
        }) = self.asked.waiting.remove(&to)
        else {
            return Err(nobody());
        };
        let text = text.trim().to_owned();
        let conversation = self.place.conversation;
        match from {
            From::Peer { peer, answer } => {
                answer.send(Ok(text)).map_err(|_| nobody())?;
                info!(%conversation, to = %peer.conversation, question = to, "an answer to another conversation");
                Ok(peer.to_string())
            }
            From::Agent { waits, title } => {
                let notice = Notice::Answered {
                    ask: to,
                    to: Asker::Max,
                    question: &question,
                    answer: &Ok(text),
                };
                if !waits.tell(notice.text(self.single())) {
                    return Err(nobody());
                }
                let agent = Handle::Agent(waits.agent);
                info!(%conversation, %agent, question = to, "an answer to an agent");
                Ok(format!("{agent} {title}"))
            }
        }
    }

    /// The wait of question `ask`, which Max or an agent here asked, is
    /// over: Max hears what was answered, or that nothing was and why, in
    /// the running core or a new one; the agent, as a steer.
    pub(super) async fn question_answered(
        &mut self,
        ask: u32,
        answer: Result<String, String>,
    ) -> Result<()> {
        // Withdrawn since, or its agent is over.
        let Some((to, question, by)) = self.question_over(ask) else {
            return Ok(());
        };
        info!(conversation = %self.place.conversation, ask, answered = answer.is_ok(), "a question's wait is over");
        let notice = Notice::Answered {
            ask,
            to: Asker::Peer(&to),
            question: &question,
            answer: &answer,
        };
        if let Some(by) = by {
            // Gone meanwhile: nobody to tell.
            let _ = by.tell(notice.text(self.single()));
            return Ok(());
        }
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
