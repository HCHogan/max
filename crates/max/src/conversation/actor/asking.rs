//! Max here asks Max in another conversation, and is asked by one: the
//! question's way between the two actors. Neither the question nor the
//! answer is said in a chat: each reaches the other side's Max as a wake's
//! item, as a job's report does. See "Asking another conversation" in
//! docs/rust-rewrite.md.

use std::collections::BTreeMap;

use max_core::item::Item;
use max_core::limits;
use max_db::links::{self, Peer};
use tokio::sync::oneshot;

use super::jobs::fitted;
use super::links::peer;
use super::*;
use crate::conversation::Question;

/// What Max in other conversations asked Max here and still waits to
/// hear, by the number each question got here. Forgotten with the actor.
#[derive(Default)]
pub(super) struct Asked {
    waiting: BTreeMap<u32, Waiting>,
    /// Questions are numbered within the conversation while max runs.
    last: u32,
}

/// A question, who waits on it, and where its answer goes.
struct Waiting {
    from: Peer,
    text: String,
    answer: oneshot::Sender<Result<String, String>>,
}

/// How a question put to Max here is named to it.
pub fn name(question: u32) -> String {
    format!("ask#{question}")
}

impl Asked {
    /// Tells everyone who waits that no answer comes, and why.
    pub(super) fn refuse(&mut self, why: &str) {
        for (_, waiting) in std::mem::take(&mut self.waiting) {
            let _ = waiting.answer.send(Err(why.to_owned()));
        }
    }

    /// The questions someone still waits on.
    fn open(&self) -> impl Iterator<Item = (u32, &Waiting)> {
        let waiting = self.waiting.iter();
        waiting
            .filter(|(_, waiting)| !waiting.answer.is_closed())
            .map(|(number, waiting)| (*number, waiting))
    }

    /// For `/status`: the questions someone still waits on.
    pub(super) fn summary(&self) -> Option<String> {
        let open: Vec<String> = self
            .open()
            .map(|(number, waiting)| format!("{} from {}", name(number), waiting.from))
            .collect();
        (!open.is_empty()).then(|| open.join(" · "))
    }

    /// For a new core, which saw none of them asked: a line for each
    /// question someone still waits on, the question on one line.
    pub(super) fn lines(&self) -> Vec<String> {
        self.open()
            .map(|(number, waiting)| {
                let text = waiting.text.replace('\n', " ⏎ ");
                format!("{} {}：{text}", name(number), waiting.from)
            })
            .collect()
    }
}

impl Conversation {
    /// Max's `ask`: the question goes to that conversation's actor, and a
    /// job waits for the answer. The job's number, or why nothing was
    /// asked.
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
        let job = self.question_job(to, question, answered);
        info!(conversation = %here, job, "Max asks another conversation");
        Ok(Ok(job))
    }

    /// Max in another conversation asks Max here: the question wakes Max,
    /// in the running core or a new one, and the asker waits until
    /// `answer` names it. Stopped, Max here isn't told.
    pub(super) async fn take_question(&mut self, question: Question) -> Result<()> {
        if self.stopping.is_some() {
            question.refuse("那边的 Max 正在重启");
            return Ok(());
        }
        if self.settings.stopped {
            question.refuse(STOPPED_THERE);
            return Ok(());
        }
        let Question { from, text, answer } = question;
        self.asked.last += 1;
        let number = self.asked.last;
        info!(conversation = %self.place.conversation, from = %from.conversation, question = number, "Max is asked from another conversation");
        let item = put(number, &from, &text, self.single());
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
    pub(super) fn answer_question(
        &mut self,
        to: u32,
        text: &str,
        origin: Option<TurnId>,
    ) -> Result<String, String> {
        if let Some(refused) = self.ended(origin).or_else(|| self.stopped()) {
            return Err(refused);
        }
        let nobody = || {
            format!(
                "没有人在等 {} 的回答：没有这个编号，或者已经答过了、对方撤回了、等到点了、Max 重启过。这次没送出去",
                name(to)
            )
        };
        let waiting = self.asked.waiting.remove(&to).ok_or_else(nobody)?;
        let sent = waiting.answer.send(Ok(text.trim().to_owned()));
        sent.map_err(|_| nobody())?;
        let from = waiting.from;
        info!(conversation = %self.place.conversation, to = %from.conversation, question = to, "Max answers another conversation");
        Ok(from.to_string())
    }

    /// The wait of question job `job` is over: Max hears what was
    /// answered, or that nothing was and why, in the running core or a new
    /// one.
    pub(super) async fn question_answered(
        &mut self,
        job: u32,
        answer: Result<String, String>,
    ) -> Result<()> {
        // Withdrawn since.
        let Some((to, question)) = self.question_over(job) else {
            return Ok(());
        };
        info!(conversation = %self.place.conversation, job, answered = answer.is_ok(), "a question's wait is over");
        let item = heard(job, &to, &question, &answer, self.single());
        self.wake_with(Reason::Job { job }, item).await
    }

    /// What a new core is shown of the questions asked before it started.
    pub(super) fn questions_waiting(&self) -> Vec<String> {
        self.asked.lines()
    }
}

/// Why a conversation that is stopped doesn't answer.
pub(super) const STOPPED_THERE: &str = "那边被 /stop 停了，Max 不回话";

/// What Max is shown when question `number` comes from `from`.
fn put(number: u32, from: &Peer, text: &str, single: u32) -> Item {
    let text = format!(
        "[{} 问] {from}\n{}\n（那个会话的 Max 在等你回答：用 answer 回答，to 填 {}；{} 小时内没答它就不等了。这个问题和你的回答都不会发到这边的聊天里）",
        name(number),
        fitted(text, single),
        name(number),
        limits::JOB_TIME.as_secs() / 3600,
    );
    let tokens = tokens::count(&text);
    Item::new(ItemKind::user(text), tokens)
}

/// What Max is shown when the wait of question job `job`, put to `to`,
/// is over: the question again, since the core that asked may be gone,
/// and the answer, or why there is none.
fn heard(
    job: u32,
    to: &Peer,
    question: &str,
    answer: &Result<String, String>,
    single: u32,
) -> Item {
    let job = crate::job::name(job);
    let question = fitted(question, single);
    let text = match answer {
        Ok(answer) => format!(
            "[{job} 回答] {to}\n问：{question}\n答：{}",
            fitted(answer, single)
        ),
        Err(why) => format!("[{job} 没答成] {to}：{why}\n问：{question}"),
    };
    let tokens = tokens::count(&text);
    Item::new(ItemKind::user(text), tokens)
}

#[cfg(test)]
mod tests;
