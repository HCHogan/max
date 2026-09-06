# ADR008: one coordinated task cutover

Status: read-only inspection on 2026-09-06 confirmed migrations 087–089 and
revision `4e9f934` on h610. This release adds the P0 follow-up and frontend-limit
migration 091; production behavioral acceptance is separate from automated gates.

## User surface

- Long work uses `task_start` with an idempotency key, explicit objective/context
  and `research`, `browser` or `sandbox` profile. It returns a stable `task#N`.
- `task_status` and `task_list` inspect work; completion normally wakes the
  frontend without polling. `task_finish` and `task_progress` are private to background execution.
- `request_finish` records answered/waiting/declined and the frontend reply;
  only recorded output settles an explicit request.
- `!task list`, `!task status task#N`, `!task steer task#N <note>`.
- `!task cancel task#N [reason]` and
  `!task replace task#N <revision> <new objective>` require initiator/admin
  authority. Rewording does not reset budget. Cancellation cannot retract an
  effect already admitted or committed.
- Replying to an unambiguous task-linked output addresses that task. Multiple
  task handles in one output require an explicit handle. Same author or newest
  runtime entry is not an assignment. `!feedback task#N <note>` also addresses
  the durable inbox; unaddressed `!feedback` asks for a target. `!btw <question>`
  keeps a separate queued request even when the frontend is busy.
- `monitor_history` includes revisions, task links, coalescing, overflow and
  failures. `configure_monitor` requires CAS and explicit retain/cancel policy
  for pending old-revision occurrences, plus explicit profile/change_only fields. `cancel_monitor` stops future/pending
  work; `cancel_tasks=true` separately cancels admitted tasks.

## Local gates

Use an isolated PostgreSQL test database, never the production URL:

```sh
cabal test max-test --test-show-details=direct
MAX_TEST_DB_URL=<isolated-test-db> cabal test max-test-db --test-show-details=direct
PGHOST=<test-host> PGPORT=<test-port> PGUSER=<test-role> bash scripts/test-task-upgrade.sh
cabal build all
cabal run max-prompt-flow
cabal run max-prompt-flow -- --check
git diff --check
```

`Max.DB.TaskSpec` exercises admission, provenance, capability profiles, CAS,
durable inbox races, cancellation, ancestor reservations, lease recovery,
resource ownership, frontend/output fences, obligation settlement and monitor
overlap. Monitor regressions cover changes back to earlier values, periodic
failure notices, cron advancement after overflow and unowned legacy controls.
Agent loop tests verify immediate frontend yield and terminal returns.
Existing database tests continue covering real outbox/dispatch races and monitor recovery. The upgrade script creates its own
isolated database and verifies preservation of active Tasks alongside archived
Plan work (the test role needs CREATEDB). Provider admission tests exercise
reserved foreground capacity, class fairness and cancellation cleanup. The hourly-budget fixture explicitly uses queue policy
so it tests the budget rather than the new coalescing default.
The upgrade gate also applies subsequent migrations and verifies that 091
extends active frontend leases without reviving expired ones. Health tests
execute the exact production queries on the current schema. Cron timestamp
fixtures use PostgreSQL precision, avoiding nanosecond rounding failures.
Stream tests exercise timeout after publication commit, callback failure,
caller cancellation and trailing usage after a terminal frame on a still-open
provider socket.
Reminder tests check body mention resolution without an automatic initiator
mention.

These are deterministic tests, not measurements of real model quality, Docker
browser/sandbox behavior, or delivery to a production platform.

## Follow-up switch

1. Record current operational health, backlog, active tasks/monitor fires and
   the runtime version; address existing health failures before claiming a
   healthy rollout. Take and verify a database backup, and retain the old binary
   and configuration without exposing credentials.
2. Validate the candidate, then drain and replace the service once. Migration
   088 expands active Task quotas without resetting reservations, snapshots old
   monitor profiles/policy, archives Plan definitions/revisions/spawn edges in
   `retired_runtime_records`, and removes Plan tables/triggers. Legacy Plan work
   is aborted, not replayed; shared journals preserve uncertain effects. Existing
   Task IDs/revisions/leases remain intact. Do not run the old binary concurrently
   with this schema. Already-admitted monitor turns retain their recovery reader. No two workers may
   own the same task attempt. Do not clear journals, pending requests or
   `outcome-unknown` effects to make a health report look clean.
   For installations already on 088 or later, apply only pending migrations;
   091 doubles valid frontend lease time without resetting tasks or replaying
   reminders.
3. Run the following acceptance cases through the real endpoints with bounded
   test objectives. Measure first-response/completion latency and provider
   usage; missing usage is unknown. Set quality/latency thresholds before
   comparing representative tasks, not after seeing results.
4. Check task state, event history, result links, monitor fire history and
   per-endpoint delivery state. Only then declare the switch healthy.

### Behavioral acceptance

- A starts long research; B gets a quick answer while A still runs. A's second
  unrelated question remains separate; an addressed correction reaches A's task.
- Browser tasks do not share a browser session. Sandbox tasks cannot take
  another active task's sandbox; ambiguous in-flight effects remain visible.
- Another participant may suggest evidence, but cannot replace/cancel A's task.
- Stop between admission and execution, then restart. Recover the same logical
  task with a new attempt, preserved reservations and journal evidence.
- Replace/cancel while an attempt finishes. Old reports cannot publish as the
  current task. Cancel a monitor with both active and pending work and check
  the separate `cancel_tasks` behavior.
- Repeated ledger/cron observations preserve their occurrence history without
  concurrent work on one monitor. Queue overflow is visible. Canned reminders
  still arrive independently, including on a slow mirrored endpoint.
- A summary-model failure still produces a bounded, fenced literal task report;
  a failed physical delivery stays in its endpoint outbox, not a repeated task.

## Limits and rollback

This release allows 60 frontend tool calls and 750 seconds per
activation, with a 900-second database lease. This doubles the frontend values
from migration 088. Canned reminders use the normal body placeholder resolver;
only an explicit body mention generates an @, with no extra initiator mention.

`maintenance health` reports `request_pending` and `task_retrying` as backlog.
It fails on `task_expired_attempt`, `task_overdue_deadline`,
`frontend_expired_lease`, `task_notification_exhausted`, and `request_failed`,
in addition to the existing delivery/dispatch/media/monitor/journal checks.
Recheck expired ownership after a recovery interval; investigate persistent
counts and historical failed requests individually. Do not delete obligations
to make the gate green. A clean isolated database is schema/test evidence,
not a production health result.

The [ADR quota table](../adr/008-durable-tasks-conversation-coordination.md#fivefold-quota-changes)
lists all fivefold changes. Hard task bounds are tool reservations, agent-model rounds, tree depth, attempt
count, admission deadline and active-task counts. Tokens/cost and provider
usage are observational; helper LLM calls are not agent-loop rounds. A success
report is an explicit agent claim with evidence, not a generic proof of success.
The frontend deadline includes context assembly; it is not a promised network
response time. A process-local per-provider gate reserves ten of 50 LLM-effect
slots for foreground; it cannot reserve actual backend capacity. Active-active service takeover is not
introduced by this change.

An old binary refuses a database containing an unknown migration. Do not delete
the migration ledger entry to force a downgrade. Prefer a forward fix; restoring
the verified pre-switch backup requires an explicit outage/reconciliation plan
for messages and effects committed after that backup. Never blindly replay
unknown sends or commands. This runbook authorizes none of those operations.
