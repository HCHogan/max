//! Calls from the group's VM: Max's tools, run beside the core. Every
//! call comes this way, a turn's program's and a unit's of Max's own
//! alike. See "The guest's calls" in docs/rust-rewrite.md.

use serde_json::Value;
use tokio::sync::oneshot;

use super::*;

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
            let _ = reply.send(Err(service::Failure::new("refused", refused.why())));
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
        self.side.spawn(move |_| async move {
            let outcome = tokio::select! {
                outcome = service::call(&tool, &context, args) => outcome,
                () = reply.closed() => return,
            };
            let _ = reply.send(outcome);
        });
    }
}
