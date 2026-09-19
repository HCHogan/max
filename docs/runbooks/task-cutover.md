# Process-owned Jobs cutover

Use [Jobs](jobs.md) for current commands and [the simplification checklist](../simplification.md)
for implementation and acceptance evidence. ADR 008 describes the retired durable
execution design; its finish tools, idempotency keys, leases, notification reviews
and restart continuation no longer apply.

## Upgrade

1. Record the deployed revision, migration ledger, active jobs, pending deliveries
   and health result. Take and verify a database backup before schema changes.
2. Validate the candidate against an isolated database and rehearse the upgrade
   against a restored snapshot. `scripts/test-task-upgrade.sh` checks preservation
   across the migration chain; it needs a test role with `CREATEDB`.
3. Stop the old service and all writers before replacing it. Startup applies
   pending migrations. Never run old and new runtimes against this schema together.
4. Verify the running revision and migration ledger. Inspect health and actual
   platform traffic using [database health and release acceptance](database-health.md).

Migrations 114–122 remove runtime dependency on old task, request, dispatch,
media and context execution records. Historical rows remain available as evidence.
An old pending task does not become a new Job. Pending or ambiguous deliveries are
closed conservatively without resending. New Jobs use public IDs above the retained
historical sequence. Canonical messages, memories, reminder definitions, files,
explicit browser profiles and source citations remain.

## Behavioral acceptance

- A detached job runs while another user receives a foreground reply. Independent
  inputs queue; addressed feedback reaches the intended job with author provenance.
- Status, cancellation, replacement, budgets and child joins work without deadlock.
  Another participant cannot replace or cancel someone else's job.
- Text becomes visible before the provider finishes. Interruption preserves the
  published prefix and does not send it again.
- Restart interrupts work without resuming commands or replaying uncertain sends.
  New traffic, reminders, memory/search, media and all configured platforms work.
- Saved browser profiles retain allowed authentication state; live browser sessions
  remain isolated to their running jobs. Sandbox files remain available.

A passing build or disposable database suite is not production acceptance.
Record the tested revision, observed behavior, provider usage and first-visible
latency; do not infer model quality or transport health from local tests.

## Rollback

Prefer a forward fix. An old binary refuses unknown migrations: do not remove
migration ledger entries to force it to start. Restoring a pre-upgrade backup
requires a plan for messages and external effects after the backup. Inspect
uncertain outcomes before any manual repeat; never replay them automatically.
