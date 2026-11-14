# Max's background agents, each a unit of the guest's that runs pi on a
# task (max-pi.sh) for hours, while Max goes on in the chat: `maxx agent`'s
# start, models, steer and ask, which bin/maxx runs with their arguments
# as a JSON object (maxx.nix, local.json). max, the host, keeps nothing
# of an agent. See "Background agents" in docs/rust-rewrite.md.
#
#   maxx agent start {task, title, workdir, model, effort}
#       Starts an agent on the task and says its name, max-agent-N. Its
#       report comes back to Max when it ends. It runs on the agents' own
#       model, or on the one named, and thinks as hard as effort says,
#       one of pi's --thinking: the provider is asked for just that, and
#       may refuse it.
#   maxx agent models {}
#       The models an agent can run on, each with its window.
#   maxx agent steer {name, text}
#       What to tell a running agent: a change of direction, more to go
#       on, or the answer to what it asked.
#   maxx agent ask {text}
#       For an agent itself: asks its Max.
#
# maxx units list shows the agents with the background commands, and
# systemctl stop NAME stops one: nothing comes back from it then.

export LC_ALL=C.UTF-8

jobs=/run/max/jobs
# Where the agents' sessions and reports are kept, and their count.
kept=/work/.max/jobs
# How many run at once: each costs model calls for as long as it runs.
most=3
# An agent's time: 6 hours. Two hours until 2026-11-11, when the owner
# found it too short.
limit=21600

fail() {
  echo "$1" >&2
  exit 1
}

# The texts of a JSON object's fields, as assignments for eval. What
# isn't such an object is a wrong command line, and so is a field that
# isn't one of them: it would be left out in silence.
fields() {
  local json=$1 parsed
  shift
  if ! parsed=$(jq -r '
      if type == "object" then . else error("the arguments are a JSON object") end
      | (keys - $ARGS.positional) as $odd
      | if $odd == [] then .
        elif $ARGS.positional == [] then error("it takes no arguments")
        else error("there is no argument \($odd[0]); there are: \($ARGS.positional | join(", "))") end
      | . as $given | $ARGS.positional[]
      | . as $name | ($given[$name] // "")
      | if type == "string" then "\($name)=\(@sh)" else error("\($name) is text") end
    ' --args "$@" <<< "$json" 2>&1); then
    parsed=${parsed#jq: error (at <stdin>:*): }
    case "$parsed" in
      "jq: parse error: "*) parsed="the arguments aren't JSON: ${parsed#jq: parse error: }" ;;
    esac
    echo "$parsed" >&2
    exit 2
  fi
  echo "$parsed"
}

# What max says of the models, in a file: the agents' own, and under
# .models every one a call can name. The keys stay with max.
told() {
  local about status
  about=$(mktemp)
  status=$(curl -s -m 20 -o "$about" -w '%{http_code}' http://127.0.0.1:7777/llm || true)
  case "$status" in
    200) echo "$about" ;;
    404) rm -f "$about" && fail "no model is configured for background agents" ;;
    *) rm -f "$about" && fail "max can't be reached for the agents' model just now ($status); try again in a moment" ;;
  esac
}

models() {
  local about
  about=$(told)
  # The agents' own first.
  jq -c '.model as $own | .effort as $effort
    | {models: ([(.models // [.])[] | select(.model == $own)] + [(.models // [])[] | select(.model != $own)]
        | map({model, window, default: (.model == $own)}
            + (if .model == $own and $effort then {effort: $effort} else {} end)))}' "$about"
  rm -f "$about"
}

start() {
  local task="" title="" workdir="" model="" effort=""
  local given
  given=$(fields "$1" task title workdir model effort) || exit $?
  eval "$given"
  # pi's levels: it takes any other word for medium, and says so where
  # nobody reads it.
  case "$effort" in
    "" | off | minimal | low | medium | high | xhigh | max) ;;
    *) fail "effort is one of off, minimal, low, medium, high, xhigh and max, not $effort" ;;
  esac
  [ -n "${task//[[:space:]]/}" ] || fail "there is no task: maxx agent start --title … --task - <<'EOF' … EOF"
  case "$workdir" in
    "") workdir=/work ;;
    /*) ;;
    *) workdir=/work/$workdir ;;
  esac
  # One start at a time, from the count to the unit: two at once would
  # each find room for the last.
  mkdir -p "$kept"
  exec 9> "$kept/.lock"
  flock 9
  local running
  running=$(systemctl list-units --no-legend --plain --state=active,activating 'max-agent-*.service' | wc -l)
  [ "$running" -lt "$most" ] || fail "$most background agents run already: wait for one to end, or stop one with systemctl stop"

  # The model it runs on, as max-pi reads it: the agents' own with its
  # effort, or the one named, which thinks as hard as --effort says or
  # as it does when nothing is said.
  local about chosen
  about=$(told)
  chosen=$(jq -c --arg model "$model" --arg effort "$effort" '
    (if $model == "" or $model == .model then del(.models)
     else (.models // [])[] | select(.model == $model) end)
    | if $effort == "" then . else .effort = $effort end' "$about")
  rm -f "$about"
  [ -n "$chosen" ] || fail "there is no model $model: maxx agent models lists them"
  model=$(jq -r .model <<< "$chosen")

  mkdir -p "$workdir" "$kept" /work/.max/projects
  local number unit dir
  number=$(($(cat "$kept/.count" 2> /dev/null || echo 0) + 1))
  echo "$number" > "$kept/.count"
  unit=max-agent-$number
  dir=$jobs/$unit
  mkdir -p "$dir/inbox"
  printf '%s\n' "$task" > "$dir/task"
  echo "$workdir" > "$dir/workdir"
  printf '%s\n' "$chosen" > "$dir/model.json"
  if [ -z "${title//[[:space:]]/}" ]; then
    # The task's first line, cut short.
    title=$(sed -n '/[^[:space:]]/{s/^[[:space:]]*//;p;q}' <<< "$task")
    [ "${#title}" -le 30 ] || title=${title:0:30}…
  fi
  maxx units agent --unit "$unit" --limit "$limit" --title "$title" --workdir "$workdir" -- "$(command -v max-pi)" "$unit"
  exec 9>&-
  jq -nc --arg name "$unit" --arg said "$unit started in $workdir on $model, for at most $((limit / 3600)) hours. When it ends, its report comes back to you as [$unit 完成]: don't wait for it. To tell it more, maxx agent steer $unit with the words after it; to stop it, systemctl stop $unit." \
    '{name: $name, said: $said}'
}

steer() {
  local name="" text=""
  local given
  given=$(fields "$1" name text) || exit $?
  eval "$given"
  local unit=$name dir=$jobs/$name
  [[ $unit =~ ^max-agent-[0-9]+$ ]] || fail "steer takes an agent's name, max-agent-N, and what to tell it"
  if [ ! -d "$dir/inbox" ] || ! systemctl is-active --quiet "$unit.service"; then
    fail "$unit isn't running: it ended, was stopped, or never was"
  fi
  [ -n "${text//[[:space:]]/}" ] || fail "there is nothing to tell $unit: maxx agent steer $unit <text>, or --text - for standard input"
  # Whole before the agent sees it: a name with a dot is still written.
  local new
  new=$(mktemp "$dir/inbox/.new.XXXXXX")
  printf '%s\n' "$text" > "$new"
  mv "$new" "$dir/inbox/$(date +%s%N)"
  jq -nc --arg said "$unit will read it at the end of the step it is in." '{said: $said}'
}

ask() {
  local unit=${MAX_AGENT:-}
  [ -n "$unit" ] || fail "ask is for an agent to ask its Max; Max tells an agent something with maxx agent steer"
  local text=""
  local given
  given=$(fields "$1" text) || exit $?
  eval "$given"
  [ -n "${text//[[:space:]]/}" ] || fail "there is no question: maxx agent ask <text>, or --text - for standard input"
  local title
  title=$(cat "$jobs/$unit/title" 2> /dev/null || true)
  jq -n --arg text "[$unit 问] $title
$text
（回答它用 maxx agent steer $unit '回答'，长的写 --text - 从标准输入给；它没别的可做时最多再等 10 分钟。这一问一答都不进群。）" '{text: $text}' \
    | maxx wake - > /dev/null
  # The agent waits for the answer once it has nothing else to do.
  touch "$jobs/$unit/asked"
  jq -nc --arg said "Max has the question; its answer will appear in the conversation. Go on with whatever else there is to do." '{said: $said}'
}

case "${1:-}" in
  start) start "${2:-}" ;;
  models)
    # It takes none: fields, given no names, refuses any.
    json=${2:-}
    [ -n "$json" ] || json="{}"
    fields "$json" > /dev/null
    models
    ;;
  steer) steer "${2:-}" ;;
  ask) ask "${2:-}" ;;
  *) fail "start, models, steer or ask, not '${1:-}'" ;;
esac
