# What Max runs in the guest, each a unit of its own in max-jobs.slice,
# which systemd starts, limits, stops and sees end: `maxx units`' run,
# start, list and stop-all, which bin/maxx runs with their arguments as a
# JSON object (maxx.nix, local.json), and the units' own hooks. The
# host asks for them so, and so does anything in the VM. See "Lifetimes
# move to systemd" in docs/rust-rewrite.md.
#
#   maxx units run JSON
#       A call: runs .command as a unit, waits for its end, and prints
#       one line of JSON: how it ended, its output, and what it left for
#       the model to see. Its caller holds this command's input open for
#       as long as it waits: when that ends, the caller is gone, and the
#       unit is stopped.
#   maxx units start JSON
#       A background command: starts the unit, says its name and what
#       becomes of it, and returns. Max is told of its end, unless it was
#       stopped on request.
#   maxx units list JSON       the units that run, and those
#                              /work/.max/systemd keeps
#   maxx units stop-all JSON   stops the first of those, and prints which
#   maxx units agent OPTIONS -- COMMAND...
#                              a background agent's unit, which `maxx
#                              agent start` asks for (max-agent.sh): pi,
#                              which is stopped with SIGUSR2 and given a
#                              while to report
#   maxx units ended UNIT      the unit's ExecStopPost=
#   maxx units notify UNIT     max-notify@UNIT.service's
#   maxx units idle SECONDS    max-trim.service's: succeeds if none runs,
#                              and none has begun or ended in that long
#
# The object: .command, what bash -lc runs; .limit, the seconds it may
# run, 120 for a call and 6 hours for a background command without it;
# .title, what it is, for the list and the notice; .workdir, /work
# without it; .unit, its name, made here without it; and for a call,
# .split, which keeps stderr apart from stdout, .input, which gives the
# command that many bytes of this command's own input, and .shown, how
# many bytes of an output the line carries.
#
# A call's unit has its directory in MAX_CALL. A picture or a video for
# the model is a line of `shown` there, which tools.show and maxx show
# write (shown.js): {"kind": "image", "path": "/work/…"}. The call's line
# carries them, and the host reads the files. What isn't a call has no
# MAX_CALL, and nobody to show anything to.
#
# A unit is a call, a background command or an agent from its start to
# its end; none becomes another. A call whose caller went away, as when
# the turn is killed or max restarts, is stopped, and nobody is told.

jobs=/run/max/jobs
out=/work/.max/out
# What /work/.max/systemd keeps, as `maxx units apply` installed it
# (max-units.sh).
installed=/run/max/units
# What a unit's hook runs: the system's, so that a job one image started
# is ended by the image the guest has switched to since.
self="/run/current-system/sw/bin/maxx units"

usage() {
  echo "maxx units: $1" >&2
  exit 2
}

# A piece of output: its size, and all of it if it fits in $shown;
# otherwise its head and its tail, and the file that has the whole.
piece() {
  local file=$1 dir=$2 bytes half
  bytes=$(stat -c %s "$file" 2> /dev/null || echo 0)
  if [ "$bytes" -le "$shown" ]; then
    if [ "$bytes" -gt 0 ]; then
      jq -Rsc --argjson bytes "$bytes" '{bytes: $bytes, head: ., tail: "", file: null}' < "$file"
    else
      jq -nc '{bytes: 0, head: "", tail: "", file: null}'
    fi
    rm -f "$file"
  else
    half=$((shown / 2))
    head -c "$half" "$file" > "$dir/head"
    tail -c "$half" "$file" > "$dir/tail"
    jq -nc --arg file "$file" --argjson bytes "$bytes" \
      --rawfile head "$dir/head" --rawfile tail "$dir/tail" \
      '{bytes: $bytes, head: $head, tail: $tail, file: $file}'
  fi
}

# How long, as Max is told it.
took() {
  local seconds=$1
  if [ "$seconds" -lt 60 ]; then
    echo "$seconds seconds"
  elif [ "$seconds" -lt 3600 ]; then
    echo "$((seconds / 60)) minutes"
  else
    echo "$((seconds / 3600)) hours $((seconds % 3600 / 60)) minutes"
  fi
}

# A call or a background command, as the JSON object asks for it:
# launch's options, and for a background command what is said of it.
asked() {
  local kind=$1 parsed
  local unit="" title="" workdir="" command="" limit=0 input=0 shown=0 split=""
  if ! parsed=$(jq -r '
      def text(name): .[name] // "" | if type == "string" then . else error("\(name) is text") end;
      def count(name): .[name] // 0
        | if type == "number" and . == floor and . >= 0 then . else error("\(name) is a whole number") end;
      if type == "object" then . else error("the arguments are a JSON object") end
      | @sh "unit=\(text("unit")) title=\(text("title")) workdir=\(text("workdir")) command=\(text("command")) limit=\(count("limit")) input=\(count("input")) shown=\(count("shown")) split=\(if .split == true then "1" else "" end)"
    ' <<< "$2" 2>&1); then
    usage "${parsed#jq: error (at <stdin>:*): }"
  fi
  eval "$parsed"
  [ -n "${command//[[:space:]]/}" ] || usage "there is no command to run"
  # Its output's file in /work is named after it, and outlives it.
  [ -n "$unit" ] || unit=max-job-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  if [ "$limit" = 0 ]; then
    limit=120
    [ "$kind" = call ] || limit=21600
  fi
  [ "$limit" -le 86400 ] || usage "limit is a day at most, 86400 seconds"
  [ "$shown" != 0 ] || shown=16384
  # Its first line, as shell titles a command.
  if [ -z "$title" ]; then
    title=$(sed -n '/[^[:space:]]/{s/^[[:space:]]*//;p;q}' <<< "$command")
    [ "${#title}" -le 60 ] || title=${title:0:60}…
    title="\$ $title"
  fi
  case "$workdir" in
    "") workdir=/work ;;
    /*) ;;
    *) workdir=/work/$workdir ;;
  esac
  local options=(--unit "$unit" --limit "$limit" --title "$title" --workdir "$workdir" --shown "$shown")
  [ -z "$split" ] || options+=(--split)
  [ "$input" = 0 ] || options+=(--input "$input")
  launch "$kind" "${options[@]}" -- bash -lc "$command"
  [ "$kind" = job ] || return 0
  jq -nc --arg unit "$unit" --argjson limit "$limit" --arg most "$(took "$limit")" '{
    unit: $unit, limit: $limit,
    said: "It runs in the background as \($unit), for at most \($most). When it ends, its exit status and output come back to you as [\($unit) 完成]: don\u0027t sleep waiting for it, and don\u0027t keep checking. Its output is written to /work/.max/out/\($unit).txt as it runs: to see how far it is, read the end of that; if it isn\u0027t wanted any more, stop it with systemctl stop \($unit)."
  }'
}

launch() {
  local kind=$1
  shift
  local unit="" limit="" title="" workdir=/work split="" input="" shown=16384
  while [ $# -gt 0 ]; do
    case "$1" in
      --unit) unit=$2 && shift 2 ;;
      --limit) limit=$2 && shift 2 ;;
      --title) title=$2 && shift 2 ;;
      --workdir) workdir=$2 && shift 2 ;;
      --shown) shown=$2 && shift 2 ;;
      --split) split=1 && shift ;;
      --agent) kind=agent && shift ;;
      --input) input=$2 && shift 2 ;;
      --) shift && break ;;
      *) usage "$kind takes no $1" ;;
    esac
  done
  [[ $unit =~ ^max-(job|agent)-[a-z0-9-]+$ ]] || usage "--unit is max-job-… or max-agent-…, not '$unit'"
  [[ $limit =~ ^[0-9]+$ ]] || usage "--limit is in seconds, not '$limit'"
  [[ $input =~ ^[0-9]*$ ]] || usage "--input is in bytes, not '$input'"
  [ $# -gt 0 ] || usage "$kind needs a command after --"
  [ -n "$title" ] || title=$1
  # systemd would fail the unit's hook with its command, and the unit
  # would end with nothing said.
  if [ ! -d "$workdir" ]; then
    if [ "$kind" != call ]; then
      usage "there is no directory $workdir"
    fi
    jq -nc --arg failed "there is no directory $workdir" \
      '{result: "", code: "", status: "", seconds: 0, out: null, err: null, shown: [], failed: $failed}'
    return
  fi
  workdir=$(realpath -- "$workdir")

  local dir=$jobs/$unit
  mkdir -p "$dir" "$out"
  echo "$kind" > "$dir/kind"
  printf '%s\n' "$title" > "$dir/title"
  echo "$limit" > "$dir/limit"
  date +%s > "$dir/started"
  local args=(
    --quiet --collect --unit="$unit" --slice=max-jobs.slice
    --description="$title"
    # The command as it was written: systemd would put the unit's
    # environment in for each ${…} in it, and make each $$ a $, before
    # bash saw it (2026-11-13; a heredoc's quotes don't keep it out).
    --expand-environment=no
    # Not needed by the end: a command that removed its own directory
    # would have the hook fail there, and end with nothing said.
    --property=WorkingDirectory="-$workdir"
    --property=RuntimeMaxSec="$limit"
    --property=StandardOutput="append:$out/$unit.txt"
    --property=ExecStopPost="$self ended $unit"
  )
  if [ "$kind" = agent ]; then
    # pi exits at once on SIGTERM, with nothing reported: its plugin
    # takes SIGUSR2, aborts the run and writes the report, in the time
    # it has before the rest is killed. Its settings are the unit's own.
    args+=(
      --property=KillSignal=SIGUSR2 --property=KillMode=mixed
      --property=TimeoutStopSec=30 --property=RuntimeDirectory="$unit"
    )
  fi
  if [ -n "$split" ]; then
    args+=(--property=StandardError="append:$out/$unit.log")
  fi
  if [ -n "$input" ]; then
    # So many bytes and no more: what follows is the caller's, below.
    head -c "$input" > "$dir/input"
    args+=(--property=StandardInput="file:$dir/input")
  fi

  if [ "$kind" != call ]; then
    if ! systemd-run --no-block "${args[@]}" -- "$@"; then
      rm -rf "$dir"
      exit 1
    fi
    return
  fi

  # What earlier calls left in /work for the model to see, which the host
  # has read long since: a call is over within minutes.
  find /work/.max/shown -mindepth 1 -maxdepth 1 -mmin +60 -exec rm -rf {} + 2> /dev/null || true
  # A call is waited for: at its limit, or stopped, what won't end is
  # killed sooner than systemd's 90 seconds, within the time max waits
  # for the line.
  args+=(--setenv=MAX_CALL="$dir" --property=TimeoutStopSec=15)
  # Held for as long as the call waits: without it, the unit's end is
  # nobody's, and its hook clears up.
  exec 9> "$dir/waiting"
  flock 9
  # It returns once the unit has ended and its hook has run. The unit's
  # own status is in what the hook wrote. The lock stays this shell's
  # alone: it must go when the caller does.
  systemd-run --wait "${args[@]}" -- "$@" < /dev/null > /dev/null 2> "$dir/failed" 9>&- &
  local waiter=$!
  # The caller says nothing more on this command's input, and holds it
  # open for as long as it waits: its end is the caller gone, as when the
  # turn is killed or max goes away. (Named, since a command in the
  # background has /dev/null for its input otherwise.) Only a pipe or a
  # socket is somebody's to hold, as max's channel is and a program's
  # child's input: a command given /dev/null for its input, as one in a
  # unit is, has nobody who could go.
  if [ -p /dev/stdin ] || [ -S /dev/stdin ]; then
    { while read -r -N 4096 _; do :; done; } <&0 > /dev/null 2>&1 9>&- &
  else
    sleep infinity > /dev/null 2>&1 9>&- &
  fi
  local caller=$! first=""
  wait -n -p first "$waiter" "$caller" || true
  if [ "$first" = "$caller" ]; then
    # The call ends with its caller, and leaves nothing. Stopped again
    # until it has ended: it may not have started yet.
    (while :; do
      systemctl stop "$unit.service" 2> /dev/null || true
      sleep 0.5
    done) > /dev/null 2>&1 9>&- &
    local stopper=$!
    wait "$waiter" || true
    kill "$stopper" 2> /dev/null || true
    rm -rf "$dir" "$out/$unit.txt" "$out/$unit.log"
    return
  fi
  kill "$caller" 2> /dev/null || true
  # The directory is this command's to remove from here, whatever becomes
  # of it: a caller that goes now leaves the line with nowhere to go.
  # shellcheck disable=SC2064
  trap "rm -rf '$dir'" EXIT
  local result="" code="" status="" seconds
  if [ -f "$dir/result" ]; then
    read -r result code status < "$dir/result"
  elif [ ! -s "$dir/failed" ]; then
    echo "the unit ended without saying how" > "$dir/failed"
  fi
  seconds=$(($(date +%s) - $(cat "$dir/started")))
  piece "$out/$unit.txt" "$dir" > "$dir/out.json"
  if [ -n "$split" ]; then
    piece "$out/$unit.log" "$dir" > "$dir/err.json"
  else
    echo null > "$dir/err.json"
  fi
  # What it left to show, a line each; one that isn't such a line is
  # nothing to show. The first 32: max shows half as many, and the line
  # has to stay one it reads whole.
  touch "$dir/shown"
  jq -nc --arg result "$result" --arg code "$code" --arg status "$status" \
    --argjson seconds "$seconds" --rawfile failed "$dir/failed" \
    --slurpfile out "$dir/out.json" --slurpfile err "$dir/err.json" \
    --rawfile left "$dir/shown" \
    '{result: $result, code: $code, status: $status, seconds: $seconds,
      out: $out[0], err: $err[0],
      shown: ([$left | split("\n")[] | fromjson?
        | select(type == "object" and (.kind | type) == "string" and (.path | type) == "string")
        | select(.path | length <= 1024)
        | {kind, path}] | .[:32]),
      failed: ($failed | if . == "" then null else . end)}'
  rm -rf "$dir"
}

# Whether systemd is stopping the unit because it was asked to, said in
# the unit's hook: the request is a job of systemd's until the hook has
# run. A unit that ends by itself, or at its limit, has none. How its
# main process ended doesn't say: a server asked to stop exits with 0 or
# 143, and a script may end itself with SIGTERM.
stopping() {
  systemctl list-jobs --no-legend "$1.service" 2> /dev/null \
    | awk '$3 == "stop" { found = 1 } END { exit !found }'
}

ended() {
  local unit=$1 dir=$jobs/$1
  [ -d "$dir" ] || return 0
  local how="${SERVICE_RESULT:-} ${EXIT_CODE:-} ${EXIT_STATUS:-}"
  echo "$how" > "$dir/result.new"
  mv "$dir/result.new" "$dir/result"
  date +%s > "$dir/ended"
  local kind
  kind=$(cat "$dir/kind")
  if [ "$kind" = call ]; then
    # Its caller reads the result. If the caller is gone, as when max went
    # away, the call ends here.
    exec 8> "$dir/waiting"
    if flock -n 8; then
      rm -rf "$dir" "$out/$unit.txt" "$out/$unit.log"
    fi
  elif [ "$kind" = job ] && stopping "$unit"; then
    # Stopped on request: whoever asked knows.
    rm -rf "$dir"
  elif [ "$kind" = agent ] && [ -e "$dir/stopped" ] && [ "${SERVICE_RESULT:-}" != timeout ]; then
    # An agent's plugin says it was told to stop, and not by its limit.
    rm -rf "$dir"
  else
    systemctl start --no-block "max-notify@$unit.service"
  fi
}

notify() {
  local unit=$1 dir=$jobs/$1
  # Told already.
  [ -f "$dir/result" ] || return 0
  local result code status title limit ran head line
  read -r result code status < "$dir/result"
  title=$(cat "$dir/title")
  limit=$(cat "$dir/limit")
  if [ "$(cat "$dir/kind")" = agent ]; then
    agent_notice "$unit" "$result" "$status" "$title" > "$dir/notice.json"
    maxx wake - < "$dir/notice.json" > /dev/null
    rm -rf "$dir"
    return
  fi
  ran=$(took $(($(cat "$dir/ended") - $(cat "$dir/started"))))
  head="[$unit 完成] $title"
  case "$result" in
    success | exit-code)
      line="exit status $status, ran for $ran"
      # A signal systemd takes for a clean end, as SIGTERM is.
      [ "$code" != killed ] || line="ended by SIG$status, after $ran"
      ;;
    timeout)
      head="[$unit 到点了，下面是做到一半的] $title"
      line="not done in $(took "$limit"); it was stopped"
      ;;
    signal | core-dump | oom-kill) line="ended by $result ($status), after $ran" ;;
    *)
      head="[$unit 失败] $title：$result"
      line="it didn't run: $code $status"
      ;;
  esac
  # A wake takes 4,000 characters: the end of the output, and where the
  # whole is.
  local file=$out/$unit.txt bytes
  bytes=$(stat -c %s "$file" 2> /dev/null || echo 0)
  { tail -c 12000 "$file" 2> /dev/null || true; } \
    | jq -Rsc --arg head "$head" --arg line "$line" --arg file "$file" --argjson bytes "$bytes" '
        (if $bytes > 12000 or length > 3000 then "…" + .[-3000:] else . end) as $end
        | {text: ([$head, $line]
            + (if $bytes == 0 then ["(no output)"] else [$end | rtrimstr("\n"), "(the whole output: \($file))"] end)
            | join("\n"))}' > "$dir/notice.json"
  # Fails while max is away: systemd tries again.
  maxx wake - < "$dir/notice.json" > /dev/null
  rm -rf "$dir"
}

# What Max is told of an agent's end: how it ended, its report or the
# beginning of it, where the whole is, and how many of Max's last words
# it never read.
agent_notice() {
  local unit=$1 result=$2 status=$3 title=$4 dir=$jobs/$1
  local report=/work/.max/jobs/$unit.md head failed="" left tail=()
  head="[$unit 完成] $title"
  if [ "$result" = timeout ]; then
    head="[$unit 到点了，下面是做到一半的] $title"
  elif [ -s "$dir/error" ]; then
    failed=1
    head="[$unit 失败] $title：$(head -c 300 "$dir/error")"
  elif [ ! -s "$report" ] && [ "$status" != 0 ]; then
    failed=1
    head="[$unit 失败] $title：the agent exited with status $status: $({ tail -n 1 "$out/$unit.txt" 2> /dev/null || true; } | head -c 300)"
  fi
  if [ -s "$report" ]; then
    tail+=("（全文在 $report）")
  elif [ -z "$failed" ]; then
    # pi's session is there too, as JSONL.
    tail+=("（它没留下报告；做的过程在 /work/.max/jobs 里它的会话记录）")
  fi
  left=$(find "$dir/inbox" -type f ! -name '.*' ! -name wrap-up 2> /dev/null | wc -l)
  if [ "$left" = 1 ]; then
    tail+=("（你最后补充的那条它没收到）")
  elif [ "$left" -gt 1 ]; then
    tail+=("（你最后补充的 $left 条它没收到）")
  fi
  # The report without the heading the plugin gave its file.
  { tail -n +3 "$report" 2> /dev/null || true; } \
    | jq -Rsc --arg head "$head" '$ARGS.positional as $tail
        | (sub("\\s+$"; "")) as $report
        | (if ($report | length) > 2000 then $report[:2000] + "…" else $report end) as $shown
        | {text: ([$head] + (if $shown == "" then [] else [$shown] end) + $tail | join("\n"))}' \
      --args "${tail[@]}"
}

running() {
  systemctl list-units --no-legend --plain --state=active,activating,deactivating \
    'max-job-*.service' 'max-agent-*.service' | awk '{print $1}'
}

# What runs, each with what it is and how long it has run, and after
# them what /work/.max/systemd keeps, each as systemd has it.
list() {
  local units unit name dir now file
  mapfile -t units < <(running)
  now=$(date +%s)
  {
    for unit in "${units[@]}"; do
      name=${unit%.service}
      dir=$jobs/$name
      if [ -f "$dir/started" ]; then
        jq -nc --arg name "$name" --arg kind "$(cat "$dir/kind")" --arg title "$(cat "$dir/title")" \
          --argjson seconds "$((now - $(cat "$dir/started")))" \
          '{name: $name, kind: $kind, title: $title, seconds: $seconds}'
      else
        jq -nc --arg name "$name" '{name: $name, kind: "job"}'
      fi
    done
    for file in "$installed"/*; do
      [ -f "$file" ] || continue
      name=${file##*/}
      jq -nc --arg name "$name" --arg state "$(systemctl is-active "$name" || true)" \
        '{name: $name, kind: "unit", state: $state}'
    done
  } | jq -sc '{units: .}'
}

# Whether the guest has had nothing of Max's to do for so long. A unit's
# start makes its directory in $jobs, its end writes there, and the
# directory goes once the end is told: the newest of them is when.
idle() {
  local seconds=$1
  [[ $seconds =~ ^[0-9]+$ ]] || usage "idle takes seconds, not '$seconds'"
  [ -z "$(running)" ] || return 1
  [ -z "$(find "$jobs" -maxdepth 1 -newermt "@$(($(date +%s) - seconds))" 2> /dev/null)" ]
}

stop_all() {
  local units
  mapfile -t units < <(running)
  if [ "${#units[@]}" -gt 0 ]; then
    systemctl stop "${units[@]}" || true
  fi
  jq -nc '{stopped: $ARGS.positional}' --args "${units[@]%.service}"
}

case "${1:-}" in
  run) asked call "${2:-}" ;;
  start) asked job "${2:-}" ;;
  list) list ;;
  stop-all) stop_all ;;
  agent) shift && launch job --agent "$@" ;;
  ended) ended "${2:?maxx units ended needs a unit}" ;;
  notify) notify "${2:?maxx units notify needs a unit}" ;;
  idle) idle "${2:?maxx units idle needs seconds}" ;;
  *) usage "run, start, list or stop-all, not '${1:-}'" ;;
esac
