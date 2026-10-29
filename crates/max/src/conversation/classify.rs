//! The intent classifier task: one at a time per conversation, in the
//! actor's `side` scope. It reads the context from the ledger, asks the
//! small model, records the call, and answers with one `Verdict`, None if
//! anything failed. The prompt and the parse are max-core's.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use chrono::FixedOffset;
use color_eyre::eyre::{Result, eyre};
use max_core::ids::{MessageId, PrincipalId};
use max_core::intent::Verdict;
use max_core::intent::classify;
use max_core::item::{Item, ItemKind};
use max_core::message::Message;
use max_core::project::{self, Budgets};
use max_core::render::{Mark, Render};
use max_core::run::Request;
use max_db::{PgPool, ledger, platform, usage};
use tokio::sync::mpsc::UnboundedSender;
use tracing::warn;

use super::project::{direct_mark, people, shown_line};
use super::{Event, Place};
use crate::llm::Chosen;

/// Enough for the one line of JSON.
const MAX_OUTPUT: u32 = 300;
/// The longest a verdict may take; the batch waits for it.
const CALL: Duration = Duration::from_secs(60);

/// Rows of context the classifier reads before the ones it judges.
pub const CONTEXT_LINES: i64 = 15;

pub struct Job {
    pub pool: PgPool,
    pub place: Arc<Place>,
    pub chosen: Chosen,
    pub persona: String,
    pub batch: Vec<MessageId>,
    pub context_lines: i64,
    pub offset: FixedOffset,
}

/// Sends the `Verdict`, or None from `Drop` if the task never got there.
struct Report {
    mailbox: UnboundedSender<Event>,
    verdict: Option<Option<Verdict>>,
}

impl Drop for Report {
    fn drop(&mut self) {
        let verdict = self.verdict.take().flatten();
        let _ = self.mailbox.send(Event::Verdict(verdict));
    }
}

pub async fn classify(job: Job, mailbox: UnboundedSender<Event>) {
    let mut report = Report {
        mailbox,
        verdict: None,
    };
    match run(&job).await {
        Ok(verdict) => report.verdict = Some(verdict),
        Err(error) => warn!(conversation = %job.place.conversation, %error, "classifying failed"),
    }
}

async fn run(job: &Job) -> Result<Option<Verdict>> {
    let Some(first) = job.batch.first() else {
        return Ok(None);
    };
    let place = &job.place;
    let mut conn = job.pool.acquire().await?;
    let mut new = Vec::new();
    for id in &job.batch {
        if let Some(row) = ledger::row(&mut conn, place.conversation, *id).await? {
            let mark = direct_mark(&mut conn, place, &row.message).await?;
            new.push((row.message, mark));
        }
    }
    let context: Vec<(Message, Mark)> =
        ledger::recent(&mut conn, place.conversation, *first, job.context_lines)
            .await?
            .into_iter()
            .map(|row| (row.message, Mark::None))
            .collect();
    let messages = context.iter().chain(&new).map(|(message, _)| message);
    let people = people(&mut conn, messages, place).await?;

    let render = Render {
        people: &people,
        offset: job.offset,
    };
    let single = Budgets::for_window(job.chosen.window).single;
    let lines = |rows: &[(Message, Mark)]| {
        rows.iter()
            .map(|(message, mark)| shown_line(&render, message, *mark, single))
            .collect::<Vec<_>>()
            .join("\n")
    };
    let (context, new) = (lines(&context), lines(&new));
    // Whom each @ is to, by name.
    let mentioned: Vec<PrincipalId> = project::mentioned(&format!("{context}\n{new}"))
        .into_iter()
        .collect();
    let known = platform::roster(&mut conn, place.endpoint, &mentioned).await?;
    let mut names: BTreeMap<PrincipalId, String> = known
        .into_iter()
        .map(|known| (known.principal, known.name))
        .collect();
    names.insert(place.me.principal, place.my_name.clone());
    drop(conn);
    let system = classify::system(&job.persona);
    let user = classify::user(
        &classify::named(&context, &names),
        &classify::named(&new, &names),
    );
    let request = Request {
        model: job.chosen.tag.clone(),
        items: vec![
            Item::new(ItemKind::System { text: system }, 0),
            Item::new(ItemKind::user(user), 0),
        ],
        tools: &[],
        max_output: Some(MAX_OUTPUT),
        roster: Default::default(),
    };
    let (purpose, pictures) = (usage::Purpose::Intent, max_llm::Pictures::default());
    let text = job
        .chosen
        .complete(
            &job.pool,
            purpose,
            Some(place.conversation),
            &request,
            &pictures,
            CALL,
        )
        .await?;
    let verdict = classify::parse(&text);
    if verdict.is_none() {
        return Err(eyre!("the classifier answered {text:.200}"));
    }
    Ok(verdict)
}

#[cfg(test)]
mod tests;
