//! What the model's tool calls do; see "工具和 codemode". Both run in the
//! group's VM: `shell` a command, `run_code` a program in the guest's
//! runner, which calls Max's tools through the MCP service and shows the
//! model pictures after its result.

use std::collections::{BTreeMap, VecDeque};
use std::path::{Path, PathBuf};
use std::time::Duration;

use color_eyre::eyre::{Result, eyre};
use max_core::item::{Part, ToolOutput};
use max_core::message::MediaRef;
use max_core::project::PICTURE_TOKENS;
use max_core::tools::Tool;
use serde_json::json;
use tokio::fs;
use tokio::io::AsyncWriteExt;
use tokio::time::timeout;

use crate::mcp::{self, Grant};
use crate::tokens;
use crate::vm::ssh::{Sink, Stream, quote};
use crate::vm::{Vm, Vms};

/// A run's wall clock, unless the call asks for another.
const SHELL_TIME: Duration = Duration::from_secs(120);
/// The most a call may ask for.
const SHELL_TIME_MAX: Duration = Duration::from_secs(600);
/// The guest stops the unit itself a little after max would have.
const GUEST_MARGIN: Duration = Duration::from_secs(30);
/// Output past this many bytes is cut to its head and tail, each half of
/// it; the whole goes to a file in /work.
const SHOWN: usize = 16 * 1024;

/// Runs `tool` for a call from `context`'s conversation.
pub async fn run(tool: Tool, vms: Option<&Vms>, context: mcp::Context) -> ToolOutput {
    let text = |text: String, error| {
        let tokens = tokens::count(&text);
        ToolOutput::text(text, error, tokens)
    };
    let (name, timeout_ms) = match &tool {
        Tool::RunCode { timeout_ms, .. } => ("run_code", *timeout_ms),
        Tool::Shell { timeout_ms, .. } => ("shell", *timeout_ms),
    };
    let Some(vms) = vms else {
        return text(format!("这里没有配 VM，{name} 用不了。"), true);
    };
    let vm = match vms.get(context.place.conversation).await {
        Ok(vm) => vm,
        Err(error) => return text(error, true),
    };
    let limit = timeout_ms
        .map_or(SHELL_TIME, Duration::from_millis)
        .clamp(Duration::from_secs(1), SHELL_TIME_MAX);
    let mut pictures = Vec::new();
    let ran = match tool {
        Tool::RunCode { code, args, .. } => {
            let context = mcp::Context {
                work: Some(vm.work().to_owned()),
                ..context
            };
            let grant = vms.sessions().open(context);
            let ran = run_code(&vm, &grant, &code, args, limit).await;
            pictures = grant.shown();
            ran
        }
        Tool::Shell {
            command, workdir, ..
        } => shell(&vm, &command, workdir.as_deref(), limit).await,
    };
    let mut output = match ran {
        Ok((shown, error)) => text(shown, error),
        Err(error) => text(format!("{name} 没跑成：{error:#}"), true),
    };
    for sha256 in pictures {
        output.parts.push(Part::Media {
            media: MediaRef::Blob(sha256),
        });
        output.tokens += PICTURE_TOKENS;
    }
    output
}

/// The systemd-run line that runs `command` as the unit `unit`, at most
/// `limit`; the guest stops it itself a little after max would have.
/// systemd-run would also set the terminal's title.
fn unit_line(unit: &str, limit: Duration, workdir: &str, command: &str) -> String {
    format!(
        "SYSTEMD_ADJUST_TERMINAL_TITLE=0 exec systemd-run --quiet --pipe --wait --collect \
         --unit={unit} --property=RuntimeMaxSec={} --working-directory={} \
         -- bash -lc {}",
        (limit + GUEST_MARGIN).as_secs(),
        quote(workdir),
        quote(command),
    )
}

/// What the model is shown, and whether the program failed. The result
/// and the console are cut as `shell`'s output is.
async fn run_code(
    vm: &Vm,
    grant: &Grant,
    code: &str,
    args: Option<serde_json::Value>,
    limit: Duration,
) -> Result<(String, bool)> {
    let unit = Vm::unit();
    let line = unit_line(&unit, limit, "/work", "exec node /run/max/runner.js");
    let tools: Vec<&str> = mcp::tool::TOOLS.iter().map(|tool| tool.name).collect();
    let input = json!({ "code": code, "args": args, "token": grant.token(), "tools": tools });
    let mut split = Split {
        out: Output::new(vm.work(), format!("{unit}.txt")),
        err: Output::new(vm.work(), format!("{unit}.log")),
    };
    let mut running = vm
        .command(unit, &line, input.to_string().as_bytes())
        .await?;
    let waited = timeout(limit, running.wait(&mut split)).await;
    split.out.finish().await?;
    split.err.finish().await?;
    let result = split.out.shown();
    let (head, error) = match waited {
        Ok(status) => match status? {
            Some(0) if result.is_empty() => ("程序跑完了，没有返回值。".to_owned(), false),
            Some(0) => (format!("返回值：\n{result}"), false),
            Some(1) => (format!("程序出错了：\n{result}"), true),
            Some(code) => (with(format!("runner 的退出码 {code}"), &result), true),
            None => (with("runner 没有退出码，可能被杀了".into(), &result), true),
        },
        Err(_) => {
            running.stop(vm.connection()).await?;
            let head = format!("{} 秒内没跑完，已经停了", limit.as_secs());
            (with(head, &result), true)
        }
    };
    let mut shown = head;
    let console = split.err.shown();
    if !console.is_empty() {
        shown.push_str("\nconsole 输出：\n");
        shown.push_str(&console);
    }
    shown.push_str(&called(&grant.calls()));
    Ok((shown, error))
}

/// The Max tools a program called, for the model to see what happened.
fn called(calls: &BTreeMap<String, (u32, u32)>) -> String {
    let each: Vec<String> = calls
        .iter()
        .map(|(tool, (succeeded, failed))| match failed {
            0 => format!("{tool} {succeeded} 次"),
            _ => format!("{tool} {} 次（失败 {failed} 次）", succeeded + failed),
        })
        .collect();
    if each.is_empty() {
        String::new()
    } else {
        format!("\n调了 Max 的工具：{}", each.join("，"))
    }
}

/// A program's result and console, apart.
struct Split {
    out: Output,
    err: Output,
}

impl Sink for Split {
    async fn output(&mut self, stream: Stream, data: &[u8]) -> Result<()> {
        match stream {
            Stream::Out => self.out.output(stream, data).await,
            Stream::Err => self.err.output(stream, data).await,
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
    // command's.
    let line = unit_line(&unit, limit, &workdir, command) + " 2>&1";
    let mut output = Output::new(vm.work(), format!("{unit}.txt"));
    let mut running = vm.command(unit, &line, &[]).await?;
    let waited = timeout(limit, running.wait(&mut output)).await;
    output.finish().await?;
    let shown = output.shown();
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

/// Where a long output goes, under /work.
const OUT: &str = ".max/out";

/// A command's output: all of it while short; past `SHOWN`, its head and
/// tail, and the whole in a file, `name` in the guest's /work/.max/out.
struct Output {
    name: String,
    /// The host's side of /work.
    work: PathBuf,
    head: Vec<u8>,
    tail: VecDeque<u8>,
    total: usize,
    file: Option<fs::File>,
}

impl Output {
    fn new(work: &Path, name: String) -> Self {
        Self {
            work: work.to_owned(),
            name,
            head: Vec::new(),
            tail: VecDeque::new(),
            total: 0,
            file: None,
        }
    }

    fn shown(&self) -> String {
        let head = String::from_utf8_lossy(&self.head);
        if self.file.is_none() {
            return head.into_owned();
        }
        let tail: Vec<u8> = self.tail.iter().copied().collect();
        let left_out = self.total - self.head.len() - tail.len();
        format!(
            "{}\n…（中间省略 {left_out} 字节，全部输出在 /work/.max/out/{}）…\n{}",
            head.trim_end_matches('\u{fffd}'),
            self.name,
            String::from_utf8_lossy(&tail).trim_start_matches('\u{fffd}'),
        )
    }
}

impl Sink for Output {
    async fn output(&mut self, _: Stream, data: &[u8]) -> Result<()> {
        self.total += data.len();
        if self.file.is_none() && self.total <= SHOWN {
            self.head.extend_from_slice(data);
            return Ok(());
        }
        if let Some(file) = &mut self.file {
            file.write_all(data).await?;
            self.tail.extend(data);
        } else {
            let (work, name) = (self.work.clone(), self.name.clone());
            let file = tokio::task::spawn_blocking(move || mcp::work::create(&work, OUT, &name))
                .await?
                .map_err(|failure| eyre!(failure.message))?;
            let mut file = fs::File::from_std(file);
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
        let work = std::env::temp_dir().join(format!("max-output-{}", std::process::id()));
        std::fs::create_dir_all(&work).unwrap();
        let mut output = Output::new(&work, "short.txt".into());
        output.output(Stream::Out, b"hello\n").await.unwrap();
        output.output(Stream::Out, b"world").await.unwrap();
        assert_eq!(output.shown(), "hello\nworld");
        assert!(!work.join(".max/out/short.txt").exists());
        let _ = std::fs::remove_dir_all(work);
    }

    #[tokio::test]
    async fn long_output_keeps_its_ends_and_goes_whole_to_a_file() {
        let work = std::env::temp_dir().join(format!("max-output-long-{}", std::process::id()));
        std::fs::create_dir_all(&work).unwrap();
        let path = work.join(".max/out/max-2.txt");
        let mut output = Output::new(&work, "max-2.txt".into());
        let mut all = Vec::new();
        for n in 0..5000 {
            let line = format!("{n:05}\n");
            all.extend_from_slice(line.as_bytes());
            output.output(Stream::Out, line.as_bytes()).await.unwrap();
        }
        output.finish().await.unwrap();
        let shown = output.shown();
        assert!(shown.starts_with("00000\n"), "{shown}");
        assert!(shown.ends_with("04999\n"), "{shown}");
        assert!(shown.contains("/work/.max/out/max-2.txt"), "{shown}");
        assert_eq!(output.head.len() + output.tail.len(), SHOWN);
        assert_eq!(std::fs::read(&path).unwrap(), all);
        let _ = std::fs::remove_dir_all(work);
    }

    /// The guest's link at /work/.max: a long output isn't written through
    /// it.
    #[tokio::test]
    async fn long_output_follows_no_link() {
        let scratch = std::env::temp_dir().join(format!("max-output-link-{}", std::process::id()));
        let (work, host) = (scratch.join("work"), scratch.join("host"));
        std::fs::create_dir_all(&work).unwrap();
        std::fs::create_dir_all(host.join("out")).unwrap();
        std::os::unix::fs::symlink(&host, work.join(".max")).unwrap();
        let mut output = Output::new(&work, "max-3.txt".into());
        let long = vec![b'x'; SHOWN + 1];
        assert!(output.output(Stream::Out, &long).await.is_err());
        assert!(!host.join("out/max-3.txt").exists());
        let _ = std::fs::remove_dir_all(scratch);
    }

    #[test]
    fn calls_are_summed_up_per_tool() {
        assert_eq!(called(&BTreeMap::new()), "");
        let calls = BTreeMap::from([
            ("history".to_owned(), (3, 1)),
            ("memory_list".to_owned(), (1, 0)),
        ]);
        assert_eq!(
            called(&calls),
            "\n调了 Max 的工具：history 4 次（失败 1 次），memory_list 1 次"
        );
    }
}
