//! What the model's tool calls do; see "工具和 codemode". `shell` runs a
//! command in the group's VM. `run_code` waits for the MCP service.

use std::collections::VecDeque;
use std::time::Duration;

use color_eyre::eyre::Result;
use max_core::ids::ConversationId;
use max_core::item::ToolOutput;
use max_core::tools::Tool;
use tokio::fs;
use tokio::io::AsyncWriteExt;
use tokio::time::timeout;

use crate::tokens;
use crate::vm::ssh::{Sink, quote};
use crate::vm::{Vm, Vms};

/// A command's wall clock, unless the call asks for another.
const SHELL_TIME: Duration = Duration::from_secs(120);
/// The most a call may ask for.
const SHELL_TIME_MAX: Duration = Duration::from_secs(600);
/// The guest stops the unit itself a little after max would have.
const GUEST_MARGIN: Duration = Duration::from_secs(30);
/// Output past this many bytes is cut to its head and tail, each half of
/// it; the whole goes to a file in /work.
const SHOWN: usize = 16 * 1024;

pub async fn run(tool: Tool, vms: Option<&Vms>, conversation: ConversationId) -> ToolOutput {
    let text = |text: String, error| {
        let tokens = tokens::count(&text);
        ToolOutput::text(text, error, tokens)
    };
    match tool {
        Tool::RunCode { .. } => text(
            "run_code 还没接上，现在用不了；跑命令用 shell。".into(),
            true,
        ),
        Tool::Shell {
            command,
            workdir,
            timeout_ms,
        } => {
            let Some(vms) = vms else {
                return text("这里没有配 VM，shell 用不了。".into(), true);
            };
            let vm = match vms.get(conversation).await {
                Ok(vm) => vm,
                Err(error) => return text(error, true),
            };
            let limit = timeout_ms
                .map_or(SHELL_TIME, Duration::from_millis)
                .clamp(Duration::from_secs(1), SHELL_TIME_MAX);
            match shell(&vm, &command, workdir.as_deref(), limit).await {
                Ok((shown, error)) => text(shown, error),
                Err(error) => text(format!("shell 没跑成：{error:#}"), true),
            }
        }
    }
}

/// What the model is shown, and whether the command failed to finish.
async fn shell(
    vm: &Vm,
    command: &str,
    workdir: Option<&str>,
    limit: Duration,
) -> Result<(String, bool)> {
    let workdir = match workdir {
        Some(dir) if dir.starts_with('/') => dir.to_owned(),
        Some(dir) => format!("/work/{dir}"),
        None => "/work".to_owned(),
    };
    let unit = Vm::unit();
    // systemd-run hands the unit its own output, so 2>&1 merges the
    // command's. It would also set the terminal's title.
    let line = format!(
        "SYSTEMD_ADJUST_TERMINAL_TITLE=0 exec systemd-run --quiet --pipe --wait --collect \
         --unit={unit} --property=RuntimeMaxSec={} --working-directory={} \
         -- bash -lc {} 2>&1",
        (limit + GUEST_MARGIN).as_secs(),
        quote(&workdir),
        quote(command),
    );
    let mut output = Output::new(vm.work().join(".max/out").join(format!("{unit}.txt")));
    let mut running = vm.command(unit.clone(), &line).await?;
    let waited = timeout(limit, running.wait(&mut output)).await;
    output.finish().await?;
    let shown = output.shown(&unit);
    match waited {
        Ok(status) => {
            let status = status?;
            let head = match status {
                Some(code) => format!("退出码 {code}"),
                None => "没有退出码，命令可能被杀了".to_owned(),
            };
            Ok((with(head, &shown), false))
        }
        Err(_) => {
            running.stop(vm.connection()).await?;
            let head = format!("{} 秒内没跑完，已经停了", limit.as_secs());
            Ok((with(head, &shown), true))
        }
    }
}

fn with(head: String, shown: &str) -> String {
    if shown.is_empty() {
        format!("{head}，没有输出。")
    } else {
        format!("{head}\n{shown}")
    }
}

/// A command's output: all of it while short; past `SHOWN`, its head and
/// tail, and the whole in a file.
struct Output {
    path: std::path::PathBuf,
    head: Vec<u8>,
    tail: VecDeque<u8>,
    total: usize,
    file: Option<fs::File>,
}

impl Output {
    fn new(path: std::path::PathBuf) -> Self {
        Self {
            path,
            head: Vec::new(),
            tail: VecDeque::new(),
            total: 0,
            file: None,
        }
    }

    fn shown(&self, unit: &str) -> String {
        let head = String::from_utf8_lossy(&self.head);
        if self.file.is_none() {
            return head.into_owned();
        }
        let tail: Vec<u8> = self.tail.iter().copied().collect();
        let left_out = self.total - self.head.len() - tail.len();
        format!(
            "{}\n…（中间省略 {left_out} 字节，全部输出在 /work/.max/out/{unit}.txt）…\n{}",
            head.trim_end_matches('\u{fffd}'),
            String::from_utf8_lossy(&tail).trim_start_matches('\u{fffd}'),
        )
    }
}

impl Sink for Output {
    async fn output(&mut self, data: &[u8]) -> Result<()> {
        self.total += data.len();
        if self.file.is_none() && self.total <= SHOWN {
            self.head.extend_from_slice(data);
            return Ok(());
        }
        if let Some(file) = &mut self.file {
            file.write_all(data).await?;
            self.tail.extend(data);
        } else {
            if let Some(dir) = self.path.parent() {
                fs::create_dir_all(dir).await?;
            }
            let mut file = fs::File::create(&self.path).await?;
            let mut all = std::mem::take(&mut self.head);
            all.extend_from_slice(data);
            file.write_all(&all).await?;
            self.file = Some(file);
            self.head = all[..SHOWN / 2].to_vec();
            self.tail = all[all.len() - SHOWN / 2..].iter().copied().collect();
        }
        let over = self.tail.len().saturating_sub(SHOWN / 2);
        self.tail.drain(..over);
        Ok(())
    }
}

impl Output {
    /// Writes out what the file has yet to get.
    async fn finish(&mut self) -> Result<()> {
        if let Some(file) = &mut self.file {
            file.flush().await?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn short_output_is_shown_whole() {
        let dir = std::env::temp_dir().join(format!("max-output-{}", std::process::id()));
        let mut output = Output::new(dir.join("short.txt"));
        output.output(b"hello\n").await.unwrap();
        output.output(b"world").await.unwrap();
        assert_eq!(output.shown("max-1"), "hello\nworld");
        assert!(!dir.join("short.txt").exists());
    }

    #[tokio::test]
    async fn long_output_keeps_its_ends_and_goes_whole_to_a_file() {
        let dir = std::env::temp_dir().join(format!("max-output-long-{}", std::process::id()));
        let path = dir.join("long.txt");
        let mut output = Output::new(path.clone());
        let mut all = Vec::new();
        for n in 0..5000 {
            let line = format!("{n:05}\n");
            all.extend_from_slice(line.as_bytes());
            output.output(line.as_bytes()).await.unwrap();
        }
        output.finish().await.unwrap();
        let shown = output.shown("max-2");
        assert!(shown.starts_with("00000\n"), "{shown}");
        assert!(shown.ends_with("04999\n"), "{shown}");
        assert!(shown.contains("/work/.max/out/max-2.txt"), "{shown}");
        assert_eq!(output.head.len() + output.tail.len(), SHOWN);
        assert_eq!(std::fs::read(&path).unwrap(), all);
        let _ = std::fs::remove_dir_all(dir);
    }
}
