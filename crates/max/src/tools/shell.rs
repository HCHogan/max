//! `shell`: a command the turn waits for, to its end or its limit; and
//! with `background`, one it doesn't wait for, whose end the guest tells
//! Max of (`maxx units start`, `max-notify@`). See "Lifetimes move to
//! systemd" in docs/rust-rewrite.md.

use super::*;

/// What the model is told of the command: it failed if it didn't finish.
pub(super) async fn shell(
    vm: &Vm,
    command: &str,
    workdir: Option<&str>,
    limit: Duration,
) -> Result<Told> {
    let unit = Unit {
        title: &title(command),
        workdir: &guest_dir(workdir),
        limit,
        split: false,
    };
    let ended = wait(vm, unit, command, None).await?;
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

/// What `maxx units start` is asked for: a background command's unit.
#[derive(Serialize)]
struct Start<'a> {
    unit: &'a str,
    /// In seconds.
    limit: u64,
    title: &'a str,
    workdir: &'a str,
    command: &'a str,
}

/// What it says of the unit it started.
#[derive(Deserialize)]
struct Started {
    said: String,
}

/// Starts `command` in the background, for at most `limit`: what the
/// model is told of it, in the guest's words, which are the same for
/// whatever starts one. It is no call, and has nobody to show a picture
/// to.
pub(super) async fn start(
    vm: &Vm,
    command: &str,
    workdir: Option<&str>,
    limit: Duration,
) -> Result<String> {
    let unit = Vm::unit();
    let asked = Start {
        unit: &unit,
        limit: limit.as_secs(),
        title: &title(command),
        workdir: &guest_dir(workdir),
        command,
    };
    let said = vm.ask(&maxx("units start", &asked)).await?;
    let line = last_line(said.as_bytes());
    let started: Started = serde_json::from_slice(line)
        .wrap_err_with(|| format!("maxx units start said {:?}", start_of(line)))?;
    Ok(started.said)
}

/// What a call at its limit is told.
pub(super) fn out_of_time(limit: Duration) -> String {
    format!("not done in {} seconds; it was stopped", limit.as_secs())
}

/// A command, as the guest lists it and its notice names it.
fn title(command: &str) -> String {
    format!("$ {}", headline(command))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_command_is_titled_by_its_first_line() {
        assert_eq!(title("make -j8\nmake install"), "$ make -j8");
    }
}
