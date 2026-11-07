# max-pi: pi in print mode, for one of Max's background jobs. The first
# line of stdin is the job as JSON, and all max writes; max-job.ts keeps
# the job's contract with the host (see "后台 agent" and "和 harness 脱钩"
# in docs/rust-rewrite.md). pi's model calls and Max's tools both go to
# Max's MCP service at 127.0.0.1:7777 with the job's token: the
# provider's key stays on the host.
#
# The job: contract (1), token, task, model (the provider's id), api
# ("openai-completions" or "openai-responses"), window, max_output and
# effort (or null), and system, appended to pi's system prompt.

IFS= read -r job
field() { jq -r "$1" <<<"$job"; }

contract=$(field .contract)
if [[ $contract != 1 ]]; then
  echo "max-pi keeps contract 1, not $contract" >&2
  exit 2
fi

# The unit's, removed when it stops: the token doesn't outlive the job.
dir=${RUNTIME_DIRECTORY:?max-pi runs with a RuntimeDirectory}

jq -n --argjson job "$job" '{
  providers: { max: {
    baseUrl: "http://127.0.0.1:7777/llm",
    api: $job.api,
    apiKey: "$MAX_JOB_TOKEN",
    models: [{
      id: $job.model,
      reasoning: ($job.effort != null),
      input: ["text", "image"],
      contextWindow: $job.window
    } + (if $job.max_output then { maxTokens: $job.max_output } else {} end)]
  } }
}' >"$dir/models.json"

jq -n '{ mcpServers: { max: {
  url: "http://127.0.0.1:7777/mcp",
  headers: { Authorization: "Bearer ${MAX_JOB_TOKEN}" },
  exposure: "direct"
} } }' >"$dir/mcp.json"

# Steers that a turn's end takes in all go in before the next model call,
# not one a call.
jq -n '{ steeringMode: "all" }' >"$dir/settings.json"

# Not system.md: where case doesn't count, as on the Mac, that is pi's
# SYSTEM.md, which takes the place of pi's own prompt.
field .system >"$dir/job-system.md"
# The task goes in on stdin: as an argument, an @ at its start would name
# a file to read.
jq -j .task <<<"$job" >"$dir/task.md"

MAX_JOB_TOKEN=$(field .token)
# The job's, for max-job.ts and for maxx in pi's shell: it calls as the
# job.
MAXX_TOKEN=$MAX_JOB_TOKEN
export MAX_JOB_TOKEN MAXX_TOKEN PI_CODING_AGENT_DIR=$dir PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0

args=(
  --print
  # .pi/ in /work is the group's to write: not trusted.
  --no-approve
  --session-dir /work/.max/jobs
  --provider max
  --model "$(field .model)"
  --append-system-prompt "$dir/job-system.md"
  --extension "$MAX_JOB"
)
effort=$(field '.effort // empty')
if [[ -n $effort ]]; then
  args+=(--thinking "$effort")
fi
exec pi "${args[@]}" <"$dir/task.md"
