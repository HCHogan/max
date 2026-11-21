//! `shell`: a command the turn waits for, to its end or its limit; and
//! with `background`, one it doesn't wait for, whose end the guest tells
//! Max of (`maxx jobs start`, `max-notify@`). See "Background commands" in
//! docs/design/jobs.md.

use std::time::Duration;

use color_eyre::eyre::{Result, WrapErr};
use serde::{Deserialize, Serialize};

use super::{Call, Ran, Told, jobs, last_line, shown, start_of, wait, with};
use crate::vm::Vm;

/// What the model is told of the command: it failed if it didn't finish.
pub(super) async fn shell(
    vm: &Vm,
    command: &str,
    workdir: Option<&str>,
    limit: Duration,
) -> Result<Told> {
    let call = Call {
        title: None,
        workdir,
        limit,
        split: false,
    };
    let ended = wait(vm, call, command, None).await?;
    if let Some(why) = &ended.failed {
        return Ok(Told {
            text: format!("the command didn't run: {}", why.trim()),
            error: true,
            left: Vec::new(),
        });
    }
    let output = shown(ended.out.as_ref());
    let (text, error) = match ended.ran() {
        Ran::Exited(status) => (with(format!("exit status {status}"), &output), false),
        Ran::OutOfTime => (with(out_of_time(limit), &output), true),
        Ran::Killed(how) => (with(format!("ended by {how}"), &output), true),
    };
    Ok(Told {
        text,
        error,
        left: ended.shown,
    })
}

/// What `maxx jobs start` is asked for: a background command's unit.
#[derive(Serialize)]
struct Start<'a> {
    /// In seconds.
    limit: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    workdir: Option<&'a str>,
    command: &'a str,
}

/// What it says of the unit it started.
#[derive(Deserialize)]
struct Started {
    /// The unit's name, the guest's to give: `max-job-…`.
    unit: String,
    /// The file its output is written to as it runs, in the guest.
    out: String,
}

/// Starts `command` in the background, for at most `limit`: what the
/// model is told of it. It is no call, and has nobody to show a picture
/// to.
pub(super) async fn start(
    vm: &Vm,
    command: &str,
    workdir: Option<&str>,
    limit: Duration,
) -> Result<String> {
    let asked = Start {
        limit: limit.as_secs(),
        workdir,
        command,
    };
    let said = vm.ask(&jobs("start", &asked)).await?;
    let line = last_line(said.as_bytes());
    let Started { unit, out } = serde_json::from_slice(line)
        .wrap_err_with(|| format!("maxx jobs start said {:?}", start_of(line)))?;
    Ok(format!(
        "It runs in the background as {unit}, for at most {}. When it ends, its exit status and \
         output come back to you as [{unit} 完成]: don't sleep waiting for it, and don't keep \
         checking. Its output is written to {out} as it runs: to see how far it is, read the end \
         of that; if it isn't wanted any more, stop it with systemctl stop {unit}.",
        span(limit)
    ))
}

/// How long, as the model is told it.
fn span(limit: Duration) -> String {
    let seconds = limit.as_secs();
    match seconds {
        0..60 => format!("{seconds} seconds"),
        60..3600 => format!("{} minutes", seconds / 60),
        _ => format!("{} hours {} minutes", seconds / 3600, seconds % 3600 / 60),
    }
}

/// What a call at its limit is told.
pub(super) fn out_of_time(limit: Duration) -> String {
    format!("not done in {} seconds; it was stopped", limit.as_secs())
}
