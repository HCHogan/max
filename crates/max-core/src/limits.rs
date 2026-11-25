//! The limits on what Max and its programs can do, in one place: those the
//! model is told of, and those more than one place enforces. The prompt
//! and the tools' descriptions are written from these, so changing one
//! changes what the model reads too.
//!
//! What stays with its own code: a tool's argument ranges (with its
//! schema), a platform's own limits (its adapter's), the tuning of an
//! algorithm, and timeouts, retries and grace periods that only keep the
//! plumbing honest.
//!
//! Some a conversation may set for itself: see [`Setting`].

use std::ops::RangeInclusive;
use std::time::Duration;

use serde::{Deserialize, Serialize};

/// The window the hourly limits and counts are over.
pub const HOUR: Duration = Duration::from_secs(3600);

// Commands (shell) and programs (run_code).

/// A command's or a program's wall clock, unless the call asks for
/// another: the guest ends its unit then.
pub const RUN_TIME: Duration = Duration::from_secs(120);
/// The most wall clock a command or a program may ask for.
pub const RUN_TIME_MAX: Duration = Duration::from_secs(600);
/// A background command's wall clock, unless the call asks for another.
pub const BACKGROUND_TIME: Duration = Duration::from_secs(6 * 60 * 60);
/// The most wall clock a background command may ask for. A background
/// agent, pi in such a command, costs model calls for as long as it runs,
/// and has the same.
pub const BACKGROUND_TIME_MAX: Duration = Duration::from_secs(24 * 60 * 60);
/// Output past this many bytes is cut to its head and tail, each half of
/// it; the whole goes to a file in /work.
pub const SHOWN_BYTES: usize = 16 * 1024;
/// A call of one of Max's tools, from a program or a command: its wall
/// clock, by default ([`Setting::CallTimeSecs`]).
pub const CALL_TIME: Duration = Duration::from_secs(60);
/// How many calls of Max's tools a VM makes at once, whatever in it makes
/// them; more wait their turn.
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

/// The largest file kept from the chat; past it, only what QQ said of a
/// file is kept. A download has a minute, and the store keeps what it
/// gets for good.
pub const KEPT_FILE_BYTES: u64 = 64 << 20;
/// The largest file sent to the chat: 200 MiB to start with, on
/// 2026-11-08; QQ is said to take more. It is read from disk a piece at a
/// time. 32 MiB took 14 seconds to upload from tank on 2026-10-29, so one
/// this big takes a minute or two, and what Max says after it waits.
pub const SENT_FILE_BYTES: u64 = 200 << 20;
/// The largest voice message sent to the chat. QQ's documentation has one
/// past 20 MB go as a file instead.
pub const SENT_VOICE_BYTES: u64 = 16 << 20;

// Asking another conversation.

/// The most characters of a question put to Max in another conversation,
/// and of its answer; a longer one is refused, not cut.
pub const ASK_CHARS: u32 = 2_000;

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

/// A limit a conversation may set for itself, with `/config` or Max's
/// `config` tool, by the name the configuration file, the command and the
/// tool all call it. The value in force is the conversation's, else the
/// configuration file's (`[limits]`, and each provider's
/// `idle_window_secs`), else the default here; the last to set it wins.
/// See "Settings a conversation sets" in docs/design/config.md.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Setting {
    /// How long a core waits idle before it ends.
    IdleWindowSecs,
    /// [`CALL_TIME`].
    CallTimeSecs,
}

crate::names!(Setting, "setting", {
    IdleWindowSecs => "idle_window_secs",
    CallTimeSecs => "call_time_secs",
});

impl Setting {
    /// What a conversation, or the configuration file's `[limits]`, may
    /// set it to.
    #[must_use]
    pub const fn range(self) -> RangeInclusive<u64> {
        match self {
            Self::IdleWindowSecs => 60..=7200,
            Self::CallTimeSecs => 10..=600,
        }
    }
}

/// What a conversation has set of the [`Setting`]s, each within its
/// range; None is the default.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Overrides {
    /// [`Setting::IdleWindowSecs`], if it is set.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub idle_window_secs: Option<u64>,
    /// [`Setting::CallTimeSecs`], if it is set.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub call_time_secs: Option<u64>,
}

impl Overrides {
    /// What `setting` is set to, if it is.
    #[must_use]
    pub fn get(&self, setting: Setting) -> Option<u64> {
        match setting {
            Setting::IdleWindowSecs => self.idle_window_secs,
            Setting::CallTimeSecs => self.call_time_secs,
        }
    }

    /// Sets `setting` to `value`, or back to the default with None.
    pub fn set(&mut self, setting: Setting, value: Option<u64>) {
        let slot = match setting {
            Setting::IdleWindowSecs => &mut self.idle_window_secs,
            Setting::CallTimeSecs => &mut self.call_time_secs,
        };
        *slot = value;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settings_are_stored_by_their_names() {
        let mut overrides = Overrides::default();
        for setting in Setting::ALL {
            assert_eq!(setting.as_str().parse(), Ok(setting));
            assert!(overrides.get(setting).is_none());
            overrides.set(setting, Some(*setting.range().start()));
        }
        let stored = serde_json::to_value(overrides).unwrap();
        let mut keys: Vec<&str> = stored
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        keys.sort_unstable();
        let mut names: Vec<&str> = Setting::ALL
            .iter()
            .map(|setting| setting.as_str())
            .collect();
        names.sort_unstable();
        assert_eq!(keys, names);
        overrides.set(Setting::CallTimeSecs, None);
        assert_eq!(
            serde_json::to_value(overrides).unwrap(),
            serde_json::json!({ "idle_window_secs": 60 })
        );
    }

    #[test]
    fn webread_prints_as_much_as_the_prompt_says() {
        let script = include_str!("../../../nix/webread.py");
        let default = format!("\"--max\", type=int, default={WEBREAD_CHARS},");
        assert!(script.contains(&default), "nix/webread.py: {default}");
    }
}
