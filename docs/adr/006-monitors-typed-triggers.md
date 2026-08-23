# ADR 006: Monitors — Typed Triggers and the Unified Scheduler

- Status: Partially implemented through slice 4. Reminders now use the
  `monitors`/`monitor_fires` scheduler; `m#`, canned and elaborated `TimeCron`,
  live-only `LedgerMatch`, fork provenance, role revalidation, TTL/fire caps
  and durable hourly budgets are production paths. The admin monitor/history
  projection and a user-facing re-aim operation remain absent. Slice 5
  `ExternalPoll` remains deliberately deferred standing network authority.
- Date: 2026-08-09.

## Context

Max can act when spoken to and when a clock fires, and in no other
case. The reminder subsystem (migration 016, `Max.Reminder`) is the
clock: one worker sleeps until the earliest pending row via the
`registerDelay` + STM `retry` idiom, an insert/cancel bumps a notify
bell that re-evaluates the schedule immediately, the DB is the single
source of truth so reminders survive restart, and delivery retry state
is kept apart from the user's schedule. It is event-driven and
restart-safe — and mute: a fire can only speak the canned text it was
armed with.

What the model cannot express is a condition carrying *intent*: "when
hank posts the new data, redo the chart", "when the CI run finishes,
look at the result", "if the feed mentions X, tell me". Today waiting
exists only inside a live dispatch, and dispatches are ephemeral; there
is no durable object that holds an armed condition while nobody is
running.

ADR 002 already supplies every concept this feature needs, and reserves
none of them for the machine: a `Goal` is persisted intent; effect
ceilings bound what a continuation may do; the journal records the
effects and transitions while a domain row materializes current state;
"resume granularity is the turn" fixes what firing must mean; and the
routing lattice's `depend` verb — "when that finishes, use the result
for Y" — is exactly this feature with "that" restricted to another
turn. ADR 005 gives a continuation its
provenance edge (`fork-from`) and its view machinery. ADR 004 gives the
trigger evidence a handle grammar. A monitor composes these; it invents
nothing.

## Decision

### A monitor is a journaled armed suspension

A monitor has one durable current-state row: who armed it (principal and
arming turn, for provenance), the conversation it is scoped to, a
`Goal`-shaped statement of intent, a **typed trigger spec**, an effect
ceiling recorded at arm time, lifetime bounds, status, fire count, and
the last observation/cooldown state its evaluator needs. One-shot status
transitions `armed → fired`; recurring monitors remain `armed` while
each occurrence appends a distinct `monitor_fire` row. Lifetime
exhaustion and cancellation transition `armed → expired` or
`armed → cancelled`. Canned deliveries inherit the reminder machinery's
attempt/parked bookkeeping unchanged.

Each fire has a trigger-kind-specific idempotency key and a small durable
admission state (`pending → dispatched`, with a reclaimable lease while
being handled). Evaluators commit `pending`; a worker claims it after
commit, opens or enqueues the continuation with the fire id as its
idempotency key, and records the resulting turn or canned delivery. Boot
reclaims expired claims before evaluating new work. A committed trigger
therefore survives the crash window between observation and dispatch,
and retry cannot admit it twice.

The DB is the single source of truth. In-memory watchers are the wakeup
bell — a write-through cache in the `sandboxes`-table mold: boot
reconciles by re-arming from rows, never by trusting memory. This is
the existing `Max.Reminder` worker idiom, generalized to more than one
wakeup source.

When implemented, monitors extend ADR 004's handle grammar with a
group-scoped ordinal `m#<n>`, beside implemented `#<nnnn>`/`s<n>` and
ADR 005's proposed `t#<n>`. The model lists, targets, and cancels
monitors by handle; it never sees a row id.

### The trigger vocabulary is typed data, not code

The model arms a monitor by filling a versioned, typed spec that the
host validates at arm time. Three constructors to start:

`LedgerMatch` also relies on host-authenticated ingest provenance. Its
implementation adds an `IngestClass` (`LiveDelivery` or `Backfill`) to the
adapter envelope, platform-event reservation, and canonical row. Adapters mark
a platform backlog drained after downtime as `LiveDelivery`; an importer or
migration marks historical material as `Backfill`. The class is never inferred
from `occurred_at`, `received_at`, a cursor, or model-visible content, and an
absent or unknown class fails closed for monitor evaluation. Existing rows may
be migrated as `Backfill` because every new monitor snapshots the current
ledger frontier before it can evaluate anything.

- **`TimeCron`** — a one-shot instant or a cron expression against the
  display timezone. This is the absorbed reminder subsystem; the
  existing sleep-until-earliest worker is its evaluator, unchanged.
- **`LedgerMatch`** — a predicate over newly ingested canonical rows in
  the arming conversation: optional sender principal, text
  pattern, media kind, mention-of-self. Evaluated in-process at ingest
  — the ingest *is* the event, so there is no polling. Arming snapshots
  the conversation's current `ingest_seq`, so rows already present can
  never match. The snapshot alone does not cover content imported
  *after* arming — a history import mints fresh `ingest_seq` for old
  utterances — so ingest provenance distinguishes live delivery from
  backfill, and monitors evaluate only canonical inbound rows carrying the
  host-authenticated `LiveDelivery` class: platform backlog drained after
  downtime fires; a migration or history import does not. Outbound/internal
  rows cannot recursively trigger the matcher. Evaluation and insertion of the
  unique `(monitor_id, canonical_message_id)` fire record occur in the
  canonical-ingest transaction; the ordinary fire worker claims it only
  after commit. The trigger is edge-triggered per row, with a
  per-monitor cooldown (default 60s) so a burst cannot machine-gun
  fires; the cooldown advance is an atomic same-transaction guard on
  the monitor row, so concurrent ingests cannot both pass it.
- **`ExternalPoll`** — a budgeted probe of an external observable
  (v1: HTTP GET plus a text pattern or content-hash-change test),
  with a floor on the interval (default minimum 5 minutes). This is
  the only polling constructor, and it is level-triggered by nature:
  the predicate sees the latest observation, and transitions between
  polls are unobservable — the contract says so rather than pretending
  otherwise. The probe is a host-managed network effect, not sandbox
  code: target and redirects are validated against its resource scope,
  ambient credentials are absent unless explicitly granted, and the
  request target, response digest, and outcome are journaled.

Arbitrary code predicates are rejected on ADR 002's opaque-code
grounds: a predicate the host cannot statically scope re-imports the
inference problem the typed vocabulary exists to avoid. A condition
that needs computation belongs in the elaborated continuation, not the
trigger — fire cheap, think after.

The spec is versioned data, so the vocabulary can grow (a sandbox-file
watch, a turn-completion watch subsuming `depend`) without schema
archaeology.

### Two continuation classes

**Canned text** — the reminder-compatible class. Firing delivers a
fixed text through the recorded send path with the existing retry
semantics. No LLM is involved; cost and latency are today's reminder
cost and latency.

**Elaborated** — the new class. Firing revalidates, then opens an ordinary
dispatch: a fresh horizon-1 turn whose initial view carries the goal text and
the trigger evidence, pushed as a bounded digest and pulled by handle per ADR
002's view contract. A `LedgerMatch` fire cites the matched `#<nnnn>`. For an
`ExternalPoll` fire, the worker retains the observation behind the fire row;
in the same admission transaction that creates the fresh turn, it writes an
immutable, result-bearing `trigger_input` journal row linking that observation
and the `monitor_fire`. The input row receives the turn's next persisted
`execution_ordinal`, so its `t#<turn_ordinal>:r<execution_ordinal>` handle names
it without pretending that the pre-turn poll had a producer turn or Plan node.
The durable `monitor_fire` row names the original evidence and links the turn
admitted by the fire. The turn separately records a `fork-from` edge to the
arming turn when one exists: `turn_edges` continues to relate turns, while the
fire row carries the world-event cause. Before ADR 005 slice 3 lands the
edge, arming-turn provenance is one plain text line in the view; the
edge row later replaces that fallback prose. Trigger evidence remains
in the initial view in both cases.

Nothing is frozen at arm time except intent and bounds. "Continue
exactly where the model was" stays a false concept (ADR 002): the
continuation re-elaborates under current context, which is precisely
what makes the mechanism restart-safe and model-upgrade-safe by
construction.

A fired elaborated turn is an ordinary turn in every respect: it may
use tools, it may reply — and it may conclude silence. Trigger is not
speech.

### Fire-time revalidation

Monitors are long-lived, so ADR 002's deoptimization triggers apply
with more force than they do to any in-flight plan: between arm and
fire, the group's policy, the arming principal's role, the tool
catalog, and the prompt version can all have moved. Firing therefore
re-runs the arm-time checks under current state, and the continuation
runs under the *intersection* of the arm-time ceiling and current
policy — a fire never escalates. A monitor whose arming principal has
lost the standing to have armed it expires with a journal row and no
message: fail closed, admin-visible, quiet.

Model-written specs create no authority, same as every other
model-written artifact: arming is itself a journaled effect, permitted
by role policy, and everything a fire may do was host-checked twice.

### Quietness is structural

A monitor is a standing license for bot-initiated activity — exactly
the class of behavior that must be rationed, not merely prompted into
politeness:

- Lifetime bounds are mandatory where the trigger watches the world:
  `LedgerMatch` and `ExternalPoll` monitors carry a TTL (default 30
  days) and a max-fire count (default 20). An explicit recurring
  reminder is its own standing consent and keeps its user-controlled
  lifetime.
- Armed monitors are capped per group (default 20, of which condition
  monitors — non-`TimeCron` — default 5).
- Arming requires role permission; the cap and the permission are both
  host boundaries, not prompt requests.
- An elaborated continuation may conclude silence, and recurring
  elaborated monitors draw a per-group budget in the narrator's mold —
  restraint is structural, not stylistic.

### The routing lattice already covers monitors

No new verbs. Cancel is `abort` aimed at `m#<n>`; re-aiming an armed
monitor (new goal, adjusted trigger) is `steer`, which re-runs arm
validation; listing is an observe surface. A reply to a message that a
fired turn produced targets that turn through the ordinary L3 send
linkage — the monitor needs no special addressing once it has fired.
The admin console lists armed monitors and fire history as a journal
projection, the same read-side shape as every other surface.

### Reminders unify into monitors

The `reminders` table migrates into `monitors` as `TimeCron` + canned
rows; `Max.Tools.Reminder`'s tools become sugar over arm/list/cancel
(the conversation stays implicit through `ToolContext`; the model
still never passes ids); the reminder worker generalizes into the
`TimeCron` evaluator. One scheduler, one table, one state machine —
the alternative is two drifting copies of the same sleep-until loop,
distinguished only by what happens at the far end.

## Max integration sequence

1. `monitors` table; one-shot migration absorbing `reminders`;
   reminder tools rewritten as sugar; the worker generalized.
   Behavior-preserving — no new capability, deletable duplication
   gone.
2. Arm/list/cancel tools and the `m#` handle; `TimeCron` with
   elaborated continuations: fire → revalidate → ordinary dispatch
   with goal and trigger digest in view, provenance as a view line.
   This alone delivers "remind me and *then look at it*".
3. Add host-authenticated `IngestClass` to the adapter envelope,
   platform-event reservation, and canonical row; migrate old rows as
   `Backfill`. Then add `LedgerMatch` at ingest: live-inbound evaluation,
   edge-per-row with cooldown, and journal rows for arm/fire/expire/cancel.
4. `fork-from` edge rows on fired turns (once ADR 005 slice 3 exists),
   fire-time revalidation hardening, caps and budgets, the admin
   projection.
5. `ExternalPoll`, last — it is the only poller and creates standing
   network authority. Its host HTTP path must have scoped targets,
   redirect/credential policy, journaled observations, bounded output,
   non-overlapping claims, and admission-time `trigger_input` result rows
   before release. Product rollout may also hold it until ADR 002's
   ungoverned sandbox egress is closed as a defense-in-depth rule; the two
   paths do not share an execution boundary.

## Consequences

- Waiting becomes a first-class durable state: intent survives
  restarts, upgrades, and model changes because what is persisted is
  a goal and a typed trigger, never a frozen model state.
- Reminders stop being a parallel subsystem and become the degenerate
  monitor: trivial trigger, LLM-free continuation.
- The turn graph acquires monitor-originated `fork-from` edges while
  `monitor_fire` rows retain the world-event cause, exercising the
  journal contract ahead of multi-principal concurrency — a third
  pre-machine tenant beside the narrator and the sandbox.
- Bot-initiated activity is rationed by construction — TTLs, fire
  counts, caps, budgets, and role-gated arming — rather than by
  prompt-side politeness.
- Costs: one more boot-reconcile surface, ingest-path evaluation must
  stay cheap (pure predicate over the row being written), and
  fire-time revalidation adds a policy read to every fire.

## Rejected alternatives

### Arbitrary code as the trigger predicate

Rejected on ADR 002's grounds. An opaque predicate cannot be scoped,
budgeted, or audited at arm time, and it would run with standing
authority forever. The typed vocabulary keeps triggers cheap and
inspectable; computation happens in the continuation, after the fire,
under a turn's ordinary discipline.

### A scheduler service beside the dispatch loop

Rejected — the mirror of ADR 002's rejected standalone workflow
engine. A separate service duplicates authorization, output, journal,
and observability, and turns "a fire opens an ordinary turn" into an
integration problem. Monitors are rows plus wakeup sources; everything
downstream of a fire is the existing loop.

### In-turn blocking wait as the first slice

Rejected for now. Holding a dispatch open until a condition fires is
the machine's `Wait`/`Guard` node — it requires durable in-turn
suspension, which is exactly the hard part of ADR 002's executor.
The armed-suspension-across-turns shape delivers the user-visible
capability first and is restart-safe by construction. When the machine
lands, an in-plan wait can compile to an arm + deferred continuation
without changing this ADR's contract.

### Immortal monitors

Rejected. A watcher without a lifetime is garbage with authority.
Everything that watches the world expires by default; only an explicit
user schedule earns an indefinite lease, because the user asked for
exactly that.

### Polling the ledger for matches

Rejected — ingest is the event. A poll loop over the canonical tables
would re-derive what the write path already knows at the moment it
knows it, at strictly worse latency and cost.

### Keeping reminders separate

Rejected. Two sleep-until schedulers, two tables, and two retry
machines that differ only at the fire step is drift waiting to happen;
the reminder is a monitor whose trigger is a clock and whose
continuation skips the model.
