//! `run_code`: a program in the guest's runner, which calls Max's tools
//! as the run.

use super::*;

/// What the runner reads on its stdin: the program, its arguments, the
/// token it calls Max's tools with, and their names.
#[derive(Serialize)]
struct RunnerInput<'a> {
    code: &'a str,
    args: Option<serde_json::Value>,
    token: &'a str,
    tools: &'static [&'static str],
}

/// The tools a program in a turn may call.
static TURN_TOOLS: LazyLock<Vec<&'static str>> = LazyLock::new(|| {
    mcp::tool::TOOLS
        .iter()
        .filter(|tool| tool.turn)
        .map(|tool| tool.name)
        .collect()
});

/// What the model is shown, and whether the program failed. The result
/// and the console are cut as `shell`'s output is.
pub(super) async fn run_code(
    vm: &Vm,
    grant: &Grant,
    code: &str,
    args: Option<serde_json::Value>,
    limit: Duration,
) -> Result<(String, bool)> {
    let unit = Vm::unit();
    // The runner has the token from its input.
    let line = unit_line(&unit, limit, "/work", "exec node /run/max/runner.js", None);
    let input = RunnerInput {
        code,
        args,
        token: grant.token(),
        tools: &TURN_TOOLS,
    };
    let input = serde_json::to_vec(&input).expect("the runner's input is JSON");
    let mut split = Split {
        out: Output::new(vm.work(), format!("{unit}.txt")),
        err: Output::new(vm.work(), format!("{unit}.log")),
    };
    let mut running = vm.command(unit, &line, &input).await?;
    let waited = running.wait_or(&mut split, sleep(limit)).await;
    split.out.finish().await?;
    split.err.finish().await?;
    let result = split.out.shown();
    let (head, error) = match waited? {
        Waited::Exited(status) => match status {
            Some(0) if result.is_empty() => ("程序跑完了，没有返回值。".to_owned(), false),
            Some(0) => (format!("返回值：\n{result}"), false),
            Some(1) => (format!("程序出错了：\n{result}"), true),
            Some(code) => (with(format!("runner 的退出码 {code}"), &result), true),
            None => (with("runner 没有退出码，可能被杀了".into(), &result), true),
        },
        Waited::Interrupted(()) => {
            let stopped = running.stop(vm.connection()).await;
            let head = format!("{} 秒内没跑完，{}", limit.as_secs(), stopping(&stopped));
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
