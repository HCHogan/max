//! Calls from the programs Max keeps in the group's VM, outside any turn:
//! Max's tools, run beside the core. See "Resident programs" in
//! docs/rust-rewrite.md.

use serde_json::Value;
use tokio::sync::oneshot;

use super::*;

impl Conversation {
    /// A program's call of `tool`; the result goes to `reply`. The call
    /// ends at the conversation's call time, or once nobody waits for it:
    /// the program closes its connection, as a turn's call ends then.
    pub(super) fn program_call(
        &mut self,
        tool: String,
        args: Value,
        mut reply: oneshot::Sender<Result<Value, mcp::Failure>>,
    ) {
        // What it would say or do in the chat is refused as it comes.
        if let Some(refused) = self.refuses(None, Does::RUNS) {
            let _ = reply.send(Err(mcp::Failure::new("refused", refused.why())));
            return;
        }
        let work = self
            .shared
            .vm_dir
            .as_deref()
            .map(|dir| vm::work(dir, self.place.conversation));
        let caller = mcp::Caller::Program(Poster::program(self.mailbox.clone()));
        let (pages, call_time) = (self.single(), self.call_time());
        let services = &self.shared.services;
        let context = mcp::Context {
            work,
            ..mcp::Context::new(services, &self.place, caller, pages, call_time)
        };
        self.side.spawn(move |_| async move {
            let outcome = tokio::select! {
                outcome = mcp::program_call(&tool, &context, args) => outcome,
                () = reply.closed() => return,
            };
            let _ = reply.send(outcome);
        });
    }
}
