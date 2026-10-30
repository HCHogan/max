# max-pi: pi in RPC mode, for one of Max's background jobs. The first
# line of stdin is the job as JSON (see "后台 agent" in
# docs/rust-rewrite.md); the rest is pi's RPC. pi's model calls and Max's
# tools both go to Max's MCP service at 127.0.0.1:7777 with the job's
# token: the provider's key stays on the host.
#
# The job: token, model (the provider's id), api ("openai-completions" or
# "openai-responses"), window, max_output and effort (or null), and
# system, appended to pi's system prompt.

IFS= read -r job
field() { jq -r "$1" <<<"$job"; }

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

field .system >"$dir/system.md"

MAX_JOB_TOKEN=$(field .token)
export MAX_JOB_TOKEN PI_CODING_AGENT_DIR=$dir PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0

args=(
  --mode rpc
  # .pi/ in /work is the group's to write: not trusted.
  --no-approve
  --session-dir /work/.max/jobs
  --provider max
  --model "$(field .model)"
  --append-system-prompt "$dir/system.md"
  --extension "$MAX_ASK_MAX"
)
effort=$(field '.effort // empty')
if [[ -n $effort ]]; then
  args+=(--thinking "$effort")
fi
exec pi "${args[@]}"
