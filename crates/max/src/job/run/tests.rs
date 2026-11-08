use std::process::Command;

use super::*;

#[test]
fn the_harness_starts_in_its_directory() {
    let line = unit_line("max-1", Duration::from_secs(120), "/work");
    assert!(line.starts_with("mkdir -p -- '/work' /work/.max/projects && "));
    assert!(line.contains("--unit=max-1 --property=RuntimeDirectory=max-1"));
    assert!(line.contains("--property=RuntimeMaxSec=120 --working-directory='/work'"));
    assert!(line.ends_with("-- bash -lc 'exec max-pi'"));
}

#[test]
fn a_directory_stays_one_word_without_shell_expansion() {
    let dir = "/work/项目's $(printf injected); `printf extra` \\ %H --flag";
    // Print the arguments instead of making the directories and starting
    // the unit, using the same shell that parses the line in the guest.
    let line = unit_line("max-2", Duration::from_secs(60), dir)
        .replace("mkdir -p", "printf '%s\\0'")
        .replace("exec systemd-run", "exec printf '%s\\0'");
    let output = Command::new("bash").args(["-c", &line]).output().unwrap();
    assert!(output.status.success());
    let output = String::from_utf8(output.stdout).unwrap();
    let args: Vec<&str> = output.trim_end_matches('\0').split('\0').collect();
    assert_eq!(
        args,
        [
            "--",
            dir,
            "/work/.max/projects",
            "--quiet",
            "--pipe",
            "--wait",
            "--collect",
            "--unit=max-2",
            "--property=RuntimeDirectory=max-2",
            "--property=RuntimeMaxSec=60",
            &format!("--working-directory={dir}"),
            "--",
            "bash",
            "-lc",
            "exec max-pi",
        ]
    );
}

#[test]
fn each_directory_has_its_own_notes() {
    for (dir, file) in [
        ("/work", "work"),
        ("/work/max", "work-max"),
        ("/work/max/", "work-max"),
        ("/work/./max", "work-max"),
        ("/work/项目's dir", "work-项目-s-dir"),
        ("/tmp/max", "tmp-max"),
        ("/work/max.rs", "work-max-rs"),
        ("/", "root"),
    ] {
        assert_eq!(notes_file(dir), format!("/work/.max/projects/{file}.md"));
    }
    let long = notes_file(&format!("/work/{}", "项".repeat(100)));
    let name = long.rsplit('/').next().unwrap();
    assert!(name.len() <= 203, "{}", name.len());
}

#[test]
fn notes_are_shown_up_to_their_limit() {
    assert_eq!(
        shown("- 用 cargo nextest run\n\n"),
        "- 用 cargo nextest run"
    );
    let line = format!("- {}\n", "坑".repeat(100));
    let text = line.repeat(100);
    let notes = shown(&text);
    let (kept, warned) = notes.rsplit_once('\n').unwrap();
    assert!(kept.len() <= 16 << 10);
    assert!(kept.lines().all(|kept| format!("{kept}\n") == line));
    assert_eq!(
        warned,
        "（笔记超过 16 KiB，后面的没加载：更新时精简一下。）"
    );
}

#[test]
fn the_agent_is_told_where_its_notes_are() {
    let system = system("/work/max", "/work/.max/projects/work-max.md", "- 先跑 fmt");
    assert!(system.starts_with(SYSTEM));
    assert!(system.contains("你在 /work/max 下干活"));
    assert!(system.contains("笔记在 /work/.max/projects/work-max.md"));
    assert!(system.contains("别往里记笔记"));
    assert!(system.ends_with("\n\n[笔记]\n- 先跑 fmt"));
}
