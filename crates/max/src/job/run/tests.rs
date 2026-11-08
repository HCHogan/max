use std::process::Command;

use super::*;

#[test]
fn the_harness_starts_in_its_directory() {
    let line = unit_line("max-1", Duration::from_secs(120), "/work");
    assert!(line.contains("--unit=max-1 --property=RuntimeDirectory=max-1"));
    assert!(line.contains("--property=RuntimeMaxSec=120 --working-directory='/work'"));
    assert!(line.ends_with("-- bash -lc 'exec max-pi'"));
}

#[test]
fn a_directory_stays_one_word_without_shell_expansion() {
    let dir = "/work/项目's $(printf injected); `printf extra` \\ %H --flag";
    // Print the arguments instead of starting the unit, using the same
    // shell that parses the line in the guest.
    let line = unit_line("max-2", Duration::from_secs(60), dir)
        .replace("exec systemd-run", "exec printf '%s\\0'");
    let output = Command::new("bash").args(["-c", &line]).output().unwrap();
    assert!(output.status.success());
    let output = String::from_utf8(output.stdout).unwrap();
    let args: Vec<&str> = output.trim_end_matches('\0').split('\0').collect();
    assert_eq!(
        args,
        [
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
