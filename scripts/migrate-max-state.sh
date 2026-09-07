#!/usr/bin/env bash
# Offline migration from the original native layout; never copies over live data.
set -euo pipefail
umask 077
mode=${1:---check}
[[ "$mode" == --check || "$mode" == --migrate ]] || { echo 'usage: migrate-max-state.sh [--check|--migrate]' >&2; exit 64; }
[[ $EUID == 0 ]] || { echo 'run as root' >&2; exit 77; }
for command in systemctl runuser psql pg_dump pg_restore usermod groupmod nix-store findmnt; do command -v "$command" >/dev/null; done
old=/var/lib/max-bot
state=/var/lib/max
[[ -d "$old" && ! -L "$old" && -d /var/lib/max-runtime && ! -L /var/lib/max-runtime ]]
[[ ! -e "$state/app" && ! -e "$state/runtime" && ! -e "$state/napcat" ]]
getent passwd max-bot >/dev/null
! getent passwd max >/dev/null
! getent group max >/dev/null
[[ $(stat -c %d "$old") == "$(stat -c %d /var/lib)" ]]
[[ $(stat -c %d /var/lib/max-runtime) == "$(stat -c %d /var/lib)" ]]
[[ $(runuser -u postgres -- psql -XAt -d postgres -c "SELECT count(*) FROM pg_database WHERE datname='max-bot'") == 1 ]]
[[ $(runuser -u postgres -- psql -XAt -d postgres -c "SELECT count(*) FROM pg_database WHERE datname='max'") == 0 ]]
[[ $(runuser -u postgres -- psql -XAt -d postgres -c "SELECT count(*) FROM pg_roles WHERE rolname='max'") == 0 ]]
if [[ "$mode" == --check ]]; then
  echo 'Preflight passed. Migration requires the whole Max stack to be stopped.'
  exit 0
fi
exec 9>/run/lock/max-state-migration.lock
flock -n 9
for unit in max.service max-runtime.service max-runtime.socket max-napcat.service; do
  active=$(systemctl show "$unit" -p ActiveState --value)
  [[ "$active" == inactive || "$active" == failed ]] || { echo "$unit is not stopped" >&2; exit 1; }
done
[[ -z $(systemctl list-units --all --plain --no-legend --state=active,activating,deactivating 'max-sandbox@*.service' 'max-browser@*.service') ]]
! pgrep -u "$(id -u max-bot)" >/dev/null
[[ $(runuser -u postgres -- psql -XAt -d postgres -c "SELECT count(*) FROM pg_stat_activity WHERE datname='max-bot'") == 0 ]]
# A stopped nspawn must have released every root/work mount before rename.
! findmnt -rn -o TARGET | grep -Eq '^/var/lib/(max-bot|max-runtime)(/|$)'
install -d -m 0755 "$state"
install -d -m 0700 "$state/backups"
backup=$(mktemp -d "$state/backups/state-migration-XXXXXXXX")
printf '%s\n' "$backup" > "$state/backups/latest-state-migration"
id -u max-bot > "$backup/uid"
id -g max-bot > "$backup/gid"
getent passwd max-bot > "$backup/passwd"
getent group max-bot > "$backup/group"
readlink -f /run/current-system > "$backup/old-system-path"
nix-store --realise "$(cat "$backup/old-system-path")" --add-root "$backup/old-system" --indirect >/dev/null
runuser -u postgres -- pg_dump -Fc --dbname=max-bot > "$backup/max-bot.dump"
pg_restore --list "$backup/max-bot.dump" > "$backup/max-bot.dump.list"
test -s "$backup/max-bot.dump.list"
tar --acls --xattrs -cpf "$backup/napcat.tar" -C "$old/napcat" .
tar -tf "$backup/napcat.tar" >/dev/null
sha256sum "$backup/max-bot.dump" "$backup/napcat.tar" > "$backup/checksums"
(
  cd "$old"
  for directory in images var .config wechatpad; do
    if [[ -d "$directory" ]]; then find "$directory" -type f -exec sha256sum '{}' +; fi
  done
) > "$backup/app-files.sha256"
(cd /var/lib/max-runtime; find volumes -type f -exec sha256sum '{}' +) > "$backup/work-files.sha256"
printf 'Verified backups: %s\n' "$backup"

mv -T "$old" "$state/app"
mv -T /var/lib/max-runtime "$state/runtime"
mv -T "$state/app/napcat" "$state/napcat"
install -d -m 0700 "$backup/legacy-config" "$backup/runtime" "$state/private"
shopt -s nullglob
for file in "$state/app"/max.yaml* "$state/app"/*.env*; do mv "$file" "$backup/legacy-config/"; done
for directory in backups adr003-backups; do
  if [[ -e "$state/app/$directory" ]]; then mv "$state/app/$directory" "$backup/$directory"; fi
done
# Keep old roots and metadata as evidence; the broker reconstructs new roots
# from its new template while adopting the original durable work directories.
for directory in roots instances; do
  if [[ -d "$state/runtime/$directory" ]]; then mv "$state/runtime/$directory" "$backup/runtime/"; fi
done
for mapping in /var/lib/private/max-browser:browser /var/cache/private/max-browser:browser-cache; do
  source=${mapping%:*}; destination=$state/private/${mapping##*:}
  if [[ -d "$source" ]]; then mv -T "$source" "$destination"; fi
done
for directory in /var/lib/max-browser /var/cache/max-browser /var/lib/max-napcat; do
  if [[ -e "$directory" || -L "$directory" ]]; then
    label=${directory#/var/}; label=${label//\//-}
    mv -T "$directory" "$backup/$label"
  fi
done
if [[ -d /nix/var/nix/gcroots/max-sandboxes ]]; then
  mv -T /nix/var/nix/gcroots/max-sandboxes "$state/runtime/gcroots"
fi
install -d -m 0700 "$state/runtime/gcroots"
# Indirect GC registrations encode the root's absolute path, so moving the
# symlink alone does not keep a closure alive.
while IFS= read -r -d '' root; do
  target=$(readlink "$root")
  nix-store --realise "$target" --add-root "$root" --indirect >/dev/null
done < <(find "$state/runtime/gcroots" "$state/runtime/migration-backups" -type l -lname '/nix/store/*' -print0)
groupmod -n max max-bot
usermod -l max -d "$state/app" max-bot
[[ $(id -u max) == "$(cat "$backup/uid")" && $(id -g max) == "$(cat "$backup/gid")" ]]
runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -d postgres <<'SQL'
ALTER ROLE "max-bot" RENAME TO max;
ALTER DATABASE "max-bot" RENAME TO max;
SQL
runuser -u postgres -- psql -X -v ON_ERROR_STOP=1 -d max <<'SQL'
BEGIN;
UPDATE images SET local_path='/var/lib/max/app/' || substr(local_path,length('/var/lib/max-bot/')+1) WHERE starts_with(local_path,'/var/lib/max-bot/');
UPDATE videos SET local_path='/var/lib/max/app/' || substr(local_path,length('/var/lib/max-bot/')+1) WHERE starts_with(local_path,'/var/lib/max-bot/');
UPDATE group_files SET local_path='/var/lib/max/app/' || substr(local_path,length('/var/lib/max-bot/')+1) WHERE starts_with(local_path,'/var/lib/max-bot/');
COMMIT;
SQL
chmod 0700 "$state/app" "$state/napcat" "$state/runtime"
(cd "$state/app"; sha256sum --check --quiet "$backup/app-files.sha256")
(cd "$state/runtime"; sha256sum --check --quiet "$backup/work-files.sha256")
[[ $(runuser -u max -- psql -XAt -d max -c 'SELECT current_user') == max ]]
touch "$backup/complete"
echo "Migration complete; rollback evidence: $backup"
