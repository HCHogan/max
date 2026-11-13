//! What a VM shows of itself for `/status`: the NixOS its guest runs, the
//! memory in use there and how Max's units are, as the guest says them;
//! and how much of the disk its /work takes, counted on the host's side,
//! where it is whether or not the VM runs.

use std::collections::{HashMap, HashSet};
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::time::{Duration, Instant};

use color_eyre::eyre::{Result, bail};

use super::ssh;

/// What a guest says of itself.
#[derive(Debug, PartialEq, Eq)]
pub struct About {
    /// Its NixOS, as /run/current-system names it: 26.05.20261108.ac588ef.
    pub version: String,
    /// The memory in use there, in bytes: all of it but what the kernel
    /// counts as available.
    pub used: u64,
    /// All the memory it has, in bytes.
    pub memory: u64,
    /// The units asked about that its systemd answered for.
    pub units: Vec<Unit>,
}

/// One of Max's units, as the guest's systemd has it.
#[derive(Debug, PartialEq, Eq)]
pub struct Unit {
    pub name: String,
    /// What systemd made of its file: loaded; not-found of a file
    /// `maxx units apply` hasn't installed; bad-setting or error of one it
    /// couldn't read.
    pub load: String,
    /// Its substate: running, exited, waiting, listening, dead, failed,
    /// auto-restart.
    pub state: String,
    /// How it failed, of one that did: exit-code, signal, timeout,
    /// oom-kill.
    pub failure: Option<String>,
    /// How long it has been in that state; None of one that was never in
    /// another.
    pub since: Option<Duration>,
    /// The memory its processes hold, in bytes, of one that has any.
    pub memory: Option<u64>,
    /// How often systemd started it again by itself.
    pub restarts: u32,
}

/// The line that asks a guest about itself and about `units`. Nothing in
/// it is the contract's: every guest has these files and systemctl, so
/// one that an older max booted answers too.
pub(super) fn line(units: &[String]) -> String {
    // The version's file ends without a new line: echo gives it a line
    // however it ends, and an empty one without the file.
    let mut line = "echo \"$(cat /run/current-system/nixos-version)\"; cat /proc/uptime; \
                    grep -E '^Mem(Total|Available):' /proc/meminfo"
        .to_owned();
    if !units.is_empty() {
        line.push_str(
            "; systemctl show -p Id,LoadState,SubState,Result,\
             StateChangeTimestampMonotonic,MemoryCurrent,NRestarts --",
        );
        for unit in units {
            line.push(' ');
            line.push_str(&ssh::quote(unit));
        }
    }
    // Whatever systemctl made of the names, the rest is the answer.
    line.push_str("; true");
    line
}

/// What a guest answered [`line`] with: its version's line, its uptime's,
/// the two of its memory, and a paragraph of properties for each unit.
pub(super) fn read(said: &str) -> Result<About> {
    let mut lines = said.lines();
    let version = lines.next().unwrap_or_default().trim();
    let up = lines
        .next()
        .and_then(|line| line.split_whitespace().next()?.parse::<f64>().ok())
        .map(Duration::from_secs_f64);
    let (mut total, mut available) = (None, None);
    let mut units = Vec::new();
    let mut unit = HashMap::new();
    // A paragraph ends at an empty line, and the last one at the end.
    for line in lines.chain([""]) {
        if let Some(kilobytes) = line.strip_prefix("MemTotal:") {
            total = bytes(kilobytes);
        } else if let Some(kilobytes) = line.strip_prefix("MemAvailable:") {
            available = bytes(kilobytes);
        } else if let Some((key, value)) = line.split_once('=') {
            unit.insert(key, value);
        } else if !unit.is_empty() {
            units.extend(Unit::read(&unit, up));
            unit.clear();
        }
    }
    match (up, total, available) {
        (Some(_), Some(memory), Some(available)) if !version.is_empty() => Ok(About {
            version: version.to_owned(),
            used: memory.saturating_sub(available),
            memory,
            units,
        }),
        _ => bail!("the guest said of itself: {}", said.trim()),
    }
}

/// `MemTotal:`'s value, `  8040000 kB`, in bytes.
fn bytes(kilobytes: &str) -> Option<u64> {
    let kilobytes: u64 = kilobytes.trim().strip_suffix("kB")?.trim().parse().ok()?;
    Some(kilobytes * 1024)
}

impl Unit {
    /// One unit's properties, in a guest up for `up`.
    fn read(properties: &HashMap<&str, &str>, up: Option<Duration>) -> Option<Self> {
        let property = |key: &str| properties.get(key).copied().unwrap_or_default();
        let name = properties.get("Id")?;
        let state = property("SubState");
        let changed = property("StateChangeTimestampMonotonic").parse().ok();
        let since = match (up, changed) {
            // 0 for one whose state never changed.
            (Some(up), Some(changed)) if changed > 0 => {
                Some(up.saturating_sub(Duration::from_micros(changed)))
            }
            _ => None,
        };
        let failure = Some(property("Result"))
            .filter(|result| state == "failed" && !result.is_empty())
            .map(str::to_owned);
        Some(Self {
            name: (*name).to_owned(),
            load: property("LoadState").to_owned(),
            state: state.to_owned(),
            failure,
            since,
            // "[not set]" of one without processes, which an older
            // systemd wrote as the largest number there is.
            memory: (property("MemoryCurrent").parse().ok())
                .filter(|&held| held > 0 && held < u64::MAX),
            restarts: property("NRestarts").parse().unwrap_or(0),
        })
    }
}

/// How much of the disk `work` takes, in bytes, as du counts it: the
/// blocks of everything under it, a file with several names once, and no
/// link followed. It stops at `until` with what it has counted, and says
/// whether that is all of it. None without the directory.
pub fn taken(work: &Path, until: Instant) -> Option<(u64, bool)> {
    // One directory open at a time: those found in it wait by name.
    let mut open = Some(std::fs::read_dir(work).ok()?);
    let mut dirs = Vec::new();
    let mut seen = HashSet::new();
    let mut bytes = 0;
    while let Some(dir) = open.take() {
        for entry in dir.flatten() {
            if Instant::now() >= until {
                return Some((bytes, false));
            }
            // Of the entry itself, not of what a link points to.
            let Ok(entry_is) = entry.metadata() else {
                continue;
            };
            if entry_is.is_dir() {
                dirs.push(entry.path());
            } else if entry_is.nlink() > 1 && !seen.insert((entry_is.dev(), entry_is.ino())) {
                continue;
            }
            bytes += entry_is.blocks() * 512;
        }
        open = std::iter::from_fn(|| dirs.pop()).find_map(|dir| std::fs::read_dir(dir).ok());
    }
    Some((bytes, true))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_guest_is_asked_about_itself_and_the_units_named() {
        let alone = line(&[]);
        assert_eq!(
            alone,
            "echo \"$(cat /run/current-system/nixos-version)\"; cat /proc/uptime; \
             grep -E '^Mem(Total|Available):' /proc/meminfo; true"
        );
        let units = line(&["web.service".to_owned(), "it's.timer".to_owned()]);
        assert!(
            units.ends_with(r" -- 'web.service' 'it'\''s.timer'; true"),
            "{units}"
        );
    }

    /// As a guest answered on 2026-11-13, with the properties in systemd's
    /// order and a paragraph for a name it has no unit of.
    const SAID: &str = "26.05.20261108.ac588ef
8000.50 15900.12
MemTotal:        8131428 kB
MemAvailable:    7204100 kB
Id=web.service
LoadState=loaded
SubState=running
Result=success
StateChangeTimestampMonotonic=20500000
MemoryCurrent=190840832
NRestarts=2

Id=poll.timer
LoadState=loaded
SubState=waiting
Result=success
StateChangeTimestampMonotonic=7959500000

Id=scrape.service
LoadState=loaded
SubState=failed
Result=exit-code
StateChangeTimestampMonotonic=7688500000
MemoryCurrent=18446744073709551615
NRestarts=0

Id=new.service
LoadState=not-found
SubState=dead
StateChangeTimestampMonotonic=0
MemoryCurrent=[not set]
";

    #[test]
    fn what_a_guest_says_of_itself_is_read() {
        let about = read(SAID).unwrap();
        assert_eq!(about.version, "26.05.20261108.ac588ef");
        assert_eq!(about.memory, 8_131_428 * 1024);
        assert_eq!(about.used, (8_131_428 - 7_204_100) * 1024);
        let unit = |name: &str, state: &str| Unit {
            name: name.to_owned(),
            load: "loaded".to_owned(),
            state: state.to_owned(),
            failure: None,
            since: None,
            memory: None,
            restarts: 0,
        };
        let seconds = |seconds| Some(Duration::from_secs(seconds));
        assert_eq!(
            about.units,
            [
                Unit {
                    since: seconds(7980),
                    memory: Some(190_840_832),
                    restarts: 2,
                    ..unit("web.service", "running")
                },
                Unit {
                    since: seconds(41),
                    ..unit("poll.timer", "waiting")
                },
                Unit {
                    failure: Some("exit-code".to_owned()),
                    since: seconds(312),
                    ..unit("scrape.service", "failed")
                },
                Unit {
                    load: "not-found".to_owned(),
                    ..unit("new.service", "dead")
                },
            ]
        );
    }

    #[test]
    fn a_guest_with_no_units_asked_about_has_none() {
        let said = "26.05.20261108.ac588ef\n12.5 20.0\nMemTotal: 1024 kB\nMemAvailable: 24 kB\n";
        let about = read(said).unwrap();
        assert_eq!((about.used, about.memory), (1000 * 1024, 1024 * 1024));
        assert_eq!(about.units, []);
    }

    #[test]
    fn what_isnt_a_guests_answer_is_refused() {
        // No version: the file wasn't there, and echo wrote the line.
        let unversioned = "\n12.5 20.0\nMemTotal: 1024 kB\nMemAvailable: 24 kB\n";
        for said in [
            "",
            "26.05\n",
            "26.05\n12.5 20.0\nMemTotal: 1024 kB\n",
            unversioned,
        ] {
            let error = read(said).unwrap_err().to_string();
            assert!(error.starts_with("the guest said of itself: "), "{error}");
        }
    }

    #[test]
    fn work_takes_what_its_files_do_once_each() {
        let scratch = |name: &str| {
            let dir = format!("max-{name}-{:016x}", rand::random::<u64>());
            std::env::temp_dir().join(dir)
        };
        let (work, outside) = (scratch("taken"), scratch("outside"));
        let later = || Instant::now() + Duration::from_secs(60);
        assert_eq!(taken(&work, later()), None);

        // What the file system says each takes, whatever it keeps of a
        // megabyte of sevens.
        let blocks = |paths: &[&str]| -> u64 {
            let of = |path: &&str| std::fs::symlink_metadata(work.join(path)).unwrap().blocks();
            paths.iter().map(of).sum::<u64>() * 512
        };
        std::fs::create_dir_all(work.join("a/b")).unwrap();
        std::fs::write(work.join("a/b/big"), vec![7u8; 1 << 20]).unwrap();
        let all = blocks(&["a", "a/b", "a/b/big"]);
        assert_eq!(taken(&work, later()), Some((all, true)));

        // Another name of the same file takes nothing more, and a link
        // out of /work isn't followed.
        std::fs::hard_link(work.join("a/b/big"), work.join("a/again")).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("huge"), vec![7u8; 1 << 20]).unwrap();
        std::os::unix::fs::symlink(&outside, work.join("out")).unwrap();
        let all = blocks(&["a", "a/b", "a/b/big", "out"]);
        assert_eq!(taken(&work, later()), Some((all, true)));

        // Out of time, it says what it has, which isn't all.
        assert_eq!(taken(&work, Instant::now()), Some((0, false)));
        for dir in [work, outside] {
            std::fs::remove_dir_all(dir).unwrap();
        }
    }
}
