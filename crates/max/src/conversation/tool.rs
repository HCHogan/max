//! The tool call task: one per call in `Step::RunTools`, in the core's `io`
//! scope. It ends with exactly one `ToolDone`.

use max_core::item::ToolOutput;
use max_core::tools::Call;
use tokio::sync::mpsc::UnboundedSender;

use super::report::Report;
use super::{Event, TaskId};
use crate::mcp;
use crate::tools::{self, Waiting};
use crate::vm::Vms;

pub async fn call(
    vms: Option<Vms>,
    context: mcp::Context,
    call: Call,
    task: TaskId,
    mailbox: UnboundedSender<Event>,
    waiting: Waiting,
) {
    let id = call.id.clone();
    let report = Report::new(mailbox, move || Event::ToolDone {
        task,
        call: id,
        out: ToolOutput::text("the tool call broke off without a result", true, 20),
    });
    let out = tools::run(call.tool, vms.as_ref(), context, Some(waiting)).await;
    report.send(Event::ToolDone {
        task,
        call: call.id,
        out,
    });
}
