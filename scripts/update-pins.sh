# update-pins: moves max's pins on top of HEAD, a commit each, and keeps
# the ones the gate passes. Run at the repository's root, in a clean tree:
#
#   nix run .#update-pins              moves them, checked by GATE
#   GATE=true nix run .#update-pins    moves them unchecked
#
# The pins are Cargo.lock, within Cargo.toml's ranges and to releases out
# for DAYS days, and the flake inputs named below. The gate is what CI runs
# on a push. When it fails with them all, each is tried alone on the ones
# kept, and one that fails is dropped: REPORT gets why, as Markdown, and is
# empty when everything that moved was kept. The nightly workflow
# (.github/workflows/pins.yml) runs this, pushes, and keeps an issue of
# what REPORT says. Why: docs/decisions/pins-move-nightly.md.

export LC_ALL=C
days=${DAYS:-7}
gate=${GATE:-nix flake check --impure -L}
report=${REPORT:-/dev/null}
inputs=(crane rust-overlay microvm llm-agents advisory-db)

[[ -f Cargo.lock && -f flake.lock ]] || {
  echo "run at the repository's root" >&2
  exit 2
}
[[ -z $(git status --porcelain) ]] || {
  echo "the tree has changes" >&2
  exit 2
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/index"
: >"$tmp/report"

say() { printf '%s\n' "$*" >&2; }

# --- Cargo.lock ------------------------------------------------------------

# A release that came out after this is too new to take.
cutoff=$(jq -nr --argjson days "$days" 'now - $days * 86400 | todate')

# "name version" of a lock's packages from crates.io.
locked() {
  awk -F'"' '
    /^name = / { name = $2 }
    /^version = / { version = $2 }
    /^source = "registry\+/ { print name, version }' "$1" | sort
}

# Fetches the index's lines for a crate, once.
index() {
  local lower path
  [[ -s $tmp/index/$1 ]] && return 0
  lower=$(tr '[:upper:]' '[:lower:]' <<<"$1")
  case ${#lower} in
    1 | 2) path=${#lower}/$lower ;;
    3) path=3/${lower:0:1}/$lower ;;
    *) path=${lower:0:2}/${lower:2:2}/$lower ;;
  esac
  curl -fsS --retry 3 "https://index.crates.io/$path" >"$tmp/index/$1"
}

# When a version came out: nothing for one older than the index's times.
out_since() {
  jq -r --arg v "$2" 'select(.vers == $v) | .pubtime // empty' "$tmp/index/$1" | tail -n 1
}

# above A B: A is the later version.
above() {
  [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1) == "$1" ]]
}

# to NAME FROM TO: moves one package of the lock, if its dependents allow.
to() {
  cargo update --quiet --package "$1@$2" --precise "$3" 2>/dev/null
}

# Sets `did` if it committed.
move_cargo() {
  local before=$tmp/before.lock fresh waiting stepped tries line name new old since candidate
  cp Cargo.lock "$before"
  cargo update --quiet
  # A release too new steps back to the newest one old enough above what
  # was locked, or to what was locked. One a dependent's new release needs
  # waits a round, for the dependent to step back first.
  while :; do
    mapfile -t fresh < <(comm -13 <(locked "$before") <(locked Cargo.lock))
    waiting=()
    stepped=
    for line in "${fresh[@]}"; do
      read -r name new <<<"$line"
      index "$name"
      since=$(out_since "$name" "$new")
      [[ -n $since && $since > $cutoff ]] || continue
      old=$(comm -23 <(locked "$before") <(locked Cargo.lock) |
        awk -v name="$name" '$1 == name { print $2 }' | sort -V | tail -n 1)
      tries=0
      while read -r candidate; do
        above "$new" "$candidate" || continue
        [[ -z $old ]] || above "$candidate" "$old" || continue
        if to "$name" "$new" "$candidate"; then
          stepped=1
          continue 2
        fi
        ((++tries < 8)) || break
      done < <(jq -r --arg cutoff "$cutoff" '
        select(.yanked | not) | select((.pubtime // "") <= $cutoff) | .vers' "$tmp/index/$name" | tac)
      if [[ -n $old ]] && to "$name" "$new" "$old"; then
        stepped=1
      else
        waiting+=("$name $new, out since ${since%T*}")
      fi
    done
    ((${#waiting[@]})) || break
    if [[ -z $stepped ]]; then
      say "Cargo.lock stays: too new, and not to be held back: ${waiting[*]}"
      {
        printf '## Cargo.lock\n\nIt stays as it is: these came out less than %s days ago, ' "$days"
        printf 'and what needs them will not take an older one:\n\n'
        printf -- '- %s\n' "${waiting[@]}"
        printf '\n'
      } >>"$tmp/report"
      cp "$before" Cargo.lock
      return 0
    fi
  done
  mapfile -t fresh < <(comm -13 <(locked "$before") <(locked Cargo.lock))
  ((${#fresh[@]})) || return 0
  git commit -q -m "Cargo.lock moves ${#fresh[@]} crates" -m "$(printf '%s\n' "${fresh[@]}")" -- Cargo.lock
  did=1
}

# --- The flake's inputs ----------------------------------------------------

# "2026-11-20 1a2b3c4", what the lock pins an input to.
pinned() {
  jq -r --arg input "$1" '
    .nodes[.nodes.root.inputs[$input]].locked
    | ((.lastModified // 0) | strftime("%Y-%m-%d")) + " " + (.rev // "?")[0:7]' flake.lock
}

# Sets `did` if it committed.
move_input() {
  local was
  was=$(pinned "$1")
  nix flake update "$1"
  git diff --quiet -- flake.lock && return 0
  git commit -q -m "flake.lock: $1 moves from $was to $(pinned "$1")" -- flake.lock
  did=1
}

# --- The gate --------------------------------------------------------------

move() {
  did=
  if [[ $1 == Cargo.lock ]]; then move_cargo; else move_input "$1"; fi
}

check() {
  say "the gate, on $1"
  bash -c "$gate" 2>&1 | tee "$tmp/gate.log" >&2
}

drop() {
  say "$1 doesn't pass, and stays"
  {
    printf '## %s\n\nIt stays as it is: `%s` fails with its newer one.\n\n```\n' "$1" "$gate"
    tail -n 60 "$tmp/gate.log"
    printf '```\n\n'
  } >>"$tmp/report"
}

base=$(git rev-parse HEAD)
moved=()
for pin in Cargo.lock "${inputs[@]}"; do
  move "$pin"
  if [[ -n $did ]]; then
    moved+=("$pin")
    say "$(git log -1 --format=%s)"
  fi
done

if ((${#moved[@]} == 1)); then
  if ! check "${moved[0]}"; then
    drop "${moved[0]}"
    git reset -q --hard "$base"
  fi
elif ((${#moved[@]} > 1)); then
  if ! check "them all"; then
    git reset -q --hard "$base"
    for pin in "${moved[@]}"; do
      move "$pin"
      [[ -n $did ]] || continue
      if ! check "$pin"; then
        drop "$pin"
        git reset -q --hard HEAD~1
      fi
    done
  fi
fi

say "kept: $(git rev-list --count "$base..HEAD") of ${#moved[@]} that moved"
cp "$tmp/report" "$report"
