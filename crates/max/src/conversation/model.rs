//! The model call task: one per `Step::CallModel`, in the core's `io`
//! scope. It streams the response through the segmenter, sends each
//! message it cuts as `Said`, and ends with exactly one `ModelDone`.

use std::sync::Arc;
use std::time::Duration;

use max_core::run::Request;
use max_core::segment::Segmenter;
use tokio::sync::mpsc::UnboundedSender;
use tracing::warn;

use super::report::Report;
use super::{Event, TaskId};
use crate::llm::Chosen;
use crate::media::pictures::Pictures;

/// The longest wait before a retry.
const MAX_BACKOFF: Duration = Duration::from_secs(8);

pub async fn call(
    chosen: Chosen,
    pictures: Option<Arc<Pictures>>,
    request: Request,
    task: TaskId,
    mailbox: UnboundedSender<Event>,
) {
    let report = Report::new(mailbox.clone(), move || Event::ModelDone {
        task,
        out: Err("the model call ended without a result".into()),
    });
    let pictures = match pictures {
        Some(pictures) => pictures.read(&request).await,
        None => max_llm::Pictures::default(),
    };
    let mut attempt = 0;
    let out = loop {
        let mut said = false;
        match once(&chosen, &request, &pictures, task, &mailbox, &mut said).await {
            Ok(out) => break Ok(out),
            // Once something is said a retry would say it again.
            Err(error) if !said && error.retryable() && attempt < chosen.retries => {
                let wait = backoff(attempt);
                warn!(%task, model = %chosen.reference(), %error, ?wait, "retrying the model call");
                tokio::time::sleep(wait).await;
                attempt += 1;
            }
            Err(error) => break Err(error.to_string()),
        }
    };
    report.send(Event::ModelDone { task, out });
}

async fn once(
    chosen: &Chosen,
    request: &Request,
    pictures: &max_llm::Pictures,
    task: TaskId,
    mailbox: &UnboundedSender<Event>,
    said: &mut bool,
) -> Result<max_core::item::ModelOutput, max_llm::Error> {
    let mut call = chosen
        .caller
        .call(request, &chosen.options, pictures)
        .await?;
    let mut segmenter = Segmenter::new(request.roster.clone());
    let mut say = |segments: Vec<max_core::segment::Segment>| {
        for segment in segments {
            *said = true;
            let _ = mailbox.send(Event::Said { task, segment });
        }
    };
    while let Some(delta) = call.next().await? {
        say(segmenter.push(&delta));
    }
    let out = call.finish()?;
    say(segmenter.finish());
    Ok(out)
}

/// 1s, 2s, 4s, then 8s.
fn backoff(attempt: u32) -> Duration {
    Duration::from_secs(1 << attempt.min(3)).min(MAX_BACKOFF)
}

#[cfg(test)]
mod tests;
