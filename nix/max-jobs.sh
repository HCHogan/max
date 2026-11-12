# max-jobs: what Max runs in the guest, each a unit of its own in
# max-jobs.slice, which systemd starts, limits, stops and sees end. The
# host asks for them with this, and so do the units' own hooks. See
# "Lifetimes move to systemd" in docs/rust-rewrite.md.
#
#   max-jobs run OPTIONS -- COMMAND...
#       A call: runs COMMAND as a unit, waits for its end, and prints one
#       line of JSON: how it ended, and its output.
#   max-jobs start OPTIONS -- COMMAND...
#       A background command: starts the unit and returns. Max is told of
#       its end, unless it was stopped on request.
#   max-jobs ended UNIT      the unit's ExecStopPost=
#   max-jobs notify UNIT     max-notify@UNIT.service's
#   max-jobs list [--count]  the units that run, or how many
#   max-jobs stop-all        stops them, and prints which
#
# OPTIONS: --unit NAME and --limit SECONDS, which a unit must have;
# --title TEXT, what it is, for the list and the notice; --workdir DIR,
# /work without it; --setenv NAME=VALUE, any number; and for a call,
# --split, which keeps stderr apart from stdout, --input, which gives
# COMMAND this command's own input, and --shown BYTES, how much of an
# output the line carries.
#
# A unit is a call or a background command from its start to its end;
# neither becomes the other. A call whose caller went away ends by itself
# within its limit, and nobody is told.

jobs=/run/max/jobs
out=/work/.max/out
# The path a unit's hook runs: the system's, so that a job one image
# started is ended by the image the guest has switched to since.
self=/run/current-system/sw/bin/max-jobs

usage() {
  echo "max-jobs: $1" >&2
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

launch() {
  local kind=$1
  shift
  local unit="" limit="" title="" workdir=/work split="" input="" shown=16384
  local setenv=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --unit) unit=$2 && shift 2 ;;
      --limit) limit=$2 && shift 2 ;;
      --title) title=$2 && shift 2 ;;
      --workdir) workdir=$2 && shift 2 ;;
      --setenv) setenv+=("--setenv=$2") && shift 2 ;;
      --shown) shown=$2 && shift 2 ;;
      --split) split=1 && shift ;;
      --input) input=1 && shift ;;
      --) shift && break ;;
      *) usage "$kind takes no $1" ;;
    esac
  done
  [[ $unit =~ ^max-job-[a-z0-9-]+$ ]] || usage "--unit is max-job-…, not '$unit'"
  [[ $limit =~ ^[0-9]+$ ]] || usage "--limit is in seconds, not '$limit'"
  [ $# -gt 0 ] || usage "$kind needs a command after --"
  [ -n "$title" ] || title=$1
  # systemd would fail the unit's hook with its command, and the unit
  # would end with nothing said.
  if [ ! -d "$workdir" ]; then
    if [ "$kind" = job ]; then
      usage "there is no directory $workdir"
    fi
    jq -nc --arg failed "there is no directory $workdir" \
      '{result: "", code: "", status: "", seconds: 0, out: null, err: null, failed: $failed}'
    return
  fi

  local dir=$jobs/$unit
  mkdir -p "$dir" "$out"
  echo "$kind" > "$dir/kind"
  printf '%s\n' "$title" > "$dir/title"
  echo "$limit" > "$dir/limit"
  date +%s > "$dir/started"
  local args=(
    --quiet --collect --unit="$unit" --slice=max-jobs.slice
    --description="$title"
    --working-directory="$workdir"
    --property=RuntimeMaxSec="$limit"
    --property=StandardOutput="append:$out/$unit.txt"
    --property=ExecStopPost="$self ended $unit"
    "${setenv[@]}"
  )
  if [ -n "$split" ]; then
    args+=(--property=StandardError="append:$out/$unit.log")
  fi
  if [ -n "$input" ]; then
    cat > "$dir/input"
    args+=(--property=StandardInput="file:$dir/input")
  fi

  if [ "$kind" = job ]; then
    if ! systemd-run --no-block "${args[@]}" -- "$@"; then
      rm -rf "$dir"
      exit 1
    fi
    return
  fi

  # Held for as long as the call waits: without it, the unit's end is
  # nobody's, and its hook clears up.
  exec 9> "$dir/waiting"
  flock 9
  # It returns once the unit has ended and its hook has run. The unit's
  # own status is in what the hook wrote. The lock stays this shell's
  # alone: it must go when the caller does.
  systemd-run --wait "${args[@]}" -- "$@" > /dev/null 2> "$dir/failed" 9>&- || true
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
  jq -nc --arg result "$result" --arg code "$code" --arg status "$status" \
    --argjson seconds "$seconds" --rawfile failed "$dir/failed" \
    --slurpfile out "$dir/out.json" --slurpfile err "$dir/err.json" \
    '{result: $result, code: $code, status: $status, seconds: $seconds,
      out: $out[0], err: $err[0], failed: ($failed | if . == "" then null else . end)}'
  rm -rf "$dir"
}

ended() {
  local unit=$1 dir=$jobs/$1
  [ -d "$dir" ] || return 0
  local how="${SERVICE_RESULT:-} ${EXIT_CODE:-} ${EXIT_STATUS:-}"
  echo "$how" > "$dir/result.new"
  mv "$dir/result.new" "$dir/result"
  date +%s > "$dir/ended"
  if [ "$(cat "$dir/kind")" = call ]; then
    # Its caller reads the result. If the caller is gone, as when max went
    # away, the call ends here.
    exec 8> "$dir/waiting"
    if flock -n 8; then
      rm -rf "$dir" "$out/$unit.txt" "$out/$unit.log"
    fi
  elif [ "$how" = "success killed TERM" ]; then
    # Stopped on request: whoever asked knows.
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
  ran=$(took $(($(cat "$dir/ended") - $(cat "$dir/started"))))
  head="[$unit 完成] $title"
  case "$result" in
    success | exit-code) line="exit status $status, ran for $ran" ;;
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

running() {
  systemctl list-units --no-legend --plain --state=active,activating,deactivating \
    'max-job-*.service' 'max-agent@*.service' | awk '{print $1}'
}

list() {
  local units unit name dir now
  mapfile -t units < <(running)
  if [ "${1:-}" = --count ]; then
    echo "${#units[@]}"
    return
  fi
  now=$(date +%s)
  for unit in "${units[@]}"; do
    name=${unit%.service}
    dir=$jobs/$name
    if [ -f "$dir/started" ]; then
      echo "$name · $(took $((now - $(cat "$dir/started")))) · $(cat "$dir/kind") · $(cat "$dir/title")"
    else
      echo "$name"
    fi
  done
}

stop_all() {
  local units
  mapfile -t units < <(running)
  [ "${#units[@]}" -gt 0 ] || return 0
  systemctl stop "${units[@]}" || true
  printf '%s\n' "${units[@]%.service}"
}

case "${1:-}" in
  run) shift && launch call "$@" ;;
  start) shift && launch job "$@" ;;
  ended) ended "${2:?max-jobs ended needs a unit}" ;;
  notify) notify "${2:?max-jobs notify needs a unit}" ;;
  list) list "${2:-}" ;;
  stop-all) stop_all ;;
  *) usage "run, start, ended, notify, list or stop-all, not '${1:-}'" ;;
esac
