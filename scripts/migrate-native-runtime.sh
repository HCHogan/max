#!/usr/bin/env bash
# Offline, copy-first migration. The legacy Docker volumes remain rollback data.
set -euo pipefail
mode=${1:---check}
[[ "$mode" == --check || "$mode" == --copy ]] || { echo 'usage: migrate-native-runtime.sh [--check|--copy]' >&2; exit 64; }
[[ $EUID == 0 ]] || { echo 'run as root on the Max host' >&2; exit 77; }
state=${MAX_RUNTIME_STATE_DIRECTORY:-/var/lib/max-runtime}
for command in docker max-runtime jq rsync systemctl; do command -v "$command" >/dev/null; done
legacy=$(docker info --format '{{.DockerRootDir}}')/volumes
volumes=$(docker volume ls --format '{{.Name}}' --filter 'name=^max-sb-')
for volume in $volumes; do
  max-runtime --validate-volume "$volume"
  mountpoint=$(docker volume inspect "$volume" | jq -er 'if length == 1 and .[0].Driver == "local" and ((.[0].Options // {}) | length == 0) then .[0].Mountpoint else error("unsupported Docker work volume") end')
  [[ "$mountpoint" == "$legacy/$volume/_data" && -d "$mountpoint" && ! -L "$mountpoint" ]]
  source=$mountpoint
  if [[ -d "$mountpoint/.max-work" && ! -L "$mountpoint/.max-work" ]]; then source=$mountpoint/.max-work; fi
  printf '%s -> %s/volumes/%s/work\n' "$source" "$state" "$volume"
done
if [[ "$mode" == --check ]]; then
  echo 'Check complete. Copy requires Max, native runtime, and all Max Docker instances to be stopped.'
  exit 0
fi
# Check positive inactive state, rather than interpreting a systemctl error as
# permission to copy live data. This script never stops unrelated workloads.
for unit in max.service max-runtime.service max-runtime.socket max-napcat.service docker-napcat.service; do
  active=$(systemctl show "$unit" --property=ActiveState --value)
  [[ "$active" == inactive || "$active" == failed ]] || { echo "$unit is not stopped" >&2; exit 1; }
done
native=$(systemctl list-units --all --plain --no-legend --state=active,activating,deactivating 'max-sandbox@*.service' 'max-browser@*.service')
[[ -z "$native" ]] || { echo 'Native Max instances have not finished stopping' >&2; exit 1; }
running=$(docker ps --format '{{.Names}}')
if grep -Eq '^(max-sb-|max-br-|napcat$)' <<<"$running"; then
  echo 'Max Docker instances or NapCat are still running' >&2
  exit 1
fi
install -d -m 700 "$state" "$state/volumes" "$state/migration-backups"
exec 9>"$state/migration.lock"
flock -n 9
for volume in $volumes; do
  source=$legacy/$volume/_data
  if [[ -d "$source/.max-work" && ! -L "$source/.max-work" ]]; then source=$source/.max-work; fi
  destination=$state/volumes/$volume
  if [[ -e "$destination" ]]; then
    # An already completed migration is idempotent; never overwrite new work.
    [[ -f "$destination/.migrated-from-docker" ]] || { echo "existing native volume: $volume" >&2; exit 1; }
    continue
  fi
  temporary=$(mktemp -d "$state/volumes/.migration-$volume.XXXXXX")
  install -d -m 700 "$temporary/work"
  rsync -aH --numeric-ids -- "$source/" "$temporary/work/"
  # Verify content, symlinks and file inventory before publishing the copy.
  changes=$(rsync -aHnc --delete --itemize-changes -- "$source/" "$temporary/work/")
  [[ -z "$changes" ]] || { echo "copy verification failed: $volume (kept at $temporary)" >&2; exit 1; }
  chown -hR 1000:1000 "$temporary/work"
  chmod 700 "$temporary/work"
  printf '%s\n' "$source" > "$temporary/.migrated-from-docker"
  mv -T "$temporary" "$destination"
  printf 'Copied and verified %s\n' "$volume"
done
# Keep credentials and account data at their existing paths. Back them up
# before adjusting ownership for the native service; print no file contents.
napcat=/var/lib/max-bot/napcat
if [[ -d "$napcat" ]]; then
  getent passwd max-napcat >/dev/null || { echo 'the native max-napcat user must exist before preparing QQ ownership' >&2; exit 1; }
  backup=$(mktemp "$state/migration-backups/napcat-XXXXXXXX.tar")
  (umask 077; tar --acls --xattrs -cpf "$backup" -C "$napcat" .)
  for directory in QQ config; do
    [[ -d "$napcat/$directory" && ! -L "$napcat/$directory" ]]
    chown -hR max-napcat:max-napcat "$napcat/$directory"
    chmod 700 "$napcat/$directory"
  done
  printf 'NapCat backup: %s\n' "$backup"
fi
echo 'Copy complete. Legacy work volumes and max-nix were preserved.'
