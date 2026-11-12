# max-pi UNIT: pi in print mode, as one of Max's background agents: the
# unit `max-agent start` made for it (max-agent.sh), with its task, its
# directory and the model in /run/max/jobs/UNIT. max-agent.ts, pi's
# plugin, keeps the agent's side: the steers in its inbox, the wrap-up,
# the stop and the report. pi's model calls go to max at 127.0.0.1:7777,
# which adds the provider's key; the agent calls Max's tools with maxx,
# as any program in the VM does. See "Background agents" in
# docs/rust-rewrite.md.

export LC_ALL=C.UTF-8

# No apostrophe in the message: bash would take it for a quote.
unit=${1:?max-pi takes the unit of the agent}
dir=/run/max/jobs/$unit
# The unit's, removed when it stops.
conf=${RUNTIME_DIRECTORY:?max-pi runs with a RuntimeDirectory}
workdir=$(cat "$dir/workdir")
# What max-agent start chose of what max says of the models: its api
# ("openai-completions" or "openai-responses"), the name max calls it by,
# window, max_output and effort (or null).
model=$(cat "$dir/model.json")
field() { jq -r "$1" <<< "$model"; }

jq -n --argjson model "$model" '{
  providers: { max: {
    baseUrl: "http://127.0.0.1:7777/llm",
    api: $model.api,
    apiKey: "max",
    models: [{
      id: $model.model,
      reasoning: ($model.effort != null),
      # The two highest efforts go as they are, for the provider to take
      # or refuse: to a model outside its own list pi sends high for them.
      thinkingLevelMap: { xhigh: "xhigh", max: "max" },
      input: ["text", "image"],
      contextWindow: $model.window
    } + (if $model.max_output then { maxTokens: $model.max_output } else {} end)]
  } }
}' > "$conf/models.json"

# Steers that a turn's end takes in all go in before the next model call,
# not one a call. And a model call is tried again for long enough to
# outlast a restart of max: 3 tries, pi's default, are over in 14 seconds.
jq -n '{ steeringMode: "all", retry: { maxRetries: 8 } }' > "$conf/settings.json"

# The agents' notes for this directory: named after its path, letters and
# digits kept and the rest made -, as Claude Code names its projects.
name=$(realpath -ms "$workdir")
name=${name#/}
name=${name//\//-}
name=${name//[^[:alnum:]]/-}
name=${name:0:120}
notes_file=/work/.max/projects/${name:-root}.md
if [ -L "$notes_file" ]; then
  notes="（没读到：它是个链接。）"
elif [ ! -e "$notes_file" ]; then
  notes="（还没有，这次新建。）"
elif [ "$(stat -c %s "$notes_file")" -gt 1048576 ]; then
  notes="（没读到：超过 1 MiB 了。）"
elif [ "$(stat -c %s "$notes_file")" -gt 16384 ]; then
  # Cut at a line.
  notes="$(head -c 16384 "$notes_file" | sed '$d')
（笔记超过 16 KiB，后面的没加载：更新时精简一下。）"
else
  notes=$(cat "$notes_file")
fi

# Not system.md: where case doesn't count, as on the Mac, that is pi's
# SYSTEM.md, which takes the place of pi's own prompt.
# Quoted: bash would put what it matched for each & in what goes in, and
# notes say `make && make test`.
system=$(cat "$MAX_AGENT_SYSTEM")
system=${system//@WORKDIR@/"$workdir"}
system=${system//@NOTES_FILE@/"$notes_file"}
system=${system//@NOTES@/"$notes"}
printf '%s\n' "$system" > "$conf/agent-system.md"

export MAX_AGENT=$unit MAX_AGENT_DIR=$dir MAX_AGENT_REPORTS=/work/.max/jobs
export PI_CODING_AGENT_DIR=$conf PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0

args=(
  --print
  # The project's .pi/ is the group's to write: not trusted. Context
  # files (AGENTS.md or CLAUDE.md in cwd and its parents) still load.
  --no-approve
  --session-dir /work/.max/jobs
  --provider max
  --model "$(field .model)"
  --append-system-prompt "$conf/agent-system.md"
  --extension "$MAX_AGENT_PLUGIN"
)
effort=$(field '.effort // empty')
if [[ -n $effort ]]; then
  args+=(--thinking "$effort")
fi
cd "$workdir"
# The task goes in on stdin: as an argument, an @ at its start would name
# a file to read.
exec pi "${args[@]}" < "$dir/task"
