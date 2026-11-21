# What Max runs in the guest, each a unit of its own in max-jobs.slice,
# which systemd starts, limits, stops and sees end: `maxx jobs`, which
# bin/maxx runs (maxx.nix). max asks for a call and for a background
# command so, each with its arguments as a JSON object, and the units'
# own hooks are here. They are max's and the units' own, and no tools.
# See "Background commands" in docs/design/jobs.md.
#
#   maxx jobs run JSON
#       A call: runs .command as a unit, max-call-…, waits for its end,
#       and prints one line of JSON: how it ended, its output, and what
#       it left for the model to see. Its caller holds this command's
#       input open for as long as it waits: when that ends, the caller is
#       gone, and the unit is stopped.
#   maxx jobs start JSON
#       A background command: starts the unit, max-job-…, prints its
#       name and the file its output is written to, and returns. Max is
#       told of its end, unless it was stopped on request.
#   maxx jobs ended UNIT       the unit's ExecStopPost=
#   maxx jobs notify UNIT      max-notify@UNIT.service's
#   maxx jobs idle SECONDS     max-trim.service's: succeeds if none runs,
#                              and none has begun or ended in that long
#
# The object: .command, what bash -lc runs; .limit, the seconds it may
# run; .title, what it is, in systemd's list and in the notice, the
# command's first line without it; .workdir, /work without it, and under
# /work if it isn't absolute; and for a call, .shown, how many bytes of
# an output the line carries, .split, which keeps stderr apart from
# stdout, and .input, which gives the command that many bytes of this
# command's own input.
#
# A unit is a call or a background command from its start to its end,
# which its name says, and neither becomes the other. What it is and when
# it began systemd keeps, its title as its description; nothing here is
# written of them. A call whose caller went away, as when the turn is
# killed or max restarts, is stopped, and nobody is told.
#
# A call's unit has a directory while it runs, in MAX_CALL. A picture or
# a video for the model is a line of `shown` there, which tools.show and
# maxx show write (shown.js): {"kind": "image", "path": "/work/…"}. The
# call's line carries them, and the host reads the files. What isn't a
# call has no MAX_CALL, and nobody to show anything to.

# A call's directory while it runs, max-call-…, and what Max is still to
# be told of a background command that ended, max-job-….json.
jobs=/run/max/jobs
out=/work/.max/out
# What a unit's hook runs.
self="/run/current-system/sw/bin/maxx jobs"

usage() {
  echo "maxx jobs: $1" >&2
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

# A call or a background command, a `call` or a `job`, as the JSON
# object asks for it.
launch() {
  local kind=$1 parsed
  local command="" title="" workdir="" limit=0 shown=0 input=0 split=""
  # A title is the command's first line, as a shell shows a command:
  # enough of it to tell runs of one program apart by their arguments.
  if ! parsed=$(jq -r '
      def text(name): .[name] // "" | if type == "string" then . else error("\(name) is text") end;
      def count(name): .[name] // 0
        | if type == "number" and . == floor and . >= 0 then . else error("\(name) is a whole number") end;
      if type == "object" then . else error("the arguments are a JSON object") end
      | (text("command") | sub("^\\s+"; "") | split("\n")[0] // "") as $line
      | (text("title") | if . != "" then . else
          "$ " + $line[:200] + (if ($line | length) > 200 then "…" else "" end)
        end) as $title
      | @sh "command=\(text("command")) title=\($title) workdir=\(text("workdir")) limit=\(count("limit")) shown=\(count("shown")) input=\(count("input")) split=\(if .split == true then "1" else "" end)"
    ' <<< "$2" 2>&1); then
    usage "${parsed#jq: error (at <stdin>:*): }"
  fi
  eval "$parsed"
  [ -n "${command//[[:space:]]/}" ] || usage "there is no command to run"
  [ "$limit" != 0 ] || usage "there is no limit, the seconds it may run"
  [ "$kind" != call ] || [ "$shown" != 0 ] || usage "there is no shown, the bytes of an output a call's line carries"
  case "$workdir" in
    "") workdir=/work ;;
    /*) ;;
    *) workdir=/work/$workdir ;;
  esac
  # Its output's file in /work is named after it, and outlives it.
  local unit
  unit=max-$kind-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  # systemd would fail the unit's hook with its command, and the unit
  # would end with nothing said.
  if [ ! -d "$workdir" ]; then
    if [ "$kind" != call ]; then
      usage "there is no directory $workdir"
    fi
    jq -nc --arg failed "there is no directory $workdir" \
      '{result: "", code: "", status: "", out: null, err: null, shown: [], failed: $failed}'
    return
  fi
  workdir=$(realpath -- "$workdir")
  mkdir -p "$jobs" "$out"
  local args=(
    --quiet --collect --unit="$unit" --slice=max-jobs.slice
    --description="$title"
    # The command as it was written: systemd would put the unit's
    # environment in for each ${…} in it, and make each $$ a $, before
    # bash saw it (a heredoc's quotes don't keep it out).
    --expand-environment=no
    # Not needed by the end: a command that removed its own directory
    # would have the hook fail there, and end with nothing said.
    --property=WorkingDirectory="-$workdir"
    --property=RuntimeMaxSec="$limit"
    --property=StandardOutput="append:$out/$unit.txt"
    --property=ExecStopPost="$self ended $unit"
  )

  if [ "$kind" != call ]; then
    # Something of Max's has begun: see idle.
    touch "$jobs"
    systemd-run --no-block "${args[@]}" -- bash -lc "$command"
    jq -nc --arg unit "$unit" --arg out "$out/$unit.txt" '{unit: $unit, out: $out}'
    return
  fi

  local dir=$jobs/$unit
  mkdir "$dir"
  # What earlier calls left in /work for the model to see, which the host
  # has read long since: a call is over within minutes.
  find /work/.max/shown -mindepth 1 -maxdepth 1 -mmin +60 -exec rm -rf {} + 2> /dev/null || true
  # A call is waited for: at its limit, or stopped, what won't end is
  # killed sooner than systemd's 90 seconds, within the time max waits
  # for the line.
  args+=(--setenv=MAX_CALL="$dir" --property=TimeoutStopSec=15)
  if [ -n "$split" ]; then
    args+=(--property=StandardError="append:$out/$unit.log")
  fi
  if [ "$input" != 0 ]; then
    # So many bytes and no more: what follows is the caller's, below.
    head -c "$input" > "$dir/input"
    args+=(--property=StandardInput="file:$dir/input")
  fi
  # Held for as long as the call waits: without it, the unit's end is
  # nobody's, and its hook clears up. This shell's alone: it must go when
  # the caller does.
  exec 9> "$dir/waiting"
  flock 9
  # The caller says nothing more on this command's input, and holds it
  # open for as long as it waits: its end is the caller gone, as when the
  # turn is killed or max goes away. The call then ends with its caller:
  # the unit is stopped, again for as long as the call's directory is
  # there, since it may not have started yet. (The input is named, since
  # a command in the background has /dev/null for it otherwise.) Only a
  # pipe or a socket is somebody's to hold, as max's channel is: a
  # command given /dev/null for its input has nobody who could go.
  local caller=""
  if [ -p /dev/stdin ] || [ -S /dev/stdin ]; then
    {
      while read -r -N 4096 _; do :; done
      : > "$dir/gone" || exit 0
      while [ -d "$dir" ]; do
        systemctl stop "$unit.service" || true
        sleep 0.5
      done
    } <&0 > /dev/null 2>&1 9>&- &
    caller=$!
  fi
  # It returns once the unit has ended and its hook has run. The unit's
  # own status is in what the hook wrote.
  systemd-run --wait "${args[@]}" -- bash -lc "$command" < /dev/null > /dev/null 2> "$dir/failed" 9>&- || true
  [ -z "$caller" ] || kill "$caller" 2> /dev/null || true
  if [ -e "$dir/gone" ]; then
    # Its caller is gone: it leaves nothing, and says nothing.
    rm -rf "$dir" "$out/$unit.txt" "$out/$unit.log"
    return
  fi
  # The directory is this command's to remove from here, whatever becomes
  # of it: a caller that goes now leaves the line with nowhere to go.
  # shellcheck disable=SC2064
  trap "rm -rf '$dir'" EXIT
  local result="" code="" status=""
  if [ -f "$dir/result" ]; then
    read -r result code status < "$dir/result"
  elif [ ! -s "$dir/failed" ]; then
    echo "the unit ended without saying how" > "$dir/failed"
  fi
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
    --rawfile failed "$dir/failed" \
    --slurpfile out "$dir/out.json" --slurpfile err "$dir/err.json" \
    --rawfile left "$dir/shown" \
    '{result: $result, code: $code, status: $status,
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

# What Max is told of a background command that ended so, as a wake's
# arguments: its title, how long it ran and the most it might have, as
# systemd has them, the end of its output, and where the whole is.
notice() {
  local unit=$1 result=$2 code=$3 status=$4
  local title="" entered=0 most="" key value
  while IFS="=" read -r key value; do
    case "$key" in
      Description) title=$value ;;
      ActiveEnterTimestampMonotonic) entered=$value ;;
      RuntimeMaxUSec) most=$value ;;
    esac
  done < <(systemctl show -p Description,ActiveEnterTimestampMonotonic,RuntimeMaxUSec "$unit.service")
  local now ran head line
  now=$(cut -d. -f1 /proc/uptime)
  ran=$(took $((now - entered / 1000000)))
  head="[$unit 完成] $title"
  case "$result" in
    success | exit-code)
      line="exit status $status, ran for $ran"
      # A signal systemd takes for a clean end, as SIGTERM is.
      [ "$code" != killed ] || line="ended by SIG$status, after $ran"
      ;;
    timeout)
      head="[$unit 到点了，下面是做到一半的] $title"
      line="not done in $most; it was stopped"
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
            | join("\n"))}'
}

ended() {
  local unit=$1
  case "$unit" in
    max-call-*)
      local dir=$jobs/$unit
      [ -d "$dir" ] || return 0
      echo "${SERVICE_RESULT:-} ${EXIT_CODE:-} ${EXIT_STATUS:-}" > "$dir/result.new"
      mv "$dir/result.new" "$dir/result"
      # Its caller reads the result. If the caller is gone, as when max
      # went away, the call ends here.
      exec 8> "$dir/waiting"
      if flock -n 8; then
        rm -rf "$dir" "$out/$unit.txt" "$out/$unit.log"
      fi
      ;;
    max-job-*)
      # Something of Max's has ended: see idle.
      mkdir -p "$jobs"
      touch "$jobs"
      # Stopped on request: whoever asked knows.
      ! stopping "$unit" || return 0
      notice "$unit" "${SERVICE_RESULT:-}" "${EXIT_CODE:-}" "${EXIT_STATUS:-}" > "$jobs/$unit.json.new"
      mv "$jobs/$unit.json.new" "$jobs/$unit.json"
      systemctl start --no-block "max-notify@$unit.service"
      ;;
  esac
}

notify() {
  local file=$jobs/$1.json
  # Told already.
  [ -f "$file" ] || return 0
  # Fails while max is away: systemd tries again.
  maxx wake - < "$file" > /dev/null
  rm -f "$file"
}

# Whether the guest has had nothing of Max's to do for so long: none
# runs, and none has begun or ended since. A call makes its directory in
# $jobs and takes it away, and a background command's start and end
# touch $jobs: when it last changed is when.
idle() {
  local seconds=$1
  [[ $seconds =~ ^[0-9]+$ ]] || usage "idle takes seconds, not '$seconds'"
  [ -z "$(systemctl list-units --no-legend --plain --state=active,activating,deactivating \
    'max-call-*.service' 'max-job-*.service')" ] || return 1
  [ -z "$(find "$jobs" -maxdepth 1 -newermt "@$(($(date +%s) - seconds))" 2> /dev/null)" ]
}

case "${1:-}" in
  run) launch call "${2:-}" ;;
  start) launch job "${2:-}" ;;
  ended) ended "${2:?maxx jobs ended needs a unit}" ;;
  notify) notify "${2:?maxx jobs notify needs a unit}" ;;
  idle) idle "${2:?maxx jobs idle needs seconds}" ;;
  *) usage "run, start, ended, notify or idle, not '${1:-}'" ;;
esac
