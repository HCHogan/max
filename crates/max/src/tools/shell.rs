//! `shell`: a command the turn waits for, to its end or its limit; and
//! with `background`, one it doesn't wait for, whose end the guest tells
//! Max of (`max-jobs start`, `max-notify@`). See "Lifetimes move to
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

/// Starts `command` in the background, for at most `limit`: what the
/// model is told of it. It is no call, and has nobody to show a picture
/// to.
pub(super) async fn start(
    vm: &Vm,
    command: &str,
    workdir: Option<&str>,
    limit: Duration,
) -> Result<String> {
    let unit = Vm::unit();
    let line = format!(
        "max-jobs start --unit {unit} --limit {} --title {} --workdir {} -- bash -lc {}",
        limit.as_secs(),
        quote(&title(command)),
        quote(&guest_dir(workdir)),
        quote(command),
    );
    vm.ask(&line).await?;
    Ok(started(&unit, limit))
}

/// What the model is told of a background command that started as
/// `unit`.
fn started(unit: &str, limit: Duration) -> String {
    format!(
        "It runs in the background as {unit}, for at most {}. When it ends, its exit status and \
         output come back to you as [{unit} 完成]: don't sleep waiting for it, and don't keep \
         checking. Its output is written to /work/.max/out/{unit}.txt as it runs: to see how far it \
         is, read the end of that; if it isn't wanted any more, stop it with systemctl stop {unit}.",
        took(limit)
    )
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
    fn a_background_command_says_where_it_is_and_how_to_stop_it() {
        let text = started("max-job-6734-9", Duration::from_secs(6 * 3600));
        assert!(
            text.starts_with(
                "It runs in the background as max-job-6734-9, for at most 6 hours 0 minutes. \
                 When it ends, its exit status and output come back to you as [max-job-6734-9 完成]"
            ),
            "{text}"
        );
        assert!(
            text.contains("written to /work/.max/out/max-job-6734-9.txt as it runs"),
            "{text}"
        );
        assert!(
            text.ends_with("stop it with systemctl stop max-job-6734-9."),
            "{text}"
        );
    }

    #[test]
    fn a_command_is_titled_by_its_first_line() {
        assert_eq!(title("make -j8\nmake install"), "$ make -j8");
    }
}
