//! Calls from the group's VM: Max's tools, run beside the core. Every
//! call comes this way, a turn's program's and a unit's of Max's own
//! alike, and each leaves a line in the log: a turn's run holds only the
//! programs, and what agents and units call is written nowhere else. See
//! "The guest's calls" in docs/design/tools.md.

use std::sync::Arc;

use serde_json::Value;
use tokio::sync::oneshot;
use tokio::time::Instant;
use tracing::info;

use super::{Conversation, Does};
use crate::conversation::Poster;
use crate::{service, vm};

impl Conversation {
    /// A call of `tool` from the VM; the result goes to `reply`. The call
    /// ends at the conversation's call time, or once nobody waits for it:
    /// the caller closed its connection, as when its unit is stopped.
    pub(super) fn program_call(
        &mut self,
        tool: String,
        args: Value,
        mut reply: oneshot::Sender<Result<Value, service::Failure>>,
    ) {
        // What it would say or do in the chat is refused as it comes.
        if let Some(refused) = self.refuses(Does::RUNS) {
            let _ = reply.send(Err(service::Failure::new("refused", refused.to_string())));
            return;
        }
        let work = self
            .shared
            .vm_dir
            .as_deref()
            .map(|dir| vm::work(dir, self.place.conversation));
        let context = service::Context {
            services: Arc::clone(&self.shared.services),
            place: Arc::clone(&self.place),
            page_tokens: self.single(),
            work,
            call_time: self.call_time(),
            poster: Some(Poster::new(self.mailbox.clone())),
        };
        let conversation = self.place.conversation;
        self.side.spawn(move |_| async move {
            let started = Instant::now();
            let outcome = tokio::select! {
                outcome = service::call(&tool, &context, args) => Some(outcome),
                () = reply.closed() => None,
            };
            // Not the arguments or the result: they are the program's.
            info!(
                %conversation,
                tool,
                took_ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
                outcome = match &outcome {
                    Some(Ok(_)) => "ok",
                    Some(Err(failure)) => failure.code,
                    None => "dropped",
                },
                "a program's call ends"
            );
            if let Some(outcome) = outcome {
                let _ = reply.send(outcome);
            }
        });
    }
}
