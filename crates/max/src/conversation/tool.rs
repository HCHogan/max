//! The tool call task: one per call in `Step::RunTools`, in the core's `io`
//! scope. It ends with exactly one `ToolDone`.

use max_core::ids::CallId;
use max_core::item::ToolOutput;
use max_core::tools::Call;
use tokio::sync::mpsc::UnboundedSender;

use super::{Event, TaskId};
use crate::mcp;
use crate::tools;
use crate::vm::Vms;

/// Sends the task's `ToolDone`: the result when it ends, or from `Drop`
/// when the task is aborted or panics, so the actor never waits for a call
/// that is gone.
struct Report {
    task: TaskId,
    call: CallId,
    mailbox: UnboundedSender<Event>,
    sent: bool,
}

impl Report {
    fn done(mut self, out: ToolOutput) {
        self.sent = true;
        let _ = self.mailbox.send(Event::ToolDone {
            task: self.task,
            call: self.call.clone(),
            out,
        });
    }
}

impl Drop for Report {
    fn drop(&mut self) {
        if !self.sent {
            let _ = self.mailbox.send(Event::ToolDone {
                task: self.task,
                call: self.call.clone(),
                out: ToolOutput::text("工具调用中途断了，没有结果。", true, 20),
            });
        }
    }
}

pub async fn call(
    vms: Option<Vms>,
    context: mcp::Context,
    call: Call,
    task: TaskId,
    mailbox: UnboundedSender<Event>,
) {
    let report = Report {
        task,
        call: call.id,
        mailbox,
        sent: false,
    };
    let out = tools::run(call.tool, vms.as_ref(), context).await;
    report.done(out);
}
