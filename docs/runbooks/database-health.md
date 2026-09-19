# Database health and release acceptance

Use the maintenance executable from the release being inspected with an explicit
`MAX_DB_URL`. `health`, `verify` and `memory reviews` are read-only and can run
with traffic. `migrate`, `gate` and `reproject` require stopped writers.

```sh
max-adr003-maintenance health
max-adr003-maintenance verify
```

`health` reports retained delivery failures, unknown effects, parked reminder
fires, expired reminder admission claims and unresolved sandbox state. A nonzero
critical count fails the command. Historical failures remain visible; there is
no debt acknowledgement command that suppresses them. This does not establish
current transport reachability or inspect process-local queues. Check the running
admin status, worker logs and actual platform receipts alongside database health.

`verify` also checks the installed baseline, canonical message structure,
projections, source deliveries and relationships. It never rewrites projections.
Retired dispatch/task execution tables and their lease indexes are outside the
current runtime gate; their rows remain retained history.

Never change historical outcomes merely to make a gate green. A failed iMessage
health probe creates no send effect, but a successful probe cannot prove a later
send succeeded. Lost send responses remain unknown until independent evidence
resolves them.

## Memory corrections

Memory proposals use `expected_version`: copy the observed version exactly.
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

The file contains one current memory proposal, or JSON `null` for an explicit dismissal.
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

1. Record the deployed Nix closure, Git revision, migration filenames, service
   start/restart count and a UTC cutoff before changing anything.
2. Complete build, unit, capability and isolated PostgreSQL gates. Rehearse
   pending migrations against a restored snapshot before activation.
3. Stop the previous writers, deploy the tested closure and verify its effective
   revision and migrations. Use that closure's executable for subsequent checks.
4. Run `verify` and `health` read-only. Record existing failures separately from
   newly created or changed outcomes since the cutoff.
5. Exercise foreground streaming, Jobs, cancellation, reminders, memory/search,
   media and configured platform delivery. Check the actual native receipts.
6. Observe a real traffic window, then repeat health checks and inspect worker
   logs, process-local queue status and service restarts. Report unresolved
   historical effects and current functional failures separately.

A running service, an empty test database or a historical acceptance report does
not prove this release healthy. Earlier debt-review decisions remain historical
evidence; they do not authorize a new acceptance or replay.
