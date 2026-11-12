//! `run_code`: a program in the guest's runner, which calls Max's tools.

use super::*;

/// What the runner reads on its stdin: the program, its arguments, and
/// the names of Max's tools.
#[derive(Serialize)]
struct RunnerInput<'a> {
    code: &'a str,
    args: Option<serde_json::Value>,
    tools: &'static [&'static str],
}

/// The tools a program may call: all of them, as its `maxx` may, those
/// the prompt doesn't declare too.
static TOOL_NAMES: LazyLock<Vec<&'static str>> =
    LazyLock::new(|| mcp::tool::TOOLS.iter().map(|tool| tool.name).collect());

/// What the model is told of the program. The result and the console are
/// cut as `shell`'s output is.
pub(super) async fn run_code(
    vm: &Vm,
    code: &str,
    args: Option<serde_json::Value>,
    limit: Duration,
) -> Result<Told> {
    let input = RunnerInput {
        code,
        args,
        tools: &TOOL_NAMES,
    };
    let input = serde_json::to_vec(&input).expect("the runner's input is JSON");
    let unit = Unit {
        title: "run_code",
        workdir: "/work",
        limit,
        split: true,
    };
    let ended = wait(vm, unit, "exec node /run/max/runner.js", Some(&input)).await?;
    if let Some(why) = &ended.failed {
        return Ok(Told {
            text: format!("the program didn't run: {}", why.trim()),
            error: true,
            left: Vec::new(),
        });
    }
    let result = shown(ended.out.as_ref());
    let (head, error) = match ended.ran() {
        Ran::Exited(0) if result.is_empty() => (
            "the program finished and returned nothing".to_owned(),
            false,
        ),
        Ran::Exited(0) => (format!("returned:\n{result}"), false),
        Ran::Exited(1) => (format!("the program failed:\n{result}"), true),
        Ran::Exited(code) => (
            with(format!("the runner's exit status {code}"), &result),
            true,
        ),
        Ran::OutOfTime => (with(shell::out_of_time(limit), &result), true),
        Ran::Killed(how) => (
            with(format!("the runner was ended by {how}"), &result),
            true,
        ),
    };
    let mut text = head;
    let console = shown(ended.err.as_ref());
    if !console.is_empty() {
        text.push_str("\nconsole output:\n");
        text.push_str(&console);
    }
    Ok(Told {
        text,
        error,
        left: ended.shown,
    })
}
