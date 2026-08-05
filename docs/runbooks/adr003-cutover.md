# ADR 003 atomic cutover runbook

This runbook moves production directly from the pre-ADR content pipeline to
the final v2 IR pipeline. It deliberately has no rolling-upgrade, dual-reader,
or dual-writer mode. Schedule a maintenance window and keep ingress closed
until all four adapter smokes pass.

The `max-adr003-maintenance` executable and `migrations/` directory must come
from the exact release being deployed. It refuses an unknown newer schema.
Run every database command as the database owner, from a host with enough free
space for two restored copies of the database and its blobs.

## Required rehearsal evidence

Before approving the production window, restore a recent production snapshot
into an isolated database and complete this whole runbook. Record:

- source snapshot timestamp, message count, and on-disk size;
- snapshot and verification-restore duration;
- `gate` duration and the longest observed blocking lock;
- rollback restore duration;
- the four-platform smoke result and operator;
- the release revision and exact rollback revision.

The local development rehearsal on 2026-08-04 proved the mechanics only. Its
source database ended at migration 030 and contained zero messages, so it is
not production-window sizing evidence:

| Operation | Result | Wall time |
| --- | --- | ---: |
| custom-format snapshot | success | 0.04 s |
| restore verification | success | 0.05 s |
| migrations 031–064 + projection + release gate | success | 0.44 s |
| rollback restore; schema returned to migration 030 | success | 0.05 s |
| fresh empty database migrations 001–064 + release gate | success | 0.49 s |

Do not infer a maintenance-window budget from these empty-database numbers.

### Recent-production snapshot rehearsal — 2026-08-04

Candidate revision `a59c12a` was rehearsed against a stopped, consistent
snapshot of the `h610` production database at 2026-08-04 22:00:03 HKT. The
source was PostgreSQL 17.10 at migration 054 with 74,987 messages and a
database size of 941,954,739 bytes (898 MiB). The custom archive was
421,081,690 bytes with SHA-256
`73367dc40aea27a119bd9e2efd8bbf66bbb66512d2ca323cc825a94ea70adc51`.
The deployed rollback closure was
`/nix/store/vbqjya9ihpjdpc2nf1bdk128ksa63l6a-max-0.13.0`.

| Operation | Result | Wall time |
| --- | --- | ---: |
| graceful stop and drain | success, zero in-flight dispatches | 1 s |
| custom-format production snapshot | success | about 50 s |
| isolated verification restore | all seven ledger/queue counts matched | 16 s |
| migrations 055–064 + projection + release gate | success; 8,907 projections regenerated | 29.375 s |
| sampled blocking lock wait during gate | none observed at 50 ms sampling | 0 ms |
| atomic rollback replacement and restore | migration 054, all counts and legacy writers restored | 15.815 s |

The gate converted one abandoned eight-hour-old `sending` Matrix lease to
`outcome_unknown` without retrying it; that production-derived failure led to
the runtime recovery and partial-index guard in revision `a59c12a`. After the
upgrade, all 74,987 messages decoded as v2 and the ledger contained 74,895
platform events, 6,383 semantic relations, 75,158 deliveries, and 74,987
dispatches. The rollback copy returned exactly to 54 migrations, 74,987 v1
messages, 256 relations, 75,158 deliveries, 74,895 events, 74,987 dispatches,
and 52 parked fetch jobs. Actual service downtime was 6 minutes 57 seconds,
including initial privilege/setup failures before the successful snapshot;
do not use that total as the expected cutover duration.

This rehearsal completed the recent-production database evidence only. It did
not deploy the final binary or perform the four-platform live smoke, which
remain mandatory before reopening ingress in the actual cutover window.

A second local rehearsal seeded a migration-030 clone with three legacy QQ
rows before taking the rollback snapshot. The fixture included mention, face,
sticker, file, video, card, forward-child, and reply provenance. The 031–064
gate preserved all three messages, rebuilt the rich row as ordered
`text/mention/emote/media/media/media/card/forward` v2 nodes, created the
forward relation, regenerated two stale projections, and passed the complete
ledger gate. Restoring the snapshot returned the clone to migration 030 with
all three legacy rows and their reply/forward columns intact. This synthetic
fixture proves non-empty semantic backfill and rollback mechanics; it is still
not recent-production sizing or distribution evidence.

## Prepare

Build and test the final release before the window. Keep both the final and
old deployment closures available. Set task-specific variables explicitly;
never rely on a default database:

```sh
export ADR003_DB_URL='postgresql://…/max-bot'
export ADR003_MIGRATIONS='/path/from/final-release/migrations'
export ADR003_GATE='/path/from/final-release/bin/max-adr003-maintenance'
export ADR003_SNAPSHOT='/safe/off-host-or-redundant-volume/max-pre-adr003.dump'
export ADR003_OLD_REV='<known-good-old-revision>'
export ADR003_NEW_REV='<final-adr003-revision>'
```

Confirm that the values name the intended host/database and that the release
binary and migration directory have the expected revision. Disable any
deployment automation that could restart or replace `max` during the window.

## Stop the world and snapshot

1. Close Matrix/iMessage polling and prevent NapCat/WechatPad reconnects or
   new webhook traffic at the ingress boundary.
2. Gracefully stop `max` (`systemctl stop max` on the NixOS deployment). Wait
   for the shutdown/drain log to finish. Confirm there is no `max` process and
   no other role writing the database.
3. Check the durable work state. Pending/failed dispatches, deliveries, or
   unparked `fetch_jobs` mean the old workers did not drain; restart the old
   release with ingress still closed, let it drain, stop it, and check again.
   An expired `sending` delivery is different: its worker disappeared after
   claiming a potentially non-idempotent send, so retrying could duplicate it.
   The final gate atomically classifies such abandoned leases as
   `outcome_unknown` and reports the count; it never resends them. A live
   (unexpired) `sending` lease still blocks the gate.
4. Snapshot the database and verify it by restoring to a newly created,
   isolated database. Compare schema migration, message, relation, delivery,
   and event counts with production. Drop only that explicitly named
   verification database after the comparison succeeds.

Example snapshot command:

```sh
pg_dump --format=custom --serializable-deferrable \
  --dbname="$ADR003_DB_URL" --file="$ADR003_SNAPSHOT"
pg_restore --list "$ADR003_SNAPSHOT"
sha256sum "$ADR003_SNAPSHOT"
```

Do not continue if the verification restore fails or counts differ. Preserve
the snapshot until the release has passed its observation window.

## Cut over

With every writer still stopped, run the all-in-one gate:

```sh
MAX_DB_URL="$ADR003_DB_URL" \
MAX_MIGRATIONS_DIR="$ADR003_MIGRATIONS" \
"$ADR003_GATE" gate
```

`gate` performs, in this order:

1. final migrations and the offline v1/segments → v2 backfills;
2. `rendered_text` regeneration from canonical IR and origin identities;
3. strict v2 decoding plus schema, relation, delivery, dispatch, source-event,
   source-delivery, sequence, legacy-object, and projection checks;
4. a zero-active-work check for delivery, dispatch, and media queues.

Any failure leaves the service stopped. Diagnose it against the restored copy;
do not manually weaken a check on production. Migrations and projection
updates are transactional at their own boundaries and safe to rerun.

Deploy the final revision without opening ingress. Start `max`, then run the
same binary in non-draining verification mode:

```sh
MAX_DB_URL="$ADR003_DB_URL" \
MAX_MIGRATIONS_DIR="$ADR003_MIGRATIONS" \
"$ADR003_GATE" verify
```

## Smoke before reopening ingress

Open one test endpoint at a time. For QQ, Matrix, iMessage, and wechatpad,
exercise and inspect the admin **消息账本** timeline for:

1. inbound plain text and a non-bot mention;
2. reply relation and native/text lowering at each destination;
3. image/media ingest, authenticated thumbnail hydration, and delivery;
4. bot reply through the canonical outbox and echo reconciliation;
5. mirror ordering across at least two consecutive messages;
6. supported edit/redaction/reaction behavior, and a quiet suppressed reaction
   on an endpoint that advertises no native reaction.

For every copy, confirm delivery status/native id, `lower_notes`, canonical
nodes, semantic relations, and the derived prompt projection. A transport
must never read `segments` or `rendered_text` to send.

When all four adapters pass, reopen all ingress and monitor:

```sql
SELECT status, count(*) FROM message_deliveries GROUP BY status ORDER BY status;
SELECT status, count(*) FROM message_dispatches GROUP BY status ORDER BY status;
SELECT endpoint_id, count(*)
FROM message_deliveries
WHERE status IN ('failed', 'outcome_unknown', 'suppressed')
GROUP BY endpoint_id ORDER BY endpoint_id;
SELECT count(*) FROM fetch_jobs WHERE parked_at IS NOT NULL;
```

Investigate growing failed queues, parked media, unexpected suppressions, or
non-monotone per-endpoint native events before ending the observation window.

## Post-cutover repairs

**2026-08-04 legacy emote/card projection repair.** The 055 backfill paired
QQ segments with v1 content parts to recover face names and card titles.
That pairing invariant held for `inbound` rows but not for 049-backfilled
`legacy` rows, whose v1 content was one flattened text part: 448 emote
nodes absorbed the entire old `rendered_text` as their name and 167 card
titles did the same, and the gate reprojection burned nested tokens into
`rendered_text`. Repaired in place with the service stopped (16 minutes):
real face names were regex-recovered from the absorbed text itself
(anchored `[face#N: …]` forms, bracket-wrapped names like `[偷感]`
included; unrecoverable bare tokens dropped the name), card titles
recovered their `[card: …]` line, and `rendered_text` was reprojected for
exactly the 615 affected rows in SQL. Zero nested tokens and zero node
pollution remained afterwards; the embedder re-embedded the touched rows
by staleness detection. Pre-repair snapshot:
`/var/tmp/max-pre-face-repair-20260804.dump` (463 MiB, keep until the
observation window ends). The migration squash below removed the
replayable 055, so the defect class cannot recur on fresh databases.

**2026-08-05 compartment source-hash re-stamp (migration 065).** Migration 062
changed `conversation_source_hash` and the ledger columns it reads (055 rewrote
`canonical_content`, 059 added `event_kind`, 060 changed `occurred_at`), so
every hash stamped before the cutover describes an input set the function can
no longer produce: the admin integrity check counted the whole history as
`bad_source_ranges` and every expand handle reported a source mismatch. The
migration re-stamps only rows whose stored hash differs, and runs itself on the
next boot — no manual step.

Production before the fix: 161 of 186 compartments stale, and the split falls
exactly on the cutover — every stale row was created between 2026-08-02 18:46
and 2026-08-04 14:22 (before 062), every correct row from 14:53 onward. So the
re-stamp touches only hashes computed by the old function and leaves
post-cutover drift evidence alone. Drift detection is meaningful again from
that deploy forward.

**2026-08-05 delivery retry budget.** A rejection by a reachable edge (QQ risk
control, a reaction on a deleted target) was retryable-shaped forever and held
the endpoint's ordered lane behind it. It now ends as `suppressed` after
`deliveryAttemptBudget` attempts (~45 minutes). An *unreachable* edge is
deliberately exempt: production delivery 72552 spent 159 attempts across an
eleven-hour QQ outage and then landed, and while an edge is down the lane is
denied to nobody. Exactly one delivery in the whole ledger has ever exceeded
the budget, and it was that outage.

**2026-08-05 release-gate repair.** `max-adr003-maintenance verify` was unsafe
to run after the squash: it required the individual 055–064 filenames that
`reconcileSquash` had already collapsed into `000_baseline.sql`, and it
recomputed `rendered_text` from the enriched canonical body while ingest still
rendered it from the pre-identity ingest body, so it failed on every row whose
mention display had been enriched. Both sides now render from the resolved
canonical body, and the gate requires the baseline. `verify` is safe to run
against the live database again.

## Atomic rollback

There is no binary-only rollback. If a release-blocking fault appears:

1. close ingress again and stop the final service and every writer;
2. preserve a diagnostic snapshot of the failed v2 database separately;
3. replace the database with a clean restore of `ADR003_SNAPSHOT`;
4. verify schema migration and ledger counts match the pre-cutover record;
5. deploy `ADR003_OLD_REV`, start it with ingress still closed, and run its
   representative old-path smoke;
6. reopen ingress only after that smoke succeeds.

Never point the old binary at the migrated database: migration 061 removes
the legacy writer contract, and the old application does not understand v2.
