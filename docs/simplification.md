# Runtime simplification

Implementation of the agreed September 19 plan. Baseline: `b9d3e34`.
The runtime migration has shipped, but the full plan is not complete. The
checklist records delivered changes; the numbered status below also tracks
unfinished design and acceptance goals.

## Status against the original numbered plan

Sections 7–8 include the monitor cutover below. Section 13 separates resource
ownership from dispatch work and makes loop state/outcomes explicit. These
changes are deployed on h610; earlier deployment evidence remains historical.

| Plan section | Status | Remaining work or limit |
|---|---|---|
| 1. Core-size goal | Measurement established; target unmet | The measured core is 33,725 effective lines including active SQL. |
| 2. Product contract | Main runtime contract implemented | Major features and conservative handling of uncertain effects remain. |
| 3. Responsibility boundary | Implemented | File and schema manifests expose core and total maintenance cost. |
| 4. Model responsibilities | Partial | Finish/disposition protocols are gone; prompt reduction and monitor observation contracts still need review. |
| 5. Runtime path | Implemented | Conversation, Agent and Jobs own live execution; dispatch preparation, execution and publication are named steps. |
| 6. Runtime boundaries | Implemented with regression coverage | Streaming, cancellation, provider state and resource boundaries have tests; live acceptance does not cover every case. |
| 7. Persistence scope | Implemented | Definitions and trigger facts remain; worker leases, retry state and crash replay are gone. Frozen definitions preserve pending-retention and authority semantics. |
| 8. Removal candidates | Implemented | Reminder triggers feed ordinary Jobs; old runtime tables have no serving-code consumers. Obsolete debt views and lease helpers are removed. |
| 9. Core responsibility budgets | Not reached | Core Haskell is 31,978 lines, plus 1,747 active SQL lines. Preserve major features when pursuing further reductions. |
| 10. Migration sequence | Runtime cutover shipped; phase F partial | Cleanup and budget/readability goals remain after the deployed A–E changes. |
| 11. Acceptance | Substantial but incomplete | Build, regression, upgrade and selected live checks passed. Model comparison was small; real-chat Jobs/reminder cases were not all exercised and strict historical health remains non-green. |
| 12. Worker architecture | Main changes implemented | Scoped service supervision, local Jobs and queues replace the old execution recovery machinery; monitor scheduling now uses the same no-replay restart contract. |
| 13. Readability | Implemented | Named LoopState/capabilities/SQL decoding, explicit outcomes, one production tool interpreter and separate dispatch ownership. |

Further size or prompt work must preserve major features. The remaining budget
and broader model/real-conversation acceptance goals are separate from this
monitor and readability cutover. Counts and evidence are in
[code-size.md](code-size.md) and the
[deployment report](research/simplification-7-8-13-release-20260919.md).

## Product contract

- Preserve major user-facing features. The line-count goal never justifies
  removing platforms, background jobs, reminders, memory/search, media/files,
  browser/sandbox, static skills or raw code mode. Replace their implementation
  where useful; retain the feature and its authorization boundaries.
- A normal final assistant response ends a turn. Tool calls continue the loop.
  Remove model-authored finish, disposition, revision and recovery protocols.
- Publish safe text fragments before the model finishes. Retain a published
  prefix on interruption and flush the final tail exactly once.
- Keep foreground chat, explicit background jobs, status, feedback, cancellation,
  deadlines, bounded concurrency and child tasks within the running process.
- Restart interrupts running work; never resume or replay it. Keep chat history,
  long-term memory, reminder definitions, user files and retained browser profiles.
- An ambiguous external effect is not automatically retried.
- Configuration changes take effect on restart. Keep a bounded shutdown drain.
- Preserve platform adapters, media, search, browser/sandbox isolation, scoped
  authorization, native identities/references and inbound deduplication.
- Retire tests for removed implementations and consolidate duplicate coverage.
  Keep distinct behavioral cases and upgrade checks; test counts are not a goal.
- Keep PostgreSQL and the existing transport implementations. No permanent
  durable/non-durable modes or replacement workflow framework.

## Execution and ownership

Platform ingress persists history, then queues conversation input. Each active
conversation owns its foreground Agent. Independent input queues for the next
turn; explicit feedback can reach the active turn at a safe boundary. Preserve
author and reply provenance without asking the model to settle message IDs.

Jobs own explicitly detached background work; finishing its initiating reply
does not cancel it. A job owns its ordinary children and cancels them on exit.
Agent and Jobs share the same tool execution and capability boundaries.

Use scoped `Async`, `bracket` and STM for local lifetime and cancellation.
Queues and actual scarce resources have limits; a parent awaiting children
must not hold their last available resource slot. Control/cancellation remains
responsive while the LLM runs. Senders serialize by destination and retain
current-run progress. No restart outbox recovery.

Maintenance scans business data that needs work. Reminder definitions and
minimal trigger markers remain persistent; executing a reminder uses Jobs.

## Migration checklist

### A. Baseline and reviewability

- [x] Audit the current source and publish the full simplification design.
- [x] Count a clean snapshot: src + app = 52,627 effective Haskell code lines.
- [x] Clean prose comments and correct stale descriptions without changing code.
- [x] Keep representative behavioral fixtures and define the Haskell core file
      manifest in `docs/code-scope.json`; validate it with `scripts/count-code.py`.
- [x] Add active SQL/schema and prompt-size accounting to final measurements.
- [x] Remove whole-source-hash model certificates as generic CI blockers while
      retaining relevant deterministic and model-level evaluation.

### B. Foreground conversation

- [x] Remove model-facing `request_finish` and per-input dispositions.
- [x] Remove frontend request ledgers.
- [x] Replace frontend SQL ownership/leases with a bounded conversation queue.
- [x] Normal text ends the loop; failures/truncation/cancellation remain distinct.
- [x] Publish paragraphs and plain-prose fragments incrementally.
- [x] Bound retained stream buffers and validate publication through the full
      SSE/transport path before EOS.
- [x] Update prompts, tools, handlers, output accounting and fixtures together.
- [x] Preserve live provider tool-call/reasoning state within a model loop.

### C. Jobs and application lifetime

- [x] Replace durable tasks/attempts/revisions/leases with scoped in-process Jobs.
- [x] Keep start/status/list/cancel/feedback, budgets and child result collection.
- [x] Remove model-supplied idempotency keys and ordinary task-finish reports.
      Keep structured results only when a caller explicitly requires a contract.
- [x] Remove restart turn recovery and durable joins.
- [x] Remove execution admission journals; retain bounded diagnostic results.
- [x] Remove task browser checkpoint/restore; retain explicitly saved profiles.
- [x] Remove configuration generations/hot reload; simplify startup and shutdown.
- [x] Route reminders through Jobs and preserve minimal trigger deduplication.
- [x] Reduce the remaining monitor claim/lease and definition protocol to the
      business state needed for scheduling, deduplication and frozen authority.

### D. Publication and maintenance

- [x] Replace durable inbound dispatch execution with a bounded local queue.
- [x] Replace durable outbox execution with bounded local queues.
- [x] Keep platform receipts, reference mappings, current-run deduplication and
      conservative handling of uncertain sends.
- [x] Replace embedding maintenance leases with a process-local lock and
      missing-data scans; keep source/version-conditional writes.
- [x] Replace media leases and serialized jobs with bounded local queues and
      missing-data scans; preserve canonical attachments and forward expansion.
- [x] Replace Historian maintenance leases with local scheduling and
      missing-data scans; preserve short transactional publication.
- [x] Delete notification LLM review pipelines and operational debt review.
- [x] Separate connection retries, individual task failures and fatal core errors.

### E. Context and optional machinery

- [x] Delete task-experience generation, replay, publication and maintenance
      commands. Retain old rows as data without loading learned instructions.
- [x] Delete the online skill factory and certificates; retain static lazy skills.
- [x] Keep useful raw code mode on the shared tool boundary, without durable
      workflow state or a second authorization/execution path.
- [x] Delete model-driven memory dreaming; retain deterministic processing of
      recorded expiry dates without leases.
- [x] Delete cross-turn raw wire archive replay.
- [x] Simplify context to recent messages, one sourced summary representation
      and relevant scoped memory; retain history search/expansion and token limits.
- [x] Replace persistent materialization/CAS traces with derived in-memory state
      and optional sampled diagnostics.

### F. Removal and acceptance

- [x] Delete unused modules, effects, configuration, SQL, admin surfaces and
      tests belonging to removed behavior. Preserve historical migrations.
- [x] Stop using old execution tables before archiving/dropping them; retain
      business history and provide an upgrade path from the existing database.
- [x] Make ordinary chat/tool/cancellation paths directly readable. Use named
      fields, explicit results and locally understandable resource ownership.
- [x] Update architecture, feature, operations and generated prompt documentation.
- [x] Publish the release's core and total-owned-code measurements with a file manifest.
- [x] Complete local gates, upgrade checks, release and the recorded operational probes.
- [ ] Complete the remaining representative model and real-conversation
      acceptance cases; retain historical health failures as evidence.

## Monitor persistence boundary

One required scheduler reads new trigger markers. SQL keeps their deduplication,
calendar position, input payload, authority and result; it does not elect workers
or retry deliveries. Startup ends unfinished triggers before accepting ingress.
A canned reminder consumes its calendar edge before publication, so a crash can
lose that occurrence but cannot resend it. Recurring definitions retain their
next date. Role checks, overlap bounds, HTTP idempotency and cancellation remain.

Frozen definitions are business inputs: `configure_monitor` can retain already
accepted triggers, which must keep their original goal, profile and grants.
The old partial-snapshot restoration path is removed. The startup sweep leaves legacy completed records alone, even when they lack
modern completion timestamps or receipts. Migration 124 removes
lease/retry columns and obsolete debt views without rewriting definitions,
messages or trigger evidence. Historical execution tables remain archived data;
a source audit finds no runtime SQL reading them.

## Readability boundary

`forkDispatch` owns registration and cleanup; `runDispatch` handles chat, Jobs
and notices. Chat is `prepareReply → runReply → publishReply`. These are local
steps, without a new workflow abstraction. `LoopState` contains only changing
round data; immutable dependencies stay in the enclosing run. `AgentOutcome`
makes complete, interrupted and failed runs distinct, including already
published text. Jobs accept only complete answers; foreground interruption
publishes the remaining partial text and retains failure status.

Capability constructors name every switch and authority ceiling. `runToolsWith`
is the sole production interpreter; `runTools` is the plain static test assembly.
Long platform row decoders name each SQL field, including typed JSON readers.
BotEnv groups immutable startup settings and process resources; it has no second
mutable configuration snapshot. Runtime comments state current invariants;
architecture.md begins with entry points and ownership. Obsolete automatic
Agent-retry classification and its tests are removed; streaming, shared tool
execution, cancellation and database behavior fixtures remain.

## Size accounting

Count effective source lines with normal formatting. Core includes lifecycle,
conversation/Agent/Jobs, authorization and common tool execution, context/memory
policy, business queries and active schema, shared HTTP/SSE/model handling,
publication, reminder scheduling and application assembly. Moving business
decisions into adapters does not remove them from the core.

Exploratory budget: types 450; conversation/Agent 1,450; Jobs 650; tool policy 700;
context/memory 1,600; business storage/schema 1,300; shared model/HTTP 950;
publication 700; reminders 350; startup/config/logging 600. Total 8,750, with a
core aspiration below 10,000. This is neither an acceptance gate nor a reason
to remove useful features. If preserving them needs more code, report that
result and keep the features. Platform/provider wire adapters, concrete tools,
isolation runtimes, bridges and UI remain separately reported maintenance costs. Report tests,
historical migrations and prompt size separately; deleting comments does not
reduce effective code lines.

## Required evidence

- Normal answer, clarification and refusal end without a finish tool.
- Controlled SSE publishes before EOS; interrupted output does not repeat.
- Tool calls round-trip with their provider state and respect authority/budgets.
- Independent inputs queue without loss at the finish boundary; feedback and
  cancellation preserve provenance and remain responsive.
- Background work survives the initiating reply, supports status/cancel, and
  cannot deadlock while joining children.
- Restart does not execute old tasks or resend pending non-idempotent output.
- Scoped memory/search, source provenance, context bounds and reminders work.
- Existing-database upgrade retains user data. Stop the old process before
  starting the new runtime; rollback must not replay uncertain historical work.
- Compare representative old/new model flows for task completion, protocol
  correction, model calls, tokens and first-visible latency; report limits of
  the sample rather than inventing improvement percentages.
- Run appropriate unit/integration/architecture/build checks. Before every
  commit run `cabal run max-prompt-flow`, include its generated diff, then run
  `cabal run max-prompt-flow -- --check`.

Source audit and detailed design were originally recorded in
`/tmp/max-simplification-plan-2026-09-19.md`; this repository checklist is the
maintained implementation record.

## Implementation evidence

- Post-release review corrections: graceful shutdown includes queued and active
  deliveries, mirror copies and deterministic Job interruption notices in one
  drain deadline. Cancellation fences stale Job publishers; there is still no
  crash continuation or post-crash notification guarantee. Selected maintenance
  and optional ingress services recover synchronous failures with local backoff;
  core supervision and asynchronous cancellation retain fail-fast behaviour.
  README, platform/workflow docs and superseded ADR statuses now describe these
  boundaries. Local source embedding respects Git exclusions, including
  `.git/info/exclude`. Removed unused helpers after checking function callers.
  Tests cover more than one page of unavailable monitor checks, a later reminder,
  shutdown during active mirrored delivery, Job notice ownership races, and
  maintenance recovery without cancelling a sibling. Production acceptance of
  these review corrections is recorded separately from their local tests.

- Sections 7–8: `58523f4` removes monitor leases, persistent delivery retries,
  replay acknowledgement, partial-snapshot restoration and obsolete debt views.
  Populated migration 124 preserves definitions, messages and trigger facts.
- Live startup exposed a pre-existing role-check bug: unavailable platform
  metadata was treated as confirmed loss of administrator authority. Monitor
  revalidation retains the pending trigger and defers read-only checks in the
  running process. Deferred IDs are excluded before the batch limit, and
  circular pagination prevents unavailable older triggers starving newer ones.
  Rechecks wait at least five seconds locally, without sleeping in dispatch;
  there is no total attempt cap while a definition remains valid. Only a known
  insufficient role expires the definition.
  Ordinary permission checks still deny access when the role is unavailable.
- Section 13: all Cabal components build; 1,043 unit and 267 PostgreSQL examples
  pass; HLint and architecture capability checks pass. The removed 14 examples
  tested an Agent retry classifier with no production caller. Current source
  and active SQL total 33,725 core lines. Final code `1cd1132` passed all CI jobs
  and is deployed on h610. Native upgrade preservation, HTTP, sandbox, browser
  and existing scheduled-Job observations are recorded in the
  [release report](research/simplification-7-8-13-release-20260919.md), including
  the remaining historical health failures.


- `eb90b84`: comment-only cleanup across 70 modules; 1,586 fewer full-line
  comments. Raw and formatted executable text match the baseline; library
  build, HLint and generated prompt-flow checks passed.
- The foreground protocol change retains the existing SQL coordinator
  temporarily. Host settlement covers observed feedback; independent requests
  queue separately. Replacing SQL ownership and removing ledgers remains open.
- Foreground protocol validation: 1,105 unit examples and 406 PostgreSQL
  integration examples passed. Architecture capability checks passed. The
  integration cases include final-publication/input races, independent-input
  separation, feedback provenance, cancellation and publication failure.
- Streaming validation: 1,110 unit examples passed. A controlled model
  callback asserts publication before returning the final response and checks
  that repeated cumulative text does not republish the accepted prefix. This
  does not yet establish live QQ first-visible latency.
- Task-experience removal: all Cabal targets build; 1,105 unit examples pass.
  The DB run passed 402 of 403 cases; its new preservation fixture used the
  wrong conversation ID. After correcting that fixture, all 28 matched
  persistence cases pass. Offline context checks pass (9 Historian, 7 recall).
  Architecture checks, HLint and `cabal check` pass.
- CI validates stored model reports without treating current whole-file hashes
  as release certificates. Existing reports pass; a deliberately failed sample
  is still rejected. Historical source/model identities remain in reports.
- Memory-dream removal: all Cabal targets build; 1,105 unit and 398 DB
  integration examples pass. Expiry coverage retains future dates, checks
  version/citation changes, rejects permanent-memory expiry and applies due
  records once. No model calls or persistent execution leases are involved.
- Online skill-factory removal: all Cabal targets build; 1,095 unit and 388 DB
  integration examples pass. Retired generated instructions stay in storage and
  are excluded from loading; static skill workflows still use current tool
  contracts and the shared executor. Architecture checks, HLint, Cabal package
  checks and Nix syntax validation pass.
- Direct task notices: 1,092 unit and 376 DB integration examples pass, as
  do the task-upgrade fixture and capability checks. Progress and results now
  publish through the existing resolver without a second model or JSON review.
  Current-version, cancellation, foreground-priority and duplicate-output
  guards remain. Old skipped notices stay ineligible after migration 114.
- Operational debt export/review was removed. Health reports raw terminal
  failure counts; historical acknowledgements no longer suppress failures.
  Old audit data is retained. Full in-process runtime cutover is still pending.
- Cross-turn replay removal: all Cabal targets build; 1,075 unit and 372 DB
  examples pass, as do architecture checks and offline context fixtures
  (9 Historian, 7 recall). The Agent fixture asserts that opaque provider
  reasoning survives into the next tool round unchanged. Reply continuations
  still resolve scoped digests; completed turns no longer capture wire blobs.
- Intermediate source count: src + app = 50,330 effective Haskell lines, down
  2,297 from the baseline. This excludes comment-only savings and is a total
  source count, not a claim that the core target has been reached.

- Static process configuration: all Cabal targets build; 1,058 unit and 372 DB
  integration examples pass. Removed configuration generations, leases, the
  reload socket/CLI and worker handoff. Tools receive context limits rather than
  a model catalog; log filtering uses the normal effect interpreter. Capability
  checks, HLint and package checks pass. Nix syntax and the configuration-restart
  VM derivation evaluate successfully; the VM has not been run on this macOS host.

- Streaming reception now caps the entire SSE response at 16 MiB, including
  incomplete frames and opaque provider state. Oversized responses are never
  retried; a received prefix remains available as interrupted output. A gated
  provider fixture runs through HTTP/SSE, Agent, canonical publication, the
  delivery worker and the QQ adapter: its first native send happens before
  provider EOS, and the final tail is sent once. This is local transport
  acceptance, not a measurement of live QQ latency.
  Regression: 1,060 unit examples and 373 PostgreSQL integration examples pass;
  the bounded-stream cases also verify socket closure and no automatic retry.

- Embedding maintenance: removed persistent leases, heartbeat/fencing queries
  and their admin status view. One cancellation-safe process lock coordinates
  batches and explicit reindexing; sleeps do not hold it. Missing-data scans,
  scoped invalidation and source/version checks remain. All Cabal targets build;
  1,061 unit and 370 DB examples pass, including cancellation, overlapping
  reindex, stale content and archived-memory writes. Capability checks and HLint
  pass. Historical lease tables remain unused rather than deleting old data.
- Intermediate src + app count is now 49,258 effective Haskell lines, 3,369
  below baseline. The core manifest was added in the following step.

- Responsibility accounting now covers every src/app Haskell file explicitly.
  The current core Haskell component is 36,083 lines; active SQL is additional.
  The report in `docs/code-size.md` keeps adapters, concrete tools, isolation,
  admin, other production code, tests, developer tools and migration history
  visible separately. The core target remains unmet.

- Comment follow-up: 36 Haskell modules have 531 fewer full-line comments.
  Non-comment source text is unchanged. Removed stale replay descriptions,
  misplaced roster documentation and obsolete incident narratives; retained
  protocol, identity, cancellation and authorization constraints. All Cabal
  targets build and HLint passes. The line-count aspiration is explicitly
  subordinate to preserving major features and readability.

- Test cleanup: consolidated token round-trip examples and browser concurrency
  setup while retaining each input and ownership scenario. Removed a duplicate
  WeChat quote assertion and the fixed tool-limit constant assertion; deadline
  relationships remain checked with startup configuration. JSON codec tests
  remain because recorded-request evaluation uses them. All Cabal targets build;
  1,058 unit examples, capability checks, HLint and package checks pass.
  Source counting now also handles deleted, unstaged files.

- Foreground ownership now uses a bounded STM queue: 256 tickets per conversation,
  1,024 per process. Ordinary inputs retain their admitted eligibility and run
  separately; owner feedback preserves canonical author, reply and ingestion
  order. Unread feedback becomes a later turn at the completion boundary.
  Foreground requests precede queued notices; commands bypass the queue.
- Removed production use of frontend leases, request ledgers, SQL inboxes and
  foreground restart continuation. Historical tables stay intact; migration 115
  preserves the output scope, terminal-state and task-notice guards. Cancellation
  revokes local publication authority before signalling the worker. Short ingress
  claims settle at queue admission, without a model-length lease heartbeat.
  Background task and transport persistence are still pending their own cutover.
- Foreground validation: all Cabal targets build; 1,066 unit examples and 349
  PostgreSQL integration examples pass. Queue fixtures cover canonical feedback
  provenance/order, cancellation, capacity, notice priority and 100 concurrent
  finish/admission races. Publication fixtures retain a committed prefix while
  rejecting sends after cancellation or runtime removal. Migration upgrade,
  architecture capability, HLint and package checks pass.
  The intermediate src + app count is 48,656 effective Haskell lines (602 fewer
  in this step, 3,971 below baseline); core Haskell is 35,493, with active SQL
  still additional. This is a staged implementation, not final plan acceptance.

- Jobs now owns detached work, generations, feedback, child joins and shared root
  budgets in STM. Normal final text completes work; only explicit caller contracts
  require structured JSON. Removed the unused finish/yield tool-control protocol
  and its exclusive-batch machinery. Current-turn skill activation remains typed.
- Reminder definitions and occurrence snapshots remain persistent. Admission is
  once per occurrence, without task attempts or restart replay. Stable observations,
  failure-notice throttling, coalescing, cron advancement and explicit cancellation
  of admitted Jobs retain dedicated integration coverage.
- Browser sessions are process-local. Automatic task checkpoint/restore is gone;
  explicit owner-scoped encrypted profiles, frozen monitor bindings, uncertain
  action fencing, confirmed reset and clear-all revocation remain covered through
  the real MCP transport fixture. Migration 116 retires live historical execution
  and preserves user data and non-reusable public IDs.
- Jobs validation: all Cabal targets build; 1,050 unit examples and 274 PostgreSQL
  examples pass. Removed obsolete recovery/lease/report tests while retaining
  native/Wasm/JavaScript admission, cancellation, provenance and effect-boundary
  cases. The live-model comparison executable builds on Jobs, but no new live-model
  quality or performance result is claimed. Architecture, upgrade and HLint checks
  pass. Prompt/package gates are run before the commit.
- This intermediate step leaves 46,728 effective src/app Haskell lines (1,928
  fewer than the conversation checkpoint), with core Haskell at 33,596. Execution
  journals, publication/outbox queues, maintenance and context simplification
  remain; this is not completion of the full plan.

- Removed unused per-invocation identity plumbing and restart-only skill/working
  summary readers. Agent now builds one tool registry per model round; invocation
  and catalog reads use that same snapshot. Skill activation still takes effect
  at the next round, and saved workflows consume the actual in-memory activation
  receipt. Historical result handles and diagnostic manifests remain available.
  All targets build; 1,050 unit and 272 DB examples pass after retiring the two
  restoration tests. Capability checks pass.

- Execution admission now reserves Jobs budgets in memory. Result ordinals belong
  to the active turn; no `started` row, row lock or SQL maximum is required before
  invoking a tool. Completed results, scoped handles, artifact spill and trusted
  manifests remain. Diagnostic storage errors are logged without changing a
  completed outcome; interruptions record unknown outcomes when possible.
  Working summaries stay in the active loop; their unused SQL write path is gone.
  Migration 117 preserves unfinished historical effects as unknown and forbids
  new pre-effect rows. It does not resume or replay them.
  All Cabal targets build; 1,050 unit and 271 PostgreSQL examples pass, including
  cancellation with no pre-effect rows, native/Wasm result-write failure, parallel
  result identity, scoped result lookup and real workflow calls. Upgrade, capability
  and HLint checks pass. Retired the old started-row recovery/settlement cases.
  Effective src/app Haskell is 46,560 lines; core Haskell is 33,428. Publication,
  maintenance and context work remain before final acceptance.

- Inbound dispatch now uses one bounded STM queue shared by QQ, Matrix, iMessage
  and WeChat. Only freshly committed live messages enter it; source-native dedupe,
  history backfill, principal attribution and reply provenance remain in the store.
  Removed dispatch claims, retries, lease ownership, handoff dispositions and the
  duplicate canonical-message projection. Jobs and reminders use the same typed
  source reader. Migration 118 retires old pending work while preserving messages,
  terminal history and unknown effects; startup never scans historical dispatches.
  All Cabal targets build; 1,050 unit and 269 PostgreSQL examples pass. Replaced
  three dispatch lease/reclaim tests with fresh-only queue and restart behavior;
  retained source deduplication, corrupt-body, provenance and platform cases.
  Upgrade, capability and HLint checks pass. Effective src/app Haskell is 46,224
  lines; core Haskell is 33,098. Outbound and maintenance queues remain pending.

- Outbound copies now enter a bounded process queue after canonical commit.
  Per-platform workers serialize destination heads; delayed retries leave other
  destinations available. Removed SQL claims, reservations, lease renewal and
  worker wakeup triggers. Native reply/action lookup, part fingerprints, stable
  Matrix transactions, echo/status reconciliation and current-run part receipts
  remain. Provider failure may retry only output created in this process; startup
  closes old pending rows and retains uncertain sends without replaying them.
  Migration 119 preserves canonical history and confirmed part receipts.
  Retired six lease/SQL-lane tests, added four process-queue cases, an actual
  restart-boundary case and a provider-failure/settlement race. Native collision,
  media, platform and streaming cases remain. All targets build; 1,054 unit and
  265 DB examples pass, as do upgrade, capability and HLint checks. Obsolete
  dispatch/delivery drain gates no longer block the stopped-process migration.
  Effective src/app Haskell is 46,195 lines; core Haskell is 33,065. Media,
  Historian, context and final operational acceptance remain.

- Media downloads and forward expansion now use typed, bounded process queues.
  Removed SQL claims, lease renewal, serialized job codecs and obsolete queue
  drain gates. Live work takes priority over historical discovery; five local
  attempts and bounded deduplication keep failed sources from spinning. Startup
  and periodic scans derive missing work from canonical history and revisit late
  commits. Image/video/file metadata and completed forward expansions remain
  persistent; empty and partial forward responses stay distinguishable.
  Forwarded images now use canonical node positions, and image/sticker writes
  commit together. Admin media counters describe the current process.
  Migration 120 archives old job diagnostics without replaying their payloads.
  Retired ten lease/batch/restart tests, added four queue and five media cases;
  attachment isolation, HTTP downloads and empty-forward behavior are covered.
  All targets build; 1,058 unit and 260 DB examples pass, as do upgrade and
  capability checks. Effective src/app Haskell is 46,080 lines; core is 33,080
  (shared media types moved into the core queue module). Historian, context and
  final operational acceptance remain. No production deployment is claimed.

- Historian now reads a source range, generates once (plus the existing bounded
  schema repair), and publishes results in one source-checked transaction.
  Removed persistent enqueue/claim/lease/generated/retry transitions. Capture
  rows contain completed diagnostics, summaries and memory
  proposal outcomes; preparation only allocates a result ID. Local quiet timers
  retain bounded backoff, per-conversation ownership and token-sized catch-up.
  Capture badges count local retry waits; historical diagnostics remain readable.
  Manual rebuild requests share this scheduler; the old summary stays readable
  until replacement commits, and restart drops pending requests.
  Migration 121 retires interrupted captures while retaining source history and
  completed evidence. Retired two SQL claim/retry cases, moved delay policy
  coverage into the scheduler, and added bounded rebuild admission, deduplication,
  ownership and cross-conversation progress cases. Worker integration covers
  scheduled publication and admin rebuilds during a blocked model call.
  All targets build; 1,061 unit and 259 DB examples pass, as do upgrade,
  capability, HLint and offline checks (9 Historian, 7 recall fixtures).
  Effective src/app Haskell is 45,670 lines; core Haskell is 32,759. Context
  representation/materialization and final operational acceptance remain.

- Prompt assembly now reads current summaries and a bounded raw tail through
  the same collector used for previews. Removed materialization CAS, durable
  revisions/fingerprints, high/low-water transitions, persistent planning traces
  and their admin surfaces. New summary publications become visible on the next
  collection; source-gap selection, scoped history, pins, replies, media and
  exact final token checks remain. Trace-level logs sample body-free decisions;
  historical planning tables remain untouched and unused.
  Retired four obsolete/duplicate DB cases and replaced the high-water protocol
  case with real read-only prompt assembly, fresh-summary visibility and preview
  parity. All targets build; 1,061 unit and 255 DB examples pass, followed by all
  13 prompt DB cases after the read-only fixture cleanup. Upgrade, capability,
  HLint, package and offline context checks pass. Effective src/app Haskell is
  44,871 lines (799 fewer); core Haskell is 32,047. Three-level summaries, remaining
  worker failure handling and final operational acceptance are still pending.

- Historian now emits one summary with one citation list. Removed P1/P2/P3/P4
  fields and age/importance-based fidelity transitions from prompt assembly.
  The planner keeps a chronological summary suffix within one quarter of its
  prompt budget (at most 8,192 estimated tokens), then applies the existing
  complete-prompt limit with pins, replies, trigger and attachments protected.
  Scoped memories, history search and source expansion remain. Collection and
  selection now use one snapshot type instead of nested equivalent wrappers.
- Migration 122 merges distinct old summary texts and their citation union while
  retaining the original columns, evidence, source ranges, handles and messages.
  Only vectors whose text changed are invalidated. Lexical and vector recall
  now read the same summary; new captures do not write legacy tiers.
  All targets build; 1,062 unit and 255 DB examples pass, plus all 13 prompt DB
  cases after the snapshot type cleanup. Upgrade, capability, HLint and offline
  checks pass (9 synthetic and 4 historical Historian fixtures, 7 recall cases).
  These offline checks do not establish live-model quality. Effective src/app
  Haskell is 44,733 lines; core Haskell is 31,909. Worker error classification,
  remaining removal/readability work, measurements and operational acceptance
  remain before full plan completion.

- Worker supervision now only links scoped lifetimes: enabled permanent workers
  must not return, and unhandled failures cancel siblings and fail the process.
  Removed the catch-all restart policy and duplicate outer backoff; `withWorkers`
  needs only `Concurrent`. Matrix and iMessage retry explicit transport/protocol
  failures, preserving ingestion state. iMessage rechecks source identity after
  a failed page so a replaced bridge database can bootstrap safely. Individual
  turns, sends, captures and maintenance passes retain their own failure policy;
  supervision never replays an external operation. Retired restart-policy and
  redundant retry-counter tests; replacements verify failure propagation, sibling
  cleanup and cancellation. A real-DB/HTTP case covers source reset during paging.
  All targets build; 1,062 unit and 256 DB examples pass, along with capability
  and HLint checks. Effective src/app Haskell is 44,698 lines; core Haskell is
  31,874. Remaining removal/readability work, final measurements and operational
  acceptance are still pending. No production deployment is claimed.

- Removed obsolete dispatch/recovery-index checks from maintenance verification.
  Deleted the unused lease-renewal module and its two obsolete tests, plus the
  preview-only effect/interpreter whose sole caller was a test. The integration
  test now exercises the real collector directly in a read-only transaction;
  remaining capability checks stay intact. The shared hash helper is retained
  because two evaluation executables still use it.
  Current runbooks now describe process-owned Jobs, retained failures, explicit
  browser profiles and supported memory corrections; removed retired debt-review
  commands. Added an exhaustive installed-table/view classification and read-only
  schema measurement. `count-code.py --schema` reports active/shared SQL and
  retained archive structures separately, without deleting either. Prompt-flow
  now emits fixture request bytes and production token estimates with `--stats`.
  See `docs/code-size.md` for the current source/SQL/prompt checkpoint and limits.
  Final removal/readability review and operational acceptance remain pending.

- TurnRuntime now requires one recorded identity, shared by output allocation,
  admission and cancellation. Removed the identity-free test constructor,
  duplicated identity fields and unreachable missing-handle branches. Agent
  carries its current working-context projection forward without a restart
  restoration path. Feedback prompts now describe the live conversation inbox.
  Consolidated four duplicate or retired-protocol test cases while retaining
  ordering, provenance, cancellation and finish-race coverage. The SSE-to-QQ
  fixture now also uses a real recorded turn and the publication authority gate.
  All targets build; 1,056 unit and 256 DB examples pass, along with populated
  upgrade, capability, HLint and offline context checks (9 Historian, 7 recall).
  Architecture, feature and development docs no longer advertise retired
  dispatch leases, durable inboxes or tests. The measured source/SQL/prompt
  checkpoint is updated in `docs/code-size.md`. Final lifecycle readability
  review, live-model comparison and operational acceptance remain pending.

- Final removal/readability audit: all source modules are reachable from a
  production or evaluation entry point. The 33 archived relations have no
  runtime/maintenance SQL callers (remaining textual matches name the public
  `task_progress` tool). Historical migrations and user data remain intact;
  the populated upgrade fixture passes. Handler now shares named terminal and
  resource cleanup paths across launch failure and child exit, removing a
  duplicate terminal write on runtime-construction failure. Ownership handoff
  stays masked, and the child remains cancellable.
  Full local regression after this cleanup: 1,056 unit and 256 DB examples pass.
  Linux CI on `5a09858` exposed a test comparing nanosecond host time with a
  microsecond PostgreSQL timestamp; the cron-overflow case now takes its test
  clock from PostgreSQL, retaining exact equality and both admission assertions.
  Current source, active/archival SQL and prompt counts are in `docs/code-size.md`.
  Release CI, representative live-model comparison and operational acceptance
  remain required; no production deployment is claimed.

- Release CI for `e99a0a3` passed every job, including Linux DB tests, Nix package,
  both platform bridges and the runtime VM checks. The timestamp fixture fix
  removes the Linux-only exact-time mismatch without weakening its assertions.
- [Live model-loop comparison](research/simplification-evaluation.md): twelve
  predeclared, counterbalanced synthetic cases used the configured production
  default profile. All returned without timeout/tool errors; clarification and
  frozen-lookup answers met their narrow expectations. New long replies released
  text before model completion, but timing and explanation quality did not
  improve uniformly. The report records calls, usage, outputs, limitations and
  the exact one-off runner; it is not a generic model-quality certificate.
  Coordinated deployment and operational acceptance remain pending.

- [h610 deployment and operational evidence](research/simplification-release-20260919.md):
  `db80b66` was built and activated on the destination host after a real-snapshot
  migration rehearsal and a verified final backup. Retained data fingerprints
  matched; production reached migration 122. A real QQ reply obtained native
  receipts before the model-completion log. Browser workspace/public-navigation
  and native sandbox probes passed. Historical delivery/sandbox uncertainty and
  existing context source mismatches remain visible; strict health is not green.
  The user separately requested pausing iMessage and WeChat integrations.
