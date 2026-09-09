# Operational debt review and live acceptance

`max-adr003-maintenance health` reports raw terminal counts alongside
`*_unreviewed` counts. Only an explicit `accepted` review of the **current exact
revision** removes terminal debt from the failing gate. Queue depth remains
informational; expired leases, deadlines and active unknown journal effects
cannot be acknowledged away. Original deliveries, dispatches, media jobs,
requests and sandbox records are retained.

## Review a bounded observation

Run the maintenance executable from the release being inspected, with an
explicit `MAX_DB_URL`. `debt export`, `health`, `verify` and `memory reviews` are
read-only and can run with traffic. `gate`, `migrate` and `reproject` require
stopped writers. `debt review` only appends audit events and supports live traffic.

```sh
max-adr003-maintenance debt export delivery_outcome_unknown all \
  '2026-09-09 05:00:00 UTC' delivery-review.json
```

Supported kinds: `delivery_outcome_unknown`, `delivery_permanent_failure`,
`dispatch_outcome_unknown`, `media_parked`, `monitor_fire_parked`,
`request_failed`, `sandbox_outcome_unknown`, `task_notification_exhausted`.
Scope must be explicit: `conversation:123` uses a **canonical conversation ID**,
`global` selects records without a conversation (currently media fetch jobs),
and `all` selects every conversation. The cutoff and 10,000-item limit bound a
batch. Narrow or remove items as necessary; never edit their observations.

Inspect source records and independent evidence, then fill the exported JSON's
`actor`, `reason`, `evidence` and `disposition`. Error and payload hashes in the
export identify observations without exporting attachment URLs or content.

- `accepted`: consciously accept an unresolved historical outcome; this does
  **not** claim the effect succeeded or failed. Never resend an ambiguous
  non-idempotent operation to find out. Record the operator's decision and why
  further reconciliation is unavailable or unnecessary.
- `reopened`: revoke an acceptance, or record an observation while leaving its
  health failure active.
- `resolved`: requires a prior audited observation and a fresh database check
  showing that the source no longer has terminal debt for that kind and ID.
  Independently verify the actual external result and record that evidence;
  do not update the source merely to satisfy this check.

```sh
max-adr003-maintenance debt review delivery-review.json
max-adr003-maintenance health
```

Review is atomic across the batch. A changed observation rejects an acceptance;
re-export and inspect it. A subsequent failure/attempt invalidates the old
acceptance even if it uses the same record ID. Reviews cannot be updated or
deleted. There is no resend, job replay or sandbox destruction path in this
command. All history remains queryable in `operational_debt_reviews`; current
classifications are in `operational_debt_status`.

## Memory corrections

Historian schema 2 uses `expected_version`: copy the observed version exactly.
The database generates the new version. Legacy `version` responses are rejected
and enter the existing bounded format-repair path. CAS and permanent-memory
protections remain enforced.

`episode_memory_review_queue` exposes rejected proposals independently from
published summaries, including existing historical failures. Re-read the
original cited messages, subsequent relevant evidence and current scoped
memories before deciding whether the old proposal is still warranted. Do not
mass-replay failures or mechanically substitute the latest version.

```sh
max-adr003-maintenance memory reviews
max-adr003-maintenance memory review LEGACY_GROUP CAPTURE INDEX \
  'operator-name' 'evidence and rationale for this review' proposal.json
```

The file contains one schema-2 proposal, or JSON `null` for an explicit dismissal.
This first-stage workflow is operator driven; it does not run an automatic
re-evaluation model. The amended proposal must cite eligible original capture
messages and pass source-integrity, content, scope, version and lifecycle checks.
If later evidence changes the fact, use a new capture of that evidence instead.
Failed reviews stay queued. Applied/dismissed reviews leave the queue. Every
attempt is retained in `episode_memory_reviews`; original proposals, summaries
and Historian cursors are unchanged.

An orphan personal-memory subject can be repaired separately:

```sh
max-adr003-maintenance memory repair-subject LEGACY_GROUP MEMORY \
  EXPECTED_VERSION CANONICAL_PRINCIPAL 'operator and checked identity evidence'
```

This requires the old subject not to exist as a principal, a unique platform
account identity mapping in that conversation, and matching original message
author evidence. Scope, version, duplicate and capacity checks all apply. The
fact and lifecycle are preserved; a new version, evidence row and mutation audit
record both old and new subject IDs. The command cannot move a valid principal's
memory or infer an ambiguous identity.

## Live release evidence

1. Record the deployed Nix closure, Git revision, schema migration filenames,
   service start time/restart count, and a UTC cutoff before changing anything.
2. Complete build, unit and disposable PostgreSQL gates. Rehearse new migrations
   against a restored production snapshot before activation.
3. Deploy the tested closure and verify its effective revision and migrations.
   Use the executable from that exact closure for all following checks.
4. Run `verify` with read-only SQL settings and normal traffic. It checks system
   event projections from relations, as the ingest writer does; a reaction's
   empty IR body must not cause its event token to be erased by `reproject`.
5. Inspect raw and unreviewed debt separately; apply only the reviewed manifest.
   Record original totals, decisions and audit IDs. Historical acceptance is not
   evidence of current transport reachability.
6. Wait at least one relevant lease interval and a real traffic window, then run
   both `verify` and `health` again. Compare newly created/changed debt since the
   cutoff, pending/retrying work, lease expiry, and service restarts. A running
   service, an empty test database, or zero unreviewed history alone is not full
   production acceptance.

iMessage now performs a read-only bridge health probe before preparing or
starting send parts. A failed probe remains retryable and creates no send-part
effect. A successful probe cannot guarantee the following send: lost responses
after send remain outcome-unknown. Probe failure also does not turn historical
unknown deliveries into known failures.

The [2026-09-09 release evidence](../research/2026-09-09-memory-health-release.md)
records a production-snapshot rehearsal and the exact h610 revision, review
decisions, data repairs and repeated live checks. Keep comparable evidence for
each release; a historical accepted batch is not permission to accept new debt.
