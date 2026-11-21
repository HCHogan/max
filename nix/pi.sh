# pi, as the guest has it: the pinned pi (PI_BIN) on the models max
# serves the VM at 127.0.0.1:7777/llm, which keeps their keys. Max runs
# it in a background command for work of many steps, and programs may
# run it too. See "Background agents" in docs/design/jobs.md.
#
# Before each run it writes into pi's agent directory what is the
# guest's: every model max serves, as the provider `max` in models.json;
# the agents' default model and effort, and retries long enough to
# outlast a restart of max, in settings.json; and what an agent is told
# of itself, APPEND_SYSTEM.md (PI_SYSTEM). The rest of the directory is
# whoever's runs pi: their providers, settings and AGENTS.md. With max
# out of reach it runs on what an earlier run wrote.
#
# It refuses --session-id ID when pi keeps a session ID only for other
# directories: pi would start a new one by that name, saying so only on
# stderr, and a run meant to go on from what an agent did would start
# from nothing.

agent=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}
mkdir -p "$agent"

# Sets in a JSON file what filter says, given new, and keeps the rest of
# it; one that isn't a JSON object starts anew. Written whole and then
# renamed, as two runs may start at once.
merge() {
  local file=$1 filter=$2 new=$3 old written
  old=$(jq -c 'if type == "object" then . else {} end' "$file" 2> /dev/null) || old=""
  [ -n "$old" ] || old="{}"
  written=$(mktemp "$file.XXXXXX")
  jq --argjson new "$new" "$filter" <<< "$old" > "$written"
  mv "$written" "$file"
}

# What max says of the models: the agents' own, with its effort, and
# under .models every one a run can name.
about=$(curl -s -m 10 http://127.0.0.1:7777/llm -w '\n%{http_code}' || true)
if [ "${about##*$'\n'}" = 200 ]; then
  about=${about%$'\n'*}
  # Each as max names it, provider/model, and over the protocol it
  # speaks. Any may be asked to think: pi sends no effort for off, and a
  # model that can't think says so. The two highest efforts go as they
  # are, which pi would send as high to a model outside its own list.
  provider=$(jq -c '{
    baseUrl: "http://127.0.0.1:7777/llm",
    api: .api,
    apiKey: "max",
    models: [(.models // []) + [del(.effort, .models)] | unique_by(.model)[]
      | {
          id: .model,
          api,
          reasoning: true,
          thinkingLevelMap: { xhigh: "xhigh", max: "max" },
          input: ["text", "image"],
          contextWindow: .window
        }
        + (if .max_output then { maxTokens: .max_output } else {} end)]
  }' <<< "$about")
  # shellcheck disable=SC2016 # jq's $new, not the shell's
  merge "$agent/models.json" '.providers.max = $new' "$provider"
  # pi tries a failed call 3 times by default, over 14 seconds.
  # shellcheck disable=SC2016 # jq's $new, not the shell's
  merge "$agent/settings.json" '
    .defaultProvider = "max"
    | .defaultModel = $new.model
    | .defaultThinkingLevel = ($new.effort // "off")
    | .retry.maxRetries = ([.retry.maxRetries // 0, 8] | max)' "$about"
fi

if ! cmp -s "$PI_SYSTEM" "$agent/APPEND_SYSTEM.md"; then
  written=$(mktemp "$agent/APPEND_SYSTEM.md.XXXXXX")
  cat "$PI_SYSTEM" > "$written"
  mv "$written" "$agent/APPEND_SYSTEM.md"
fi

# The session it is to go on from, and where pi keeps sessions.
id=""
sessions=$agent/sessions
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --session-id) id=${args[i + 1]-} ;;
    --session-id=*) id=${args[i]#--session-id=} ;;
    --session-dir) sessions=${args[i + 1]-} ;;
    --session-dir=*) sessions=${args[i]#--session-dir=} ;;
  esac
done
if [ -n "$id" ] && [ -d "$sessions" ]; then
  here=$(pwd -P)
  found=()
  while IFS= read -r -d '' file; do
    # A session's first line names the directory it is for; one that
    # doesn't say is left out.
    cwd=$(head -n 1 "$file" | jq -rR 'fromjson? | .cwd // empty')
    [ -z "$cwd" ] || found+=("$cwd")
  done < <(find "$sessions" -name "*_$id.jsonl" -print0)
  if [ "${#found[@]}" -gt 0 ] && ! printf '%s\n' "${found[@]}" | grep -qxF -- "$here"; then
    others=$(printf '%s\n' "${found[@]}" | sort -u | paste -sd ' ')
    echo "pi: the session $id is in $others, not $here: run pi there to go on with it, or give this run another id" >&2
    exit 2
  fi
fi

export PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0
exec "$PI_BIN" "$@"
