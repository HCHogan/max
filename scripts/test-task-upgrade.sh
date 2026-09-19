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
for migration in migrations/*.sql; do
  name="$(basename "$migration")"
  if [[ "$name" > "088_task_runtime_completion.sql" ]]; then
    if [[ "$name" == "091_frontend_limits.sql" ]]; then
      psql -X -v ON_ERROR_STOP=1 -d "$database" -f test-db/fixtures/frontend-limits-upgrade.sql
    elif [[ "$name" == "093_haskell_task_settlement.sql" ]]; then
      psql -X -v ON_ERROR_STOP=1 -d "$database" -f test-db/fixtures/task-settlement-upgrade.sql
    elif [[ "$name" == "095_haskell_authority_and_workspaces.sql" ]]; then
      psql -X -v ON_ERROR_STOP=1 -d "$database" -f test-db/fixtures/task-authority-upgrade.sql
    elif [[ "$name" == "096_haskell_monitor_admission.sql" ]]; then
      continue
    elif [[ "$name" == "097_endpoint_known_identities.sql" ]]; then
      psql -X -v ON_ERROR_STOP=1 -d "$database" -f test-db/fixtures/endpoint-identities-upgrade.sql
    elif [[ "$name" == "099_progress_review.sql" ]]; then
      psql -X -v ON_ERROR_STOP=1 -d "$database" -f test-db/fixtures/progress-review-upgrade.sql
    elif [[ "$name" == "114_direct_task_notices.sql" ]]; then
      psql -X -v ON_ERROR_STOP=1 -d "$database" -f test-db/fixtures/direct-notices-upgrade.sql
    elif [[ "$name" == "115_local_conversations.sql" ]]; then
      psql -X -v ON_ERROR_STOP=1 -d "$database" -f test-db/fixtures/local-conversations-upgrade.sql
    elif [[ "$name" == "116_local_jobs.sql" ]]; then
      psql -X -v ON_ERROR_STOP=1 -d "$database" -f test-db/fixtures/local-jobs-upgrade.sql
    elif [[ "$name" == "117_diagnostic_results.sql" ]]; then
      psql -X -v ON_ERROR_STOP=1 -d "$database" -f test-db/fixtures/diagnostic-results-upgrade.sql
    elif [[ "$name" == "118_local_ingress.sql" ]]; then
      psql -X -v ON_ERROR_STOP=1 -d "$database" -f test-db/fixtures/local-ingress-upgrade.sql
    elif [[ "$name" == "119_local_delivery.sql" ]]; then
      psql -X -v ON_ERROR_STOP=1 -d "$database" -f test-db/fixtures/local-delivery-upgrade.sql
    elif [[ "$name" == "120_local_media.sql" ]]; then
      psql -X -v ON_ERROR_STOP=1 -d "$database" -f test-db/fixtures/local-media-upgrade.sql
    elif [[ "$name" == "121_local_historian.sql" ]]; then
      psql -X -v ON_ERROR_STOP=1 -d "$database" -f test-db/fixtures/local-historian-upgrade.sql
    elif [[ "$name" == "122_single_summary.sql" ]]; then
      psql -X -v ON_ERROR_STOP=1 -d "$database" -f test-db/fixtures/single-summary-upgrade.sql
    else
      psql -X -v ON_ERROR_STOP=1 -1 -d "$database" -f "$migration" >/dev/null
    fi
  fi
done
