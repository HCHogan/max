//! The questions Max here put to Max in another conversation, and whose
//! answers it waits for (`ask#5`): started by its turns, outliving the
//! core that asked, and waking Max when the answer comes, or won't. What
//! runs in the group's VM is not here: a background command and a
//! background agent are units of the guest's, which tell Max of their end
//! themselves. See "Asking another conversation" and "Lifetimes move to
//! systemd" in docs/rust-rewrite.md.

use std::collections::BTreeMap;

use max_db::links::Peer;
use tokio::sync::oneshot;

use super::*;
use crate::conversation::Waits;
use crate::tools::headline;
use max_core::limits;

/// The questions that wait, by number.
#[derive(Default)]
pub(super) struct Jobs {
    waiting: BTreeMap<u32, Waiting>,
    /// The last number: questions count together whichever way they go,
    /// so that `ask#5` is one question here.
    last: u32,
}

/// A question put to Max in another conversation: which, and what was
/// asked, for the core that hears the answer.
struct Waiting {
    to: Peer,
    question: String,
    started: Instant,
    /// Dropping it ends the wait.
    _task: Scope,
}

impl Waiting {
    fn title(&self) -> String {
        format!("? {}: {}", self.to, headline(&self.question))
    }
}

impl Conversation {
    /// Withdraws `handle`, asked from here: nobody hears of it again. A
    /// question asked of Max here is declined: whoever asked hears so.
    pub(super) fn cancel_job(&mut self, handle: Handle) -> Result<(), String> {
        let Handle::Ask(number) = handle else {
            return Err(over(handle));
        };
        if self.decline(number) {
            info!(conversation = %self.place.conversation, %handle, "a question is declined");
            return Ok(());
        }
        if self.jobs.waiting.remove(&number).is_none() {
            return Err(over(handle));
        }
        info!(conversation = %self.place.conversation, %handle, "a question is withdrawn");
        Ok(())
    }

    /// `handle` as it waits, or every question that does.
    pub(super) fn jobs_running(&self, handle: Option<Handle>) -> Result<Vec<Waits>, String> {
        let waiting = self.jobs.waiting.iter();
        let jobs: Vec<Waits> = waiting
            .filter(|(number, _)| handle.is_none_or(|handle| handle == Handle::Ask(**number)))
            .map(|(number, waiting)| Waits {
                handle: Handle::Ask(*number).to_string(),
                title: waiting.title(),
                minutes: waiting.started.elapsed().as_secs() / 60,
            })
            .collect();
        match handle {
            Some(handle) if jobs.is_empty() => Err(over(handle)),
            _ => Ok(jobs),
        }
    }

    /// Waits for the answer to `question`, put to Max in `to`: its
    /// number. The wait ends with the answer, or with why none comes;
    /// withdrawn, nobody is told, and an answer finds nobody waiting.
    pub(super) fn question_job(
        &mut self,
        to: Peer,
        question: &str,
        answered: oneshot::Receiver<Result<String, String>>,
    ) -> u32 {
        let number = self.jobs.next_ask();
        let mailbox = self.mailbox.clone();
        let mut task = Scope::new();
        task.spawn(move |_| async move {
            let answer = match tokio::time::timeout(limits::ASK_WAIT, answered).await {
                Ok(Ok(answer)) => answer,
                // The question was dropped on its way, or with the actor
                // that held it.
                Ok(Err(_)) => Err("Max there stopped before answering".to_owned()),
                Err(_) => Err(format!(
                    "no answer in {} hours",
                    limits::ASK_WAIT.as_secs() / 3600
                )),
            };
            let _ = mailbox.send(Event::Answered {
                ask: number,
                answer,
            });
        });
        let waiting = Waiting {
            to,
            question: question.to_owned(),
            started: Instant::now(),
            _task: task,
        };
        self.jobs.waiting.insert(number, waiting);
        number
    }

    /// Ends the wait of question `ask`: whom it was put to, and the
    /// question. None if it was withdrawn since.
    pub(super) fn question_over(&mut self, ask: u32) -> Option<(Peer, String)> {
        let waiting = self.jobs.waiting.remove(&ask)?;
        Some((waiting.to, waiting.question))
    }

    /// Ends every wait, for `/kill`: their handles.
    pub(super) fn cancel_jobs(&mut self) -> Vec<Handle> {
        let waiting = std::mem::take(&mut self.jobs.waiting);
        waiting.into_keys().map(Handle::Ask).collect()
    }

    /// A line a question, for `/status`.
    pub(super) fn job_lines(&self) -> Vec<String> {
        let waiting = self.jobs.waiting.iter();
        waiting
            .map(|(number, waiting)| {
                format!(
                    "{} · {}m · {}",
                    Handle::Ask(*number),
                    waiting.started.elapsed().as_secs() / 60,
                    waiting.title()
                )
            })
            .collect()
    }

    /// The most tokens one item may take: the running core's, or the
    /// next one's.
    pub(super) fn single(&self) -> u32 {
        let settings = &self.settings;
        let window = match &self.core {
            Some(a) => Some(a.chosen.window),
            None => self
                .shared
                .models
                .turn(settings.model.as_deref(), settings.effort.as_deref())
                .ok()
                .map(|chosen| chosen.window),
        };
        Budgets::for_window(window.unwrap_or(0)).single
    }
}

#[cfg(test)]
impl Jobs {
    /// A question as if put to conversation `to`, with nobody behind it
    /// to answer: its number.
    pub(super) fn pretend(&mut self, to: i64, question: &str) -> u32 {
        let number = self.next_ask();
        let waiting = Waiting {
            to: Peer {
                conversation: ConversationId(to),
                title: None,
            },
            question: question.to_owned(),
            started: Instant::now(),
            _task: Scope::new(),
        };
        self.waiting.insert(number, waiting);
        number
    }
}

impl Jobs {
    /// Whether `handle` waits for its answer.
    pub(super) fn has(&self, handle: Handle) -> bool {
        matches!(handle, Handle::Ask(number) if self.waiting.contains_key(&number))
    }

    /// The next question's number, whichever way it goes.
    pub(super) fn next_ask(&mut self) -> u32 {
        self.last += 1;
        self.last
    }
}

fn over(handle: Handle) -> String {
    match handle {
        Handle::Ask(_) => format!(
            "{handle} isn't waiting for an answer: it was answered, withdrawn or out of time, or never was"
        ),
        // As they were named until 2026-11-12.
        Handle::Agent(number) => format!(
            "a background agent is a unit of the VM's: max-jobs list shows them, and systemctl stop max-agent-{number} stops one"
        ),
    }
}
