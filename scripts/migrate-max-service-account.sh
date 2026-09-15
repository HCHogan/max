#!/usr/bin/env bash
# Preserve the existing service UID/GID before creating the fleet login account.
set -euo pipefail
umask 077
mode=${1:---check}
[[ "$mode" == --check || "$mode" == --migrate ]] || { echo 'usage: max-migrate-service-account [--check|--migrate]' >&2; exit 64; }
[[ $EUID == 0 ]] || { echo 'run as root' >&2; exit 77; }
if getent passwd max-service >/dev/null; then
  [[ $(getent passwd max-service | cut -d: -f6) == /var/lib/max/app ]]

else
  [[ $(getent passwd max | cut -d: -f6) == /var/lib/max/app ]]
fi
[[ "$mode" == --migrate ]] || { echo 'Ready: stop max-stack.target, migrate, then activate the new NixOS configuration.'; exit 0; }
exec 9>/run/lock/max-service-account.lock
flock -n 9
for unit in max.service max-runtime.service max-runtime.socket; do
  state=$(systemctl show "$unit" -p ActiveState --value)
  [[ $state == inactive || $state == failed ]] || { echo "$unit must be stopped" >&2; exit 1; }
done
old_user=max
if getent passwd max-service >/dev/null; then old_user=max-service; fi
old_uid=$(id -u "$old_user")
old_gid=$(id -g "$old_user")
! pgrep -u "$old_uid" >/dev/null || { echo 'Old service UID still has processes' >&2; exit 1; }
backup=/var/lib/max/backups/service-account
install -d -m700 "$backup"
for file in /etc/passwd /etc/group /etc/shadow /etc/gshadow /var/lib/nixos/uid-map /var/lib/nixos/gid-map; do
  if [[ -f $file && ! -e "$backup/${file##*/}" ]]; then cp -p "$file" "$backup/${file##*/}"; fi
done
if [[ $old_user == max ]]; then usermod --login max-service max; fi
if getent group max >/dev/null && [[ $(getent group max | cut -d: -f3) == "$old_gid" ]]; then
  groupmod --new-name max-service max
fi
for kind in uid gid; do
  file=/var/lib/nixos/$kind-map
  if [[ -f $file ]]; then
    value=$old_uid
    [[ $kind != gid ]] || value=$old_gid
    jq --compact-output --argjson value "$value" '(if .max == $value then del(.max) else . end) | .["max-service"] = $value' "$file" > "$file.max-service.tmp"
    chmod --reference="$file" "$file.max-service.tmp"
    mv "$file.max-service.tmp" "$file"
  fi
done
[[ $(id -u max-service) == "$old_uid" && $(id -g max-service) == "$old_gid" ]]
echo 'Service UID/GID preserved. Activate the new configuration before restarting Max.'
