//! Max here asks Max in another conversation, and is asked by one: the
//! question's way between the two actors, and the four lines that say so,
//! two in each conversation. See "Asking another conversation" in
//! docs/rust-rewrite.md.

use std::collections::BTreeMap;

use max_db::links::{self, Peer};
use tokio::sync::oneshot;

use super::links::peer;
use super::*;
use crate::conversation::Question;

/// What Max in other conversations asked Max here and still waits to
/// hear, by the line that put each question. Forgotten with the actor.
#[derive(Default)]
pub(super) struct Asked(BTreeMap<MessageId, Waiting>);

/// Who waits on a question, and where its answer goes.
struct Waiting {
    from: Peer,
    answer: oneshot::Sender<Result<String, String>>,
}

impl Asked {
    /// Tells everyone who waits that no answer comes, and why.
    pub(super) fn refuse(&mut self, why: &str) {
        for (_, waiting) in std::mem::take(&mut self.0) {
            let _ = waiting.answer.send(Err(why.to_owned()));
        }
    }

    /// For `/status`: the questions someone still waits on, by line.
    pub(super) fn summary(&self) -> Option<String> {
        let waiting: Vec<String> = self
            .0
            .iter()
            .filter(|(_, waiting)| !waiting.answer.is_closed())
            .map(|(line, waiting)| format!("#{line} from {}", waiting.from))
            .collect();
        (!waiting.is_empty()).then(|| waiting.join(" · "))
    }
}

impl Conversation {
    /// Max's `ask`: a line says here what is asked of whom, the question
    /// goes to that conversation's actor, and a job waits for the answer.
    /// The job's number, or why nothing was asked.
    pub(super) async fn ask(
        &mut self,
        to: ConversationId,
        question: &str,
        origin: Option<TurnId>,
    ) -> Result<Result<u32, String>> {
        if let Some(refused) = self.ended(origin).or_else(|| self.stopped()) {
            return Ok(Err(refused));
        }
        if self.stopping.is_some() {
            return Ok(Err("Max 正在重启，问不了".to_owned()));
        }
        let here = self.place.conversation;
        let mut conn = self.shared.services.pool.acquire().await?;
        // A conversation there is no edge to and one that doesn't exist
        // are refused alike: asking tells nothing of which there are.
        if !links::linked(&mut conn, here, to).await? {
            return Ok(Err(format!(
                "问不了 c#{to}：这里没有连到它，或者没有这个会话。能问的列在 [能问的会话] 里"
            )));
        }
        let from = peer(&mut conn, here).await?;
        let to = peer(&mut conn, to).await?;
        drop(conn);
        let question = question.trim();
        let said = format!("asked {to}:\n{question}");
        let Some(line) = self.host_line(said, None, origin).await? else {
            return Ok(Err(NOTHING_TO_SAY.to_owned()));
        };
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
        let job = self.question_job(to, line.id, question, answered);
        info!(conversation = %here, job, line = %line.id, "Max asks another conversation");
        Ok(Ok(job))
    }

    /// Max in another conversation asks Max here: a line says so and
    /// wakes Max, and the asker waits until `answer` names the line.
    /// Stopped, nobody here is told.
    pub(super) async fn take_question(&mut self, question: Question) -> Result<()> {
        if self.stopping.is_some() {
            question.refuse("Max is restarting");
            return Ok(());
        }
        if self.settings.stopped {
            question.refuse("Max is stopped there (/stop)");
            return Ok(());
        }
        let Question { from, text, answer } = question;
        let said = format!("{from} asks:\n{text}");
        let Some(line) = self.host_line(said, None, None).await? else {
            let _ = answer.send(Err("the question was empty".to_owned()));
            return Ok(());
        };
        info!(conversation = %self.place.conversation, from = %from.conversation, line = %line.id, "Max is asked from another conversation");
        // Those nobody waits on any more: withdrawn, or out of time.
        self.asked
            .0
            .retain(|_, waiting| !waiting.answer.is_closed());
        self.asked.0.insert(line.id, Waiting { from, answer });
        self.wake_at(&line, Reason::Asked).await
    }

    /// Max's `answer` to the question of line `to`: it goes to whoever
    /// waits on it, and a line says so here. Whom it went to; or why it
    /// wasn't taken, and then nothing is said.
    pub(super) async fn answer_question(
        &mut self,
        to: MessageId,
        text: &str,
        origin: Option<TurnId>,
    ) -> Result<Result<String, String>> {
        if let Some(refused) = self.ended(origin).or_else(|| self.stopped()) {
            return Ok(Err(refused));
        }
        let nobody = || {
            format!(
                "没有人在等 #{to} 的回答：它不是别的会话问你的那一行，或者已经答过了、对方撤回了、等到点了、Max 重启过。这次没发出去"
            )
        };
        let Some(waiting) = self.asked.0.remove(&to) else {
            return Ok(Err(nobody()));
        };
        let text = text.trim();
        // The asker has it before the line says so: withdrawn in the
        // meantime, nothing is said.
        if waiting.answer.send(Ok(text.to_owned())).is_err() {
            return Ok(Err(nobody()));
        }
        let from = waiting.from;
        let said = format!("answered {from}:\n{text}");
        self.host_line(said, Some(to), origin).await?;
        info!(conversation = %self.place.conversation, to = %from.conversation, line = %to, "Max answers another conversation");
        Ok(Ok(from.to_string()))
    }

    /// The wait of question job `job` is over: a line says here what
    /// was answered, or that nothing was and why, and wakes Max with it.
    pub(super) async fn question_answered(
        &mut self,
        job: u32,
        answer: Result<String, String>,
    ) -> Result<()> {
        // Withdrawn since.
        let Some((to, asked)) = self.question_over(job) else {
            return Ok(());
        };
        info!(conversation = %self.place.conversation, job, answered = answer.is_ok(), "a question's wait is over");
        let said = match answer {
            Ok(text) => format!("{to} answered:\n{text}"),
            Err(why) => format!("{to} didn't answer: {why}"),
        };
        let Some(line) = self.host_line(said, Some(asked), None).await? else {
            return Ok(());
        };
        self.wake_at(&line, Reason::Job { job }).await
    }

    /// A line maxx says here on Max's account, in a text code block as a
    /// command's answer is: the row. What it shows was written in another
    /// conversation, so nothing in it is read as Markdown.
    async fn host_line(
        &mut self,
        body: String,
        reply_to: Option<MessageId>,
        turn: Option<TurnId>,
    ) -> Result<Option<Arc<Message>>> {
        let draft = Draft {
            reply_to,
            nodes: vec![DraftNode::Text {
                text: command::fenced("text", &body),
            }],
        };
        self.say_row(draft, turn, None, By::Host, None).await
    }
}

#[cfg(test)]
mod tests;
