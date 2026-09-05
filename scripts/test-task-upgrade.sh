#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
database="max_task_upgrade_$$"
createdb "$database"
trap 'dropdb --if-exists "$database"' EXIT
for migration in migrations/*.sql; do
  if [[ "$(basename "$migration")" == "088_task_runtime_completion.sql" ]]; then
    break
  fi
  psql -X -v ON_ERROR_STOP=1 -1 -d "$database" -f "$migration" >/dev/null
done
psql -X -v ON_ERROR_STOP=1 -d "$database" -f test-db/fixtures/task-upgrade-before.sql >/dev/null
psql -X -v ON_ERROR_STOP=1 -1 -d "$database" -f migrations/088_task_runtime_completion.sql >/dev/null
psql -X -v ON_ERROR_STOP=1 -d "$database" -f test-db/fixtures/task-upgrade-after.sql
