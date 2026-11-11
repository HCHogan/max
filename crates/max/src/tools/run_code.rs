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

/// The tools a program in a turn may call: all of them, as its `maxx`
/// may. Those the prompt doesn't declare, `say` and `wake`, run as a
/// program's; see [`mcp::Caller::route`].
static TOOL_NAMES: LazyLock<Vec<&'static str>> =
    LazyLock::new(|| mcp::tool::TOOLS.iter().map(|tool| tool.name).collect());

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
        tools: &TOOL_NAMES,
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
            Some(0) if result.is_empty() => (
                "the program finished and returned nothing".to_owned(),
                false,
            ),
            Some(0) => (format!("returned:\n{result}"), false),
            Some(1) => (format!("the program failed:\n{result}"), true),
            Some(code) => (
                with(format!("the runner's exit status {code}"), &result),
                true,
            ),
            None => (
                with(
                    "the runner has no exit status: it may have been killed".into(),
                    &result,
                ),
                true,
            ),
        },
        Waited::Interrupted(()) => {
            let stopped = running.stop(vm.connection()).await;
            let head = format!(
                "not done in {} seconds; {}",
                limit.as_secs(),
                stopping(&stopped)
            );
            (with(head, &result), true)
        }
    };
    let mut shown = head;
    let console = split.err.shown();
    if !console.is_empty() {
        shown.push_str("\nconsole output:\n");
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
