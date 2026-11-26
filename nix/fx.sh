# fx, as the guest has it: the pinned fx (FX_BIN) on the models max
# serves the VM at 127.0.0.1:7777/llm, which keeps their keys. Max runs
# it in a background command for work of many steps, and programs may
# run it too. See "Background agents" in docs/design/jobs.md.
#
#   fx ask [--session NAME] [fx ask's own options] [task]
#   fx models
#
# --session is the wrapper's: fx names its sessions itself, so each
# name has an fx home of its own, in which the session of a directory is
# the one `--resume last` goes on with. A run without a name keeps no
# session. `fx models` is answered here, as fx lists one connection's
# models and max's are on two. Anything else goes to fx as it is.
#
# Before each run it writes what is the guest's into the fx home: every
# model max serves, as custom connections in settings.json, with the
# agents' default model and effort; and what an agent is told of itself,
# AGENTS.md (FX_SYSTEM). With max out of reach it runs on what an
# earlier run was told.
#
# It refuses a name whose session is kept only for other directories:
# fx would start a new one, and a run meant to go on from what an agent
# did would start from nothing.

base=$HOME/.max/fx
mkdir -p "$base"

# What max says of the models: the agents' own, with its effort, and
# under .models every one a run can name.
about=$(curl -s -m 10 http://127.0.0.1:7777/llm -w '\n%{http_code}' || true)
if [ "${about##*$'\n'}" = 200 ]; then
  written=$(mktemp "$base/about.json.XXXXXX")
  printf '%s\n' "${about%$'\n'*}" > "$written"
  mv "$written" "$base/about.json"
fi
if ! about=$(jq -ce 'select(type == "object")' "$base/about.json" 2> /dev/null); then
  echo "fx: max is out of reach, and no earlier run was told its models" >&2
  exit 1
fi

# A connection of fx's has one protocol, so max's models are on two.
# shellcheck disable=SC2016 # jq's, not the shell's
connection='def connection: if .api == "openai-responses" then "max-responses" else "max" end;'

if [ "${1-}" = models ]; then
  jq -r '.model as $own
    | (.models // []) + [del(.effort, .models)] | unique_by(.model)[]
    | "\(.model)\t\(.window) tokens" + (if .model == $own then "\tdefault" else "" end)' <<< "$about"
  exit
fi

name="" model="" args=()
if [ "${1-}" = ask ]; then
  shift
  # An agent has nobody to ask.
  args=(ask --full-access)
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) name=${2-}; shift; [ $# -eq 0 ] || shift ;;
      --session=*) name=${1#--session=}; shift ;;
      --model) model=${2-}; args+=("$1"); shift ;;
      --model=*) model=${1#--model=}; args+=("$1"); shift ;;
      # The task, as it is.
      --) args+=("$@"); break ;;
      *) args+=("$1"); shift ;;
    esac
  done
  # The name is a directory's.
  if [ -n "$name" ] && ! [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "fx: a session's name is of letters, digits, - _ and ., and starts with a letter or digit: $name" >&2
    exit 2
  fi
  # A model max serves is called on its protocol's connection; any other
  # goes to the agents' own, as max sends it.
  provider=$(jq -r --arg model "$model" "$connection"'
    first((.models // [])[] | select(.model == $model) | connection) // empty' <<< "$about")
  [ -z "$provider" ] || args=(ask --full-access --provider "$provider" "${args[@]:2}")
else
  args=("$@")
fi

# Each model as max names it, on its protocol's connection, with what
# it may be asked: any effort, which a model that can't think refuses
# itself. The agents' own is the one a run is on that names none. fx
# waits for an answer longer than max does for a provider's, so that max
# is the one to give up; and it is told that full access was explained,
# which it would otherwise write into the file itself, with a copy of
# it, each run.
settings=$(jq -c "$connection"'
  def efforts($more): (["minimal", "low", "medium", "high", "xhigh", "max"] + $more | unique) as $levels
    | if .api == "openai-responses"
      then $levels | map({ key: ., value: { reasoning: { effort: . } } })
      else $levels | map({ key: ., value: { reasoning_effort: . } })
      end
    | from_entries;
  [.effort // empty] as $asked
  | ((.models // []) + [del(.effort, .models)] | unique_by(.model)) as $models
  | {
      provider: connection,
      models: { (connection): .model },
      auto_upgrade: false,
      yolo_acknowledged: true,
      providers: ($models | group_by(connection) | map({
        key: (.[0] | connection),
        value: {
          protocol: .[0].api,
          base_url: "http://127.0.0.1:7777/llm",
          auth: { type: "none" },
          timeouts: { first_response_ms: 900000, stall_ms: 900000 },
          model_metadata: (map({
            key: .model,
            value: ({
                context_window: .window,
                supports_tool_use: true,
                supports_vision: true,
                reasoning_efforts: efforts($asked)
              }
              + (if .max_output then { max_output_tokens: .max_output } else {} end))
          }) | from_entries)
        }
      }) | from_entries)
    }
    + (if .effort then { effort } else {} end)' <<< "$about")

if [ -n "$name" ]; then
  export FX_HOME="$base/sessions/$name"
else
  export FX_HOME="$base/home"
fi
mkdir -p "$FX_HOME"
# Written whole and then renamed, as two runs may start at once.
written=$(mktemp "$FX_HOME/settings.json.XXXXXX")
printf '%s\n' "$settings" > "$written"
mv "$written" "$FX_HOME/settings.json"
if ! cmp -s "$FX_SYSTEM" "$FX_HOME/AGENTS.md"; then
  written=$(mktemp "$FX_HOME/AGENTS.md.XXXXXX")
  cat "$FX_SYSTEM" > "$written"
  mv "$written" "$FX_HOME/AGENTS.md"
fi
export FX_AUTO_UPGRADE=0

if [ "${args[0]-}" = ask ]; then
  if [ -z "$name" ]; then
    args=(ask --no-save "${args[@]:1}")
  else
    here=$("$FX_BIN" sessions --json --limit 1 < /dev/null | jq '.count')
    if [ "$here" -gt 0 ]; then
      args=(ask --resume last "${args[@]:1}")
    else
      others=$("$FX_BIN" sessions --all --json < /dev/null | jq -r '[.sessions[].workspace_root] | unique | join(" ")')
      if [ -n "$others" ]; then
        echo "fx: the session $name is in $others, not $(pwd -P): run fx there to go on with it, or give this run another name" >&2
        exit 2
      fi
    fi
  fi
fi
exec "$FX_BIN" "${args[@]}"
