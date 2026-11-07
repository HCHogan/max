//! The limits on what Max and its programs can do, in one place: those the
//! model is told of, and those more than one place enforces. The prompt
//! and the tools' descriptions are written from these, so changing one
//! changes what the model reads too.
//!
//! What stays with its own code: a tool's argument ranges (with its
//! schema), QQ's own limits, the tuning of an algorithm, and timeouts,
//! retries and grace periods that only keep the plumbing honest.

use std::time::Duration;

/// The window the hourly limits and counts are over.
pub const HOUR: Duration = Duration::from_secs(3600);

// Commands (shell) and programs (run_code).

/// A command's or a program's wall clock, unless the call asks for
/// another...
pub const RUN_TIME: Duration = Duration::from_secs(120);
/// ...and the most it may ask for.
pub const RUN_TIME_MAX: Duration = Duration::from_secs(600);
/// A background command's, unless the call asks for another...
pub const BACKGROUND_TIME: Duration = Duration::from_secs(30 * 60);
/// ...and the most it may ask for: as long as a background agent.
pub const BACKGROUND_TIME_MAX: Duration = JOB_TIME;
/// Output past this many bytes is cut to its head and tail, each half of
/// it; the whole goes to a file in /work.
pub const SHOWN_BYTES: usize = 16 * 1024;
/// A call of one of Max's tools, from a program or a command: its wall
/// clock...
pub const CALL_TIME: Duration = Duration::from_secs(60);
/// ...and how many one run makes at once, or a VM's programs outside any
/// turn together; more wait their turn.
pub const CALLS_AT_ONCE: usize = 64;

// What a program shows the model.

/// The most pictures one program shows.
pub const PICTURES_PER_RUN: usize = 4;
/// The most seconds of video one program shows, and so the most a model
/// call is sent: the newest videos' (older ones are named instead).
pub const VIDEO_SECONDS: u32 = 600;
/// The largest picture shown, or sent to the chat.
pub const PICTURE_BYTES: u64 = 10 << 20;
/// The largest video shown: video.js made two minutes of a noisy one
/// 3.8 MB, and an ordinary one 1.2 MB.
pub const VIDEO_BYTES: u64 = 32 << 20;

/// The largest file kept from the chat, or sent to it. QQ takes up to
/// 200 MiB, but a call has `CALL_TIME`, and 32 MiB took 14 seconds to
/// upload from tank on 2026-10-29. Past it, only what QQ said of a file is
/// kept.
pub const FILE_BYTES: u64 = 64 << 20;

// Background agents and commands.

/// The most agents a conversation runs at once...
pub const JOBS_AT_ONCE: usize = 3;
/// ...and background commands, besides.
pub const COMMANDS_AT_ONCE: usize = 3;
/// How long an agent may take; then it is aborted, and reports how far it
/// got.
pub const JOB_TIME: Duration = Duration::from_secs(2 * 60 * 60);
/// How long an agent's question waits for Max's answer; then it goes on by
/// itself.
pub const QUESTION_WAIT: Duration = Duration::from_secs(10 * 60);

// Memory.

/// The most tokens of the memory file a core is shown.
pub const MEMORY_TOKENS: u32 = 3_000;
/// Far past what is shown: a memory file this big isn't read at all.
pub const MEMORY_FILE_BYTES: u64 = 256 << 10;

/// The rows `maxx events --after` sends from before it was asked.
pub const EVENTS_CAUGHT_UP: i64 = 1000;

/// The characters the guest's `webread` prints at once, as its `--max`
/// defaults to.
pub const WEBREAD_CHARS: usize = 12_000;

/// The most times an hour the classifier may wake Max; it is a guard
/// against the small model going wrong. Direct triggers don't count.
pub const JUDGED_WAKES_PER_HOUR: usize = 8;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn webread_prints_as_much_as_the_prompt_says() {
        let script = include_str!("../../../nix/webread.py");
        let default = format!("\"--max\", type=int, default={WEBREAD_CHARS},");
        assert!(script.contains(&default), "nix/webread.py: {default}");
    }
}
