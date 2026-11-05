//! Calls from the programs Max keeps in the group's VM, outside any turn:
//! Max's tools, run beside the core. See "常驻程序" in
//! docs/rust-rewrite.md.

use serde_json::Value;
use tokio::sync::oneshot;

use super::*;

impl Conversation {
    /// A program's call of `tool`; the result goes to `reply`.
    pub(super) fn program_call(
        &mut self,
        tool: String,
        args: Value,
        reply: oneshot::Sender<Result<Value, mcp::Failure>>,
    ) {
        if self.stopping.is_some() {
            let _ = reply.send(Err(mcp::Failure::new("closed", "Max 正在重启，没做")));
            return;
        }
        let work = self
            .shared
            .vm_dir
            .as_deref()
            .map(|dir| vm::work(dir, self.place.conversation));
        let context = mcp::Context {
            services: Arc::clone(&self.shared.services),
            place: Arc::clone(&self.place),
            page_tokens: self.single(),
            video: false,
            work,
            caller: mcp::Caller::Program(Poster::program(self.mailbox.clone())),
        };
        self.side.spawn(move |_| async move {
            let _ = reply.send(mcp::program_call(&tool, &context, args).await);
        });
    }
}
