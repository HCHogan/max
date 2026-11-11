//! `shell` with `background`: a command the conversation's actor runs as
//! a job, and how a background command's end is told, a moved one's too.

use super::output::OUT;
use super::*;

/// A `shell` call to run in the background, as its conversation's actor
/// gets it: the actor runs it with [`background`] and wakes Max when it
/// ends. See "Background commands" in docs/rust-rewrite.md.
#[derive(Debug)]
pub struct Background {
    pub command: String,
    pub workdir: Option<String>,
    pub limit: Duration,
    /// Its unit in the guest, and so its output file's name.
    pub unit: String,
}

/// Has the conversation start `command` as a background job: what the
/// model is shown, and whether it couldn't.
pub(super) async fn started(
    context: &mcp::Context,
    command: String,
    workdir: Option<String>,
    limit: Duration,
) -> (String, bool) {
    let Some(poster) = context.caller.poster() else {
        return (
            "commands can't run in the background from here".to_owned(),
            true,
        );
    };
    let unit = Vm::unit();
    let file = format!("/work/{OUT}/{unit}.txt");
    let shell = Background {
        command,
        workdir,
        limit,
        unit,
    };
    match poster.shell(shell).await {
        Ok(number) => {
            let shell = Handle::Shell(number);
            let shown = format!(
                "It runs in the background as {shell}, for at most {} minutes. {}",
                limit.as_secs().div_ceil(60),
                follow(shell, &file),
            );
            (shown, false)
        }
        Err(why) => (why, true),
    }
}

/// Runs a background command in `conversation`'s VM until it ends or
/// runs out of time: how it went, its exit status and its output.
pub async fn background(vms: Vms, conversation: ConversationId, shell: Background) -> Finished {
    let begun = Instant::now();
    // Held until the command ends, the VM isn't idle meanwhile.
    let vm = match vms.get(conversation).await {
        Ok(vm) => vm,
        Err(why) => return failed(why),
    };
    let mut output = Output::new(vm.work(), format!("{}.txt", shell.unit));
    // Whole from the start, for the model to follow along.
    if let Err(error) = output.create().await {
        return failed(format!("{error:#}"));
    }
    // It outlives the turn, and so any run's token.
    let workdir = shell.workdir.as_deref();
    let started = start_in(&vm, shell.unit, &shell.command, workdir, None, shell.limit).await;
    let ran = match started {
        Ok(running) => {
            let deadline = Instant::now() + shell.limit;
            wait_until(&vm, running, &mut output, deadline).await
        }
        Err(error) => Err(error),
    };
    finished(ran, &output, begun, shell.limit)
}

/// A background command's end, as `ran` says: it began at `begun`, had
/// `limit`, and printed `output`.
pub(super) fn finished(
    ran: Result<Ran>,
    output: &Output,
    begun: Instant,
    limit: Duration,
) -> Finished {
    let (how, head) = match ran {
        Err(error) => return failed(format!("{error:#}")),
        Ok(Ran::Exited(status)) => (
            How::Done,
            format!("{}, ran for {}", exited(status), took(begun.elapsed())),
        ),
        Ok(Ran::OutOfTime(stopped)) => (
            How::OutOfTime,
            format!(
                "not done in {} minutes; {}",
                limit.as_secs().div_ceil(60),
                stopping(&stopped)
            ),
        ),
    };
    Finished {
        ending: Ending {
            how,
            text: Some(with(head, &output.shown())),
            unsent: 0,
        },
        file: None,
    }
}

/// A background command that couldn't run, and `why`.
pub(super) fn failed(why: String) -> Finished {
    Finished {
        ending: Ending {
            how: How::Failed(why),
            text: None,
            unsent: 0,
        },
        file: None,
    }
}
