//! `shell` in a turn: a command the turn waits on, which moves to the
//! background once someone waits on the turn and it has run a while. See
//! "Background commands" in docs/rust-rewrite.md.

use super::background::{failed, finished};
use super::output::OUT;
use super::*;

/// What the model is shown, and whether the command failed to finish. A
/// turn's command, `movable`, may move to the background instead.
pub(super) async fn shell(
    vm: &Vm,
    grant: &Grant,
    command: &str,
    workdir: Option<&str>,
    limit: Duration,
    movable: Option<Movable>,
) -> Result<(String, bool)> {
    let unit = Vm::unit();
    let mut output = Output::new(vm.work(), format!("{unit}.txt"));
    let token = Some(grant.token());
    let running = start_in(vm, unit, command, workdir, token, limit).await?;
    let (begun, deadline) = (Instant::now(), Instant::now() + limit);
    let ran = match movable {
        None => wait_until(vm, running, &mut output, deadline).await?,
        Some(movable) => {
            let started = Started {
                running,
                begun,
                deadline,
            };
            match wait_or_move(vm, started, output, command, movable).await? {
                Kept::Here(ran, kept) => {
                    output = *kept;
                    ran
                }
                Kept::Moved(mut shown) => {
                    shown.push_str(&called(&grant.calls()));
                    return Ok((shown, false));
                }
            }
        }
    };
    let shown = output.shown();
    let (mut shown, error) = match ran {
        Ran::Exited(status) => (with(exited(status), &shown), false),
        Ran::OutOfTime(stopped) => {
            let head = format!(
                "not done in {} seconds; {}",
                limit.as_secs(),
                stopping(&stopped)
            );
            (with(head, &shown), true)
        }
    };
    shown.push_str(&called(&grant.calls()));
    Ok((shown, error))
}

/// What lets a turn's command move to the background: whether someone
/// waits on the turn, and its conversation, which takes the command.
pub(super) struct Movable {
    pub(super) waiting: Waiting,
    pub(super) poster: Poster,
}

/// A command that has started, and when it must end.
struct Started {
    running: Command,
    begun: Instant,
    deadline: Instant,
}

/// What a command that could move stops waiting on, besides its end.
enum Interrupt {
    OutOfTime,
    /// It moves.
    Due,
}

/// Where a command that could move ended up.
enum Kept {
    /// Here, as it ran, with its output.
    Here(Ran, Box<Output>),
    /// In the background: what the model is shown.
    Moved(String),
}

/// Waits for the command as [`wait_until`] does; but once someone waits
/// on the turn and it has run [`MOVE_AFTER`], it goes to the conversation
/// as a background job, if the conversation takes it.
async fn wait_or_move(
    vm: &Vm,
    started: Started,
    mut output: Output,
    command: &str,
    movable: Movable,
) -> Result<Kept> {
    let Started {
        mut running,
        begun,
        deadline,
    } = started;
    // Between pieces of output, so that none is half written when the
    // command moves with its output.
    let interrupt = async {
        tokio::select! {
            () = sleep_until(deadline) => Interrupt::OutOfTime,
            () = due(movable.waiting, begun) => Interrupt::Due,
        }
    };
    match running.wait_or(&mut output, interrupt).await {
        Ok(Waited::Interrupted(Interrupt::Due)) => {}
        waited => {
            let ran = ended(vm, running, &mut output, waited).await?;
            return Ok(Kept::Here(ran, Box::new(output)));
        }
    }
    let shown = output.shown();
    let file = format!("/work/{OUT}/{}", output.name);
    let (ran, left) = (
        begun.elapsed(),
        deadline.saturating_duration_since(Instant::now()),
    );
    let moved = Box::new(Moved {
        vm: vm.clone(),
        running,
        output,
        deadline,
        begun,
        command: command.to_owned(),
    });
    match movable.poster.adopt(moved).await {
        Ok(job) => Ok(Kept::Moved(moved_away(job, ran, left, &file, &shown))),
        Err((why, Some(moved))) => {
            info!(why, "a command someone waits on stays in the foreground");
            let Moved {
                running,
                mut output,
                ..
            } = *moved;
            let ran = wait_until(vm, running, &mut output, deadline).await?;
            Ok(Kept::Here(ran, Box::new(output)))
        }
        // Dropped with the conversation, it went to the stopper.
        Err((why, None)) => Err(eyre!(why)),
    }
}

/// Once someone waits on the turn and the command begun at `begun` has
/// run [`MOVE_AFTER`]; never, if the turn ends first.
async fn due(mut waiting: Waiting, begun: Instant) {
    if waiting.wait_for(|waiting| *waiting).await.is_err() {
        std::future::pending::<()>().await;
    }
    sleep_until(begun + MOVE_AFTER).await;
}

/// What the model is shown of a command that moved to the background as
/// job `job`: it had run `ran`, has `left`, and printed `shown` so far.
fn moved_away(job: u32, ran: Duration, left: Duration, file: &str, shown: &str) -> String {
    let job = job::name(job);
    let mut text = format!(
        "Someone is waiting for you to answer: this command had run {} seconds and wasn't done, so it moved to the background as {job}, with {} seconds left. {}",
        ran.as_secs(),
        left.as_secs(),
        follow(&job, file),
    );
    if shown.is_empty() {
        text.push_str(" No output so far.");
    } else {
        text.push_str(" Its output so far:\n");
        text.push_str(shown);
    }
    text
}

/// A turn's command handed to its conversation as a background job, as
/// someone addressed Max while it ran. It keeps its unit, its output and
/// its deadline, and loses the run's token once the call returns.
pub struct Moved {
    vm: Vm,
    running: Command,
    output: Output,
    deadline: Instant,
    /// When it started, for the job's age...
    pub begun: Instant,
    /// ...and what it is, for its title.
    pub command: String,
}

impl fmt::Debug for Moved {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Moved")
            .field("command", &self.command)
            .finish_non_exhaustive()
    }
}

/// Runs a moved command on until it ends or its time is up: how it went,
/// as for [`background`].
pub async fn moved(moved: Box<Moved>) -> Finished {
    let Moved {
        vm,
        running,
        mut output,
        deadline,
        begun,
        ..
    } = *moved;
    // Whole from now on, for the model to follow along.
    if output.file.is_none()
        && let Err(error) = output.create().await
    {
        return failed(format!("{error:#}"));
    }
    let ran = wait_until(&vm, running, &mut output, deadline).await;
    finished(ran, &output, begun, deadline - begun)
}

#[cfg(test)]
mod tests {
    use std::pin::pin;

    use tokio::time::timeout;

    use super::*;

    /// A command moves once someone waits and it has run `MOVE_AFTER`:
    /// never while nobody waits, nor once the turn has ended.
    #[tokio::test(start_paused = true)]
    async fn a_command_moves_once_someone_waits_and_it_has_run_a_while() {
        let begun = Instant::now();
        let (someone, waiting) = watch::channel(false);
        let mut moves = pin!(due(waiting, begun));
        assert!(timeout(MOVE_AFTER * 2, &mut moves).await.is_err());
        someone.send_replace(true);
        assert!(timeout(Duration::ZERO, &mut moves).await.is_ok(), "at once");

        let begun = Instant::now();
        let (someone, waiting) = watch::channel(false);
        let mut moves = pin!(due(waiting, begun));
        let early = Duration::from_secs(3);
        assert!(timeout(early, &mut moves).await.is_err());
        someone.send_replace(true);
        moves.await;
        assert_eq!(begun.elapsed(), MOVE_AFTER, "not before its time");

        let (someone, waiting) = watch::channel(false);
        drop(someone);
        let ended = due(waiting, Instant::now());
        assert!(timeout(MOVE_AFTER * 2, ended).await.is_err());
    }

    #[test]
    fn a_moved_command_says_where_it_went() {
        let (ran, left) = (Duration::from_secs(15), Duration::from_secs(105));
        let file = "/work/.max/out/max-1.txt";
        let text = moved_away(4, ran, left, file, "编译中\n");
        assert!(
            text.starts_with(
                "Someone is waiting for you to answer: this command had run 15 seconds and wasn't \
                 done, so it moved to the background as job#4, with 105 seconds left. When it ends, \
                 its exit status and output come back to you as [job#4 完成]"
            ),
            "{text}"
        );
        assert!(
            text.contains("written to /work/.max/out/max-1.txt as it runs"),
            "{text}"
        );
        assert!(
            text.ends_with("agent_cancel. Its output so far:\n编译中\n"),
            "{text}"
        );
        let quiet = moved_away(4, ran, left, file, "");
        assert!(
            quiet.ends_with("agent_cancel. No output so far."),
            "{quiet}"
        );
    }
}
