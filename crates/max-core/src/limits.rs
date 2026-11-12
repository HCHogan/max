//! The limits on what Max and its programs can do, in one place: those the
//! model is told of, and those more than one place enforces. The prompt
//! and the tools' descriptions are written from these, so changing one
//! changes what the model reads too.
//!
//! What stays with its own code: a tool's argument ranges (with its
//! schema), QQ's own limits, the tuning of an algorithm, and timeouts,
//! retries and grace periods that only keep the plumbing honest.
//!
//! Some a conversation may set for itself: see [`Setting`].

use std::ops::RangeInclusive;
use std::time::Duration;

use serde::{Deserialize, Serialize};

/// The window the hourly limits and counts are over.
pub const HOUR: Duration = Duration::from_secs(3600);

// Commands (shell) and programs (run_code).

/// A command's or a program's wall clock, unless the call asks for
/// another: the guest ends its unit then...
pub const RUN_TIME: Duration = Duration::from_secs(120);
/// ...and the most it may ask for.
pub const RUN_TIME_MAX: Duration = Duration::from_secs(600);
/// A background command's, unless the call asks for another...
pub const BACKGROUND_TIME: Duration = Duration::from_secs(6 * 60 * 60);
/// ...and the most it may ask for. A command costs no model calls while
/// it runs, only room in the VM, so it may run much longer than an agent,
/// whose own time is the guest's to say (nix/max-agent.sh).
pub const BACKGROUND_TIME_MAX: Duration = Duration::from_secs(24 * 60 * 60);
/// Output past this many bytes is cut to its head and tail, each half of
/// it; the whole goes to a file in /work.
pub const SHOWN_BYTES: usize = 16 * 1024;
/// A call of one of Max's tools, from a program or a command: its wall
/// clock, by default ([`Setting::CallTimeSecs`])...
pub const CALL_TIME: Duration = Duration::from_secs(60);
/// ...and how many a VM makes at once, whatever in it makes them; more
/// wait their turn.
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
/// See "Settings a conversation sets" in docs/rust-rewrite.md.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Setting {
    /// How long a core waits idle before it ends.
    IdleWindowSecs,
    /// [`CALL_TIME`].
    CallTimeSecs,
}

impl Setting {
    pub const ALL: [Self; 2] = [Self::IdleWindowSecs, Self::CallTimeSecs];

    pub fn name(self) -> &'static str {
        match self {
            Self::IdleWindowSecs => "idle_window_secs",
            Self::CallTimeSecs => "call_time_secs",
        }
    }

    pub fn find(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|setting| setting.name() == name)
    }

    /// What a conversation, or the configuration file's `[limits]`, may
    /// set it to.
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub idle_window_secs: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub call_time_secs: Option<u64>,
}

impl Overrides {
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
            assert_eq!(Setting::find(setting.name()), Some(setting));
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
        let mut names: Vec<&str> = Setting::ALL.iter().map(|setting| setting.name()).collect();
        names.sort_unstable();
        assert_eq!(keys, names);
        overrides.set(Setting::CallTimeSecs, None);
        assert_eq!(
            serde_json::to_value(overrides).unwrap(),
            serde_json::json!({ "idle_window_secs": 60 })
        );
    }

    #[test]
    fn the_defaults_are_in_range() {
        let call_time = CALL_TIME.as_secs();
        assert!(Setting::CallTimeSecs.range().contains(&call_time));
    }

    #[test]
    fn stored_overrides_read_leniently() {
        let read: Overrides =
            serde_json::from_value(serde_json::json!({ "call_time_secs": 90, "gone": 1 })).unwrap();
        assert_eq!(read.get(Setting::CallTimeSecs), Some(90));
        assert_eq!(read.get(Setting::IdleWindowSecs), None);
    }

    #[test]
    fn webread_prints_as_much_as_the_prompt_says() {
        let script = include_str!("../../../nix/webread.py");
        let default = format!("\"--max\", type=int, default={WEBREAD_CHARS},");
        assert!(script.contains(&default), "nix/webread.py: {default}");
    }
}
