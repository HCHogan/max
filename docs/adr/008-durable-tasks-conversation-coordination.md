# ADR 008: Durable Tasks and Conversation Coordination

- Status: Accepted; **local implementation, production cutover pending**.
  This decision retires the model-authored Plan DSL and adaptive-elaboration
  programme of [ADR 002](002-partial-plans-adaptive-elaboration.md), and the
  requirement in [ADR 007](007-plans-as-orchestration.md) that delegation and
  steering go through a whole Plan value. Their reliability contracts survive
  as listed below. [ADR 006](006-monitors-typed-triggers.md) retains its trigger
  and occurrence contracts; new elaborated continuations admit tasks.
- Date: 2026-09-05.
- Review baseline: `c53b95a`, version `0.17.3`. The baseline table below describes
  the pre-change implementation. The implementation section describes this
  working-tree candidate, not an already deployed release.

## Context

ADR 002's product hypothesis has failed for Max: requiring the model to author
a restricted executable plan has not established enough practical value to
justify continuing that route. This is a decision to stop investing in that
hypothesis, not a proof that every typed workflow language is ineffective.
The durable runtime built underneath it remains useful.

ADR 007 corrected the motivation from static verification to delegation,
context isolation, and steering, but kept the expensive authoring contract:
learn a dialect, choose schemas and detailed budgets, write the combining
expression before seeing results, and rewrite the whole plan to change work.
Completing more of the language is no longer the default next step.

### What exists, and what the evidence does not establish

The current checkout has real implementations, not just an unconnected IR:

| Area | Baseline evidence | Boundary |
|---|---|---|
| Plan admission, execution, and storage | [Max.Tools.Plan](../../src/Max/Tools/Plan.hs), [Max.DB.Plan](../../src/Max/DB/Plan.hs) | Existing plan tools remain active until migrated. |
| Fork dispatch, cancellation, checkpoints, and wake admission | [Max.Plan.Worker](../../src/Max/Plan/Worker.hs), [Max.Handler](../../src/Max/Handler.hs) | These mechanisms are assets to reuse, not a reason to preserve the DSL. |
| Ordinary `Hole` and `Bind` | `Execute.walk` stops; `Tools.Plan.settle` abandons an unparked plan | The guide's fill-and-continue language exceeds the shipped continuation path. |
| Browser and sandbox delegation | `Plan.Catalog.childReachableEffects`, `Tools.Plan.planGoalFor`, `Plan.Validate.narrows` | Child capability mappings exist, but ordinary root goals derive effects from the read-only plannable catalog and grant only `CurrentConversation`; requested browser/sandbox authority is rejected before child dispatch. |
| Budget and acceptance | `Tools.Plan.planGoalFor`, `planValidationEnv`, `Handler.dispatchChild` | The root uses four calls and a 60-second wall-clock parameter; production verifiers are empty. Child calls and elapsed time have runtime enforcement; the declared token field is not an implemented cumulative LLM-spend guarantee. |
| Plan evaluation | [plan-eval](../../plan-eval/README.md), [Harness.judge](../../plan-eval/Harness.hs), [Live.ask](../../plan-eval/Live.hs) | Candidate parse/admission rates and return-shape probes are not comparative end-to-end task-success measurements. |
| Monitors | [Max.Monitor](../../src/Max/Monitor.hs), [Max.DB.Monitor](../../src/Max/DB/Monitor.hs) | Typed observations already admit durable occurrences and ordinary turns without a Plan DSL. |
| Busy-conversation handling | `Handler.tryAbsorbIntoRunningTurn`, [Max.Tasks](../../src/Max/Tasks.hs) | Exact reply routing exists; same-author/latest-turn absorption and deferral are not a durable task coordinator. Inbox ownership is process-local even though source messages are durable. |

These are source-inspection findings, not newly executed production probes or
benchmarks. The [2026-09-05 operations record](../runbooks/adr003-cutover.md)
also reports a non-green production verification gate. This ADR neither repairs
that state nor declares it healthy.

## Decision

**The runtime makes work reliable; the model decides how to do it.** Ordinary
tool calling remains the default. Delegation exposes addressable tasks, not a
mandatory workflow language. One conversation coordinator handles dialogue;
multiple bounded tasks may work concurrently behind it.

### Retire the authoring programme, preserve the execution contracts

| Previous decision | Disposition |
|---|---|
| Partial-plan elaboration as the general agent execution model | Retired as Max's development direction. |
| Model-authored DSL, ordinary hole filling, adaptive horizon, additional join/watch syntax | No further expansion as the default roadmap. Keep compatibility code only while existing work needs it. |
| Write a deterministic combining expression before delegating | Retired. Model synthesis after results is legitimate work, not a failed join. |
| Whole-plan rewrite and whole-Goal hash as the only steering mechanism | Replaced by stable task identity, specification revisions, and addressed events. Hashes remain useful fingerprints, not task identities. |
| Journal, normalized outcomes, scoped result handles and artifacts | Retained. Results must keep provenance, retrieval bounds, and scope checks. |
| Durable admission, parent/child provenance, checkpoints, cancellation, leases and fencing | Retained; share these mechanisms with the new task surface. |
| Runtime capability narrowing and execution-time authorization | Retained. Schemas, prompts, and model-written code do not grant authority. |
| Distinguishing candidate output from verified completion | Retained. A schema validates shape, not whether the task was accomplished. |
| Generic verifier framework and schema coverage for every tool | Not prerequisites for useful delegation. Add task-specific checks where they demonstrate value. |
| ADR 006 typed triggers, occurrence deduplication, bounds and revalidation | Retained; no Plan-language dependency is required. |

Old ADR bodies remain historical records. Their statements that a tool-based
agent cannot be steered, that post-fork synthesis wastes the fork, or that more
language features are the next milestones are superseded by this decision.
Immutable call history can describe operations on mutable, versioned tasks;
editing history was never necessary for steering.

### Tasks outlive turns; identity is not a description hash

A **task** is an addressable unit of work with an objective, owning principal,
conversation scope, origin, optional parent, input references, authority ceiling,
budget, specification revision, status, and result references. A **turn** is
one execution of the existing agent loop advancing that work. A task may need
several turns or wait without a running process. A quick conversational answer
does not need a separate background task.

Task IDs are host-allocated and stable across restart and rewording. Do not
reuse `Max.Tasks.TaskId`, whose counter resets on restart, as this identity;
existing durable `t#` turn and `m#` monitor handles keep their meanings.
The public task-handle spelling is an implementation choice, not a new DSL.

The initial model-facing operations have these semantics; names are illustrative:

| Operation | Contract |
|---|---|
| `task_start` | Provide objective, bounded inputs/resource handles, a host-defined capability profile, and optional result shape. Return after durable admission with a task handle, not after completion. |
| `task_status` / `task_list` | Return compact, scoped progress and results. Completion events are the normal wakeup; status calls are not a polling requirement. |
| `task_steer` | Append an attributed note to the addressed task. Acknowledgement means durably queued, not already acted upon. |
| `task_replace` | Change the specification under compare-and-set, invalidate the previous execution generation, and preserve earlier evidence. Changed work is explicit rather than inferred from text similarity. |
| `task_cancel` | Record cancellation and fence subsequent effects/results; signal any live executor without waiting for a model. |

Further questions can continue retained task context with another turn; a
completed attempt is never rewritten into an uncompleted one. New attempts and
specification changes are journaled. Waiting for input, budget exhaustion,
partial results, cancellation, failure, and success remain distinguishable.
A request being read or a model returning prose is not a success condition.

The default result is a bounded report of status, findings, evidence/artifact
references, and unresolved issues. Task-specific structured payloads are optional.
The parent may inspect evidence, ask a retained child another question, or use
another model turn to synthesize results. Large raw output does not enter the
conversation frontend unless explicitly retrieved within its scope and budget.

### Authority and budgets belong to the host

Separate the catalog for **inline execution** from the grants available for
**delegation**. A tool need not have a Plan result schema to be usable by an
agent child. Every grant is still bounded by the initiating authority, current
policy, and the requested capability profile. A missing or changed grant fails
closed; the model gets a clear report of the effective capabilities.

Children receive explicit context, scoped inputs, and selected skill metadata,
not the whole conversation by accident. Task execution retains an independent
browser/session scope; shared writable files or sandboxes require resource-local
ownership or serialization, not a conversation-wide execution lock. Neither a
child result nor a monitor event becomes a privileged instruction to the
frontend. Follow-on effects must remain associated with an authorized task or
new user request; the frontend's broader tools cannot launder a narrower grant.

Host profiles provide useful defaults instead of asking the model to guess
calls, tokens, milliseconds, and effect algebra. Limits apply across descendants
and recovery. Admission accounts for outstanding reservations as well as settled
usage, so parallel children cannot each spend the same remaining allowance.
Tool-call count, LLM token/cost accounting, elapsed deadline, active execution
time, and pure-expression fuel must have distinct names and meanings. State
which limits are enforced and which are observational; unknown provider usage
is not zero. Limits stop or suspend work, never certify success.

This is bounded delegation of ordinary requests, not consent to an immortal
autonomous goal. Continuing work beyond its original scope, schedule, or budget
requires an explicit user action or already-authorized host policy.

### One conversation frontend, concurrent background work

The frontend is a **logical coordinator per canonical conversation**, including
its mirrored endpoints. It need not be a permanently resident model process.
Only one fenced frontend activation may own dialogue decisions and unrestricted
agent-authored conversation publication at a time. Other conversations remain
independent.

```text
canonical messages       monitor occurrences       task events
        |                         |                      |
        +----------- durable admission/routing ---------+
                         |                 |
              conversation frontend     addressed task inbox
                         |                 |
                         +---- bounded tasks (parallel)
                         |                 |
                         +<--- results / questions
                         |
                 recorded publication
                         |
                 per-endpoint outboxes
```

The frontend answers cheap questions directly and delegates long research,
browser, sandbox, or media work. It then releases its activation: **one
frontend does not mean holding a conversation slot until all its tasks finish**.
Inline work is bounded; the implementation must measure interactive latency
and provide a yield/delegation boundary rather than rely on politeness in a
prompt. Cancellation and authority revocation bypass model scheduling.

Background tasks publish progress, questions, and completion events to their
owner, not independent free-form replies to the room. Nested task results reach
the parent task first; a root task's user-facing outcome reaches the frontend.
Explicitly authorized canned reminders may publish without a model, through the
same recorded-output boundary. Physical delivery continues independently per
endpoint; this design does not introduce a global send lock or undo a prefix
already published to users.

Before admitting further output, check task revision, cancellation, and the
frontend ownership fence. A changed task's late result may be archived but must
not answer as the current version. Newly arrived messages are handled at bounded
decision boundaries; they do not require cancelling every in-progress model
response or regenerating already-visible text.

### Durable routing records obligations, not just messages

Keep canonical message bodies in the existing ledger. Persist task assignment,
event identity, author, source reference, ordering, processing position, and
disposition separately. Database state is authoritative; notification bells
only wake workers. An event acknowledged before its intended consequence commits
must remain recoverable. Task creation and its source-event assignment must
commit atomically or converge through a unique admission key.

Reading a user request is not resolving it. Each admitted request remains
pending, awaiting clarification, delegated to an identifiable task, answered, or
explicitly declined/cancelled with a reason. Delegation transfers the obligation;
it does not erase it. Silence may be appropriate for ambient conversation or
monitor observations, but cannot silently discharge an explicit user request.

| Input | Routing rule |
|---|---|
| Explicit task handle or reply to a task-linked output | Address that task, preserving principal and message provenance; addressing does not itself authorize mutation. |
| Authorized explicit cancellation/revocation | Durable control operation first, then executor notification; no model round required. |
| An unaddressed direct question | Frontend decides whether to answer, create work, or attach it. Same author/latest running task is evidence, not an automatic assignment. |
| Ambiguous destructive change | Ask which task/change was intended; do not guess and cancel unrelated work. |
| Ambient group conversation | Record normally; the existing participation policy may choose not to wake a model. |
| Task result or monitor observation | Deliver a bounded attributed event to its owner, not a synthetic user command. |

The task initiator and authorized administrators may cancel or replace work
under host policy. Other participants may supply evidence or suggestions without
gaining those powers. Cross-conversation addressing fails closed. Sibling
messaging is not needed in the first slice; parent/child inboxes provide the
useful feedback path without adding a broadcast mesh.

Reserve capacity for interactive frontend work. Limit background concurrency
globally, per conversation, and per initiating principal; use fair scheduling
and deadlines so one busy user or recurring monitor cannot starve others.
Coalesce redundant progress notifications, not unanswered user requests.
User-requested timed reminders retain their deadline semantics rather than
being treated as disposable proactive chatter.

### Monitors create occurrences; occurrences create tasks

Retain three distinct durable objects:

| Object | Meaning |
|---|---|
| Monitor definition | A versioned standing rule: owner, scope, trigger, objective/template, authority, lifetime and overlap policy. |
| Occurrence (`monitor_fire`) | One observed cause with its deduplication key, definition revision, evidence, and admission disposition. |
| Task | The work admitted for that occurrence, executed by the same runtime as user-delegated work. |

A monitor has no sleeping model, suspended call stack, or hidden Plan hole.
At fire time, revalidate the owner's standing and intersect the recorded ceiling
with current policy. Create at most one logical task per admitted occurrence;
link it transactionally or through an idempotent admission key. Recovery finds
that task rather than making another. The next turn works from current context
and recorded trigger evidence, not an assumption that the world stood still.

Keep `TimeCron`, live-only `LedgerMatch`, cooldowns, TTL/fire caps, durable
group budgets, and the canned/elaborated distinction. A fixed reminder goes
straight to recorded delivery. An elaborated fire admits background work;
triggering does not itself require a message to the room. Task completion and
dependency wakeups use task events, not ledger polling or new external probes.

For elaborated monitors, default to one active task per definition and at most
one coalesced pending activation. Preserve occurrence evidence and record which
events were coalesced; do not erase their history. A definition requiring every
event must explicitly choose a bounded queue with visible overflow/backpressure.
For interval/cron observations, missed ticks coalesce by default instead of
starting an unbounded catch-up storm. Fixed user reminders keep their explicit
delivery contract and are not silently folded into this observation policy.

Definition updates use revisions and affect future occurrences. Each occurrence
keeps the rule revision that admitted it; pending old-revision work is explicitly
retained or cancelled, never silently reinterpreted. Cancelling a monitor stops
future and unadmitted work. Cancelling its already-admitted tasks is an explicit
additional operation; expose that distinction in both tools and the admin view.
Neither operation promises to retract an external effect already committed.

Failures consume bounded retries and back off; ambiguous effects are reconciled,
not repeated as fresh tasks. Operators and authorized users must be able to see
definition state, last/next fire, active task, coalesced work, failure reason,
and fire history. Change-only notification and bounded failure notices prevent
recurring work from becoming recurring noise.

`ExternalPoll` stays deferred. If demanded by a concrete task, implement a
host-managed probe with constrained destinations/redirects, explicit credential
authority, interval floor, cost limits, and an observation record. Retiring the
Plan DSL does not authorize arbitrary code as an always-running trigger.

### Share reliability machinery, not every domain state machine

Reuse the existing execution journal, tool authorization, turn lifecycle,
artifact resolver, worker supervision, lease/fencing, and outbox boundaries.
Tasks, monitors, and deliveries retain their own domain states; the common
contracts are admission, attributed events, ownership, cancellation, and recovery.
No second agent loop or competing execution scheduler is introduced for tasks.

Exactly-once logical admission does not imply exactly-once external effects.
Keep reservations, attempt identity, idempotency where the target supports it,
and `outcome_unknown` where it does not. A stale lease owner cannot publish,
complete, spend new authority, or overwrite a newer attempt. Cancellation stops
future authorized work; it is not a rollback guarantee for effects in flight.

Durable continuation means another turn reconstructing authorized context from
journal and task state. It does not mean serializing an arbitrary Python/JS
stack, retaining process memory across crash, or blindly replaying scripts.

## Migration and validation

The user chose **one coordinated production switch**, not incremental
production migrations. This changes release sequencing, not the safety gates.
No deployment, destructive cleanup, or Git commit is implied by implementation.

| Implemented boundary | Location / contract |
|---|---|
| Durable identity and inbox | Migration `087_durable_tasks.sql`; `Max.DB.Task`. Host `task#` IDs, unique source/key admission, specification revisions, attributed events, distinct attempt turns and bounded journal reconstruction. |
| Model surface | `Max.Tools.Task`: start/status/list/steer/replace/cancel, plus background-only `task_finish`. Fixed bounded report schema initially; arbitrary task-specific schemas are not required. |
| Capabilities | `Max.Task.Types` filters effective host grants for research/browser/sandbox. No Plan result schema is needed. Child grants are intersected again with current definitions on execution; no conversation-send tools are granted. |
| Shared execution | `Max.Handler` dispatches tasks through the existing Agent, TurnRuntime, journal, browser scope and finalizer. Task attempts are excluded from legacy turn recovery; expired attempts get new fenced turns, not blind script replay. |
| Budgets and scheduling | Tree-wide reservations: 40 tools, 80 agent-model rounds, ten-minute admission deadline; eight active background tasks globally, two per conversation/principal, fair principal ordering and maximum depth/retry bounds. Reservations survive crashes and replacement. Token/cost usage is observational, not an enforced spend ceiling; helper-model calls are not agent rounds. |
| Frontend | One database-fenced activation per canonical conversation, six inline tools and a 75-second activation deadline. Successful delegation yields immediately. New same-author questions are not absorbed. Addressed controls bypass the LLM. |
| Output | Background attempts cannot insert conversation output. Root reports get separate frontend activations; nested reports wake their parent. Stale task revisions/attempts and expired frontend ownership cannot publish. A failed/silent summary model falls back to a bounded, literal report through the same fenced boundary. |
| Monitors | New elaborated fires atomically link to tasks, retaining legacy admitted-turn readers. Research is the initial monitor task profile. Versioned snapshots, single-flight, coalescing or bounded queues, explicit old-pending policy, separate cancellation of admitted work, change-only notifications and bounded repeated failure notices. Canned reminders keep their existing outboxes. |
| Operator visibility | `task_status`, `monitor_history`, `configure_monitor`, `!task`, and the admin durable-work view expose state, provenance, outstanding requests, overlap and failures. |

The ordinary tool inventory no longer advertises Plan authoring. Its readers,
worker and restricted legacy-child tools remain for already stored work. The
ordinary-hole guide now states that it stops rather than fills and resumes;
the old `tokens` field is identified as expression fuel, not model usage.

The [cutover runbook](../runbooks/task-cutover.md) separates local deterministic
validation from the real-provider/browser/platform trials still required at the
joint switch. These tests do not establish answer quality or production health.
Comparative task-outcome evaluation remains useful evidence, not a reason to
keep expanding the retired Plan language.

Rollout gates must cover:

- **Interactive concurrency:** A starts a long investigation; B receives an
  answer to a simple question before A finishes; A's addressed correction
  reaches A's task. An unrelated second question from A remains distinct.
- **Routing and authority:** a participant's suggestion cannot cancel another
  person's task, and guessed task/monitor/artifact handles cannot widen scope.
- **Race and recovery:** restart after event commit but before dispatch; cancel
  versus completion; steer versus inbox consumption; frontend lease loss; a
  late result from a replaced generation. No obligation is silently lost and
  no stale attempt publishes as current.
- **Monitors:** overlapping fires, missed ticks, bounded queue overflow,
  rule updates, revocation, and cancellation with an already-active task.
  Existing live-versus-backfill, cooldown, and unique-admission tests still pass.
- **Effects and budgets:** descendant/reserved spend, cancellation with an
  external effect in flight, unknown usage, and unknown delivery outcomes.
  Recovery cannot mint fresh budget or replay an ambiguous send.
- **Outcomes:** roughly 20–30 representative tasks with repeated trials;
  assess answer quality/completeness, first-response and completion latency,
  total parent/child cost, context occupancy, and work wasted on steering.
  Set acceptance thresholds before comparing results. Plan invocation rate,
  parsing rate, and shape conformance are not task-success proxies.

Database integration and behavioral tests are required for implementation;
unit tests or Nix evaluation alone cannot validate leases, admissions, or
recovery. Preserve the repository's full build/test and prompt-flow release
gates. This document does not claim those future behavioral gates have run.

## Prior art and what is not being copied

Upstream documentation consulted on 2026-09-05 describes interfaces and design
choices, not performance measurements made in this repository:

- [Pi Fabric architecture](https://github.com/monotykamary/pi-fabric/blob/main/docs/architecture.md)
  separates its TypeScript surface from host-owned tool effects and uses QuickJS
  isolation by default. Its [workflow example](https://github.com/monotykamary/pi-fabric/blob/main/skills/fabric-workflow/SKILL.md)
  demonstrates bounded fan-out, later verification/synthesis, partial outcomes,
  and retrying failed items rather than the entire workflow. The useful lesson
  is composable work with explicit boundaries, not a requirement to adopt its
  mesh or component system.
- [Prime Agent's RLM model](https://github.com/PrimeIntellect-ai/prime-agent/blob/main/packages/coding-agent/docs/rlm.md)
  separates model-facing programmatic state from host-owned child lifecycles;
  its documented child call returns an admission handle, with replies through
  messages or files. Its [long-running model](https://github.com/PrimeIntellect-ai/prime-agent/blob/main/packages/coding-agent/docs/long-running-agents.md)
  distinguishes goals, continuation policy, schedules, and communication.
  Persistent addressability is useful without a prewritten combining term.
  Its Python environment is explicitly not a security sandbox; Max must not
  copy ambient OS authority into an untrusted group-chat setting.

A restricted code-mode tool may later help with deterministic filtering and
aggregation. It is a separate, measured experiment, not a prerequisite for this
ADR. Any such tool must keep effects behind Max's host authorization/journal,
bound execution and output, and preserve partial-effect evidence on failure.

## Consequences and rejected alternatives

The model-facing surface becomes smaller while the host retains real
responsibilities: routing obligations, ownership, budget accounting, and
publication ordering. There may be an extra synthesis turn and less static
knowledge about the whole workflow. These are acceptable costs when they improve
actual answers and responsiveness; they must be measured rather than assumed.

- **Finish the hole elaborator first:** rejected. It extends the failed product
  hypothesis before measuring a simpler task interface.
- **Replace all durability with a REPL or subprocess:** rejected. Process
  lifetime and persistent variables do not provide scoped admission, delivery
  reconciliation, or fenced recovery.
- **Serialize every task in a group:** rejected. Only dialogue coordination is
  single-owner; slow work must not make the conversation unavailable.
- **Let every message or monitor spawn an independent speaking agent:** rejected.
  Parallel execution is useful; competing unsynchronized conversation owners
  are not.
- **Use an intent classifier to silently merge or discard explicit questions:**
  rejected. Routing hints do not discharge an obligation or grant authority.
- **Build a universal scheduler/state table:** rejected. Share lifecycle
  primitives and events while keeping task, monitor, and delivery semantics
  distinct.
- **Delete existing plan rows or restart them through the new API:** rejected.
  History, active work, and ambiguous effects are migration obligations, not
  expendable implementation details.
