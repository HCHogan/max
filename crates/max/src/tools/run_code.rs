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
    let input = RunnerInput {
        code,
        args,
        token: grant.token(),
        tools: &TOOL_NAMES,
    };
    let input = serde_json::to_vec(&input).expect("the runner's input is JSON");
    let unit = Unit {
        title: "run_code",
        workdir: "/work",
        limit,
        // The runner has the token from its input.
        token: None,
        split: true,
    };
    let ended = wait(vm, unit, "exec node /run/max/runner.js", Some(&input)).await?;
    if let Some(why) = &ended.failed {
        return Ok((format!("the program didn't run: {}", why.trim()), true));
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
    let mut shown = head;
    let console = super::shown(ended.err.as_ref());
    if !console.is_empty() {
        shown.push_str("\nconsole output:\n");
        shown.push_str(&console);
    }
    shown.push_str(&called(&grant.calls()));
    Ok((shown, error))
}
