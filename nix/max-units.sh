# max-units: makes the units in /work/.max/systemd the ones the guest
# runs, so that what Max keeps running outlives the VM. max-units.service
# runs it at every boot, and Max runs it after changing the directory. See
# "Resident programs" in docs/rust-rewrite.md.
#
# New and changed files are copied to /run/systemd/system, services with a
# drop-in that puts them in max-units.slice; those with an [Install]
# section are enabled for this boot and started, and changed ones that
# were running are restarted. Files that are gone are stopped and removed.
# A name a system unit has is skipped: the system's would win anyway. So
# is a link: max, when it starts, boots the VMs with units to keep, and
# counts only files, since on the host a link could point anywhere. Last,
# the VM service hears how many there are: it keeps the VM on while there
# are any, if it can, and says whether it does.

dir=/work/.max/systemd
run=/run/systemd/system
# What was installed, as it was: tells changed files and gone ones.
installed=/run/max/units

mkdir -p "$dir" "$installed"
exec 9> /run/max/units.lock
flock 9

wanted=()
declare -A keep=()
for file in "$dir"/*; do
  name=${file##*/}
  case "$name" in
    *.service | *.socket | *.timer | *.path | *.target) ;;
    *) continue ;;
  esac
  if [ -L "$file" ]; then
    echo "$name：是链接，没装，把文件本身放进来"
    continue
  fi
  [ -f "$file" ] || continue
  if [ -e "/etc/systemd/system/$name" ]; then
    echo "$name：和系统的 unit 重名，没装，换个名字"
    continue
  fi
  wanted+=("$name")
  keep[$name]=1
done

for file in "$installed"/*; do
  [ -f "$file" ] || continue
  name=${file##*/}
  [ -n "${keep[$name]:-}" ] && continue
  systemctl disable --runtime --now --no-block --quiet "$name" 2> /dev/null || true
  rm -rf "${run:?}/$name" "${run:?}/$name.d" "${installed:?}/$name"
  echo "$name：停了，去掉了"
done

changed=()
for name in "${wanted[@]}"; do
  cmp -s "$dir/$name" "$installed/$name" && continue
  # The old [Install] goes before the new one is read.
  if [ -f "$installed/$name" ]; then
    systemctl disable --runtime --quiet "$name" 2> /dev/null || true
  fi
  install -m 0644 "$dir/$name" "$run/$name"
  if [[ $name == *.service ]]; then
    mkdir -p "$run/$name.d"
    printf '[Service]\nSlice=max-units.slice\n' > "$run/$name.d/max.conf"
  fi
  cp "$dir/$name" "$installed/$name"
  changed+=("$name")
done

systemctl daemon-reload
for name in "${changed[@]}"; do
  systemctl try-restart --no-block "$name" 2> /dev/null || true
done
failed=0
for name in "${wanted[@]}"; do
  if grep -q '^\[Install\]' "$dir/$name"; then
    systemctl enable --runtime --now --no-block --quiet "$name" || failed=1
  fi
done

# The starts are queued; a few seconds for them to settle before the
# report.
for _ in $(seq 50); do
  busy=0
  for name in "${wanted[@]}"; do
    case "$(systemctl is-active "$name" || true)" in
      activating | deactivating | reloading | refreshing) busy=1 ;;
    esac
  done
  [ "$busy" = 0 ] && break
  sleep 0.1
done

if [ ${#wanted[@]} -eq 0 ]; then
  echo "$dir 里没有 unit"
fi
for name in "${wanted[@]}"; do
  state=$(systemctl is-active "$name" || true)
  echo "$name：$state"
  if [ "$state" = failed ]; then
    failed=1
    journalctl -u "$name" -n 10 --no-pager -o cat || true
  fi
done
report=$(jq -cn --argjson units "${#wanted[@]}" '{units: $units}')
if answer=$(curl -sf --max-time 15 -H 'content-type: application/json' -d "$report" http://127.0.0.1:7777/units 2> /dev/null); then
  jq -r '.said // empty' <<< "$answer"
fi
exit "$failed"
