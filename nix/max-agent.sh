# max-agent: Max's background agents, each a unit of the guest's that runs
# pi on a task (max-pi.sh) for hours, while Max goes on in the chat. Max
# runs this with shell; max, the host, keeps nothing of an agent. See
# "Background agents" in docs/rust-rewrite.md.
#
#   max-agent start [--title TEXT] [--workdir DIR] [--model NAME] [--effort LEVEL]
#       The task on standard input: starts an agent on it and says its
#       name, max-agent-N. Its report comes back to Max when it ends.
#       It runs on the agents' own model, or on the one named, and
#       thinks as hard as LEVEL says, one of pi's --thinking: the
#       provider is asked for just that, and may refuse it.
#   max-agent models
#       The models an agent can run on, each with its window.
#   max-agent steer NAME
#       What to tell a running agent, on standard input: a change of
#       direction, more to go on, or the answer to what it asked.
#   max-agent ask [TEXT]
#       For an agent itself: asks its Max, TEXT or standard input.
#
# max-jobs list shows the agents with the background commands, and
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
  echo "max-agent: $1" >&2
  exit 1
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
  jq -r '.model as $own | .effort as $effort
    | [(.models // [.])[] | select(.model == $own)] + [(.models // [])[] | select(.model != $own)]
    | .[]
    | "\(.model)  \(.window) tokens"
      + (if .model == $own then "  (the default" + (if $effort then ", effort \($effort)" else "" end) + ")" else "" end)' "$about"
  rm -f "$about"
}

start() {
  local title="" workdir=/work model="" effort=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title=$2 && shift 2 ;;
      --workdir) workdir=$2 && shift 2 ;;
      --model) model=$2 && shift 2 ;;
      --effort) effort=$2 && shift 2 ;;
      *) fail "start takes --title, --workdir, --model and --effort, not $1; the task comes on standard input" ;;
    esac
  done
  # pi's levels: it takes any other word for medium, and says so where
  # nobody reads it.
  case "$effort" in
    "" | off | minimal | low | medium | high | xhigh | max) ;;
    *) fail "--effort is one of off, minimal, low, medium, high, xhigh and max, not $effort" ;;
  esac
  local task
  task=$(cat)
  [ -n "${task//[[:space:]]/}" ] || fail "the task comes on standard input: max-agent start --title … <<'EOF' … EOF"
  case "$workdir" in
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
  [ -n "$chosen" ] || fail "there is no model $model: max-agent models lists them"
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
  max-jobs start --unit "$unit" --agent --limit "$limit" --title "$title" --workdir "$workdir" -- max-pi "$unit"
  exec 9>&-
  echo "$unit started in $workdir on $model, for at most $((limit / 3600)) hours. When it ends, its report comes back to you as [$unit 完成]: don't wait for it. To tell it more, max-agent steer $unit with the words on standard input; to stop it, systemctl stop $unit."
}

steer() {
  local unit=${1:-} dir=$jobs/${1:-}
  [[ $unit =~ ^max-agent-[0-9]+$ ]] || fail "steer takes an agent's name, max-agent-N, and the words on standard input"
  if [ ! -d "$dir/inbox" ] || ! systemctl is-active --quiet "$unit.service"; then
    fail "$unit isn't running: it ended, was stopped, or never was"
  fi
  local text new
  text=$(cat)
  [ -n "${text//[[:space:]]/}" ] || fail "what to tell $unit comes on standard input"
  # Whole before the agent sees it: a name with a dot is still written.
  new=$(mktemp "$dir/inbox/.new.XXXXXX")
  printf '%s\n' "$text" > "$new"
  mv "$new" "$dir/inbox/$(date +%s%N)"
  echo "$unit will read it at the end of the step it is in."
}

ask() {
  local unit=${MAX_AGENT:-}
  [ -n "$unit" ] || fail "ask is for an agent to ask its Max; Max tells an agent something with max-agent steer"
  local text=${1:-}
  [ -n "$text" ] || text=$(cat)
  [ -n "${text//[[:space:]]/}" ] || fail "the question comes as an argument or on standard input"
  local title
  title=$(cat "$jobs/$unit/title" 2> /dev/null || true)
  jq -n --arg text "[$unit 问] $title
$text
（回答它用 max-agent steer $unit，内容从标准输入给；它没别的可做时最多再等 10 分钟。这一问一答都不进群。）" '{text: $text}' \
    | maxx wake - > /dev/null
  # The agent waits for the answer once it has nothing else to do.
  touch "$jobs/$unit/asked"
  echo "Max has the question; its answer will appear in the conversation. Go on with whatever else there is to do."
}

case "${1:-}" in
  start) shift && start "$@" ;;
  models) models ;;
  steer) shift && steer "$@" ;;
  ask) shift && ask "$@" ;;
  *) fail "start, models, steer or ask, not '${1:-}'" ;;
esac
