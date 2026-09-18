# Runtime simplification

Implementation of the agreed September 19 plan. Baseline: `b9d3e34`.
This checklist tracks the full scope; a passing intermediate change does not
complete the plan.

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
- [ ] Add active SQL/schema and prompt-size accounting to final measurements.
- [x] Remove whole-source-hash model certificates as generic CI blockers while
      retaining relevant deterministic and model-level evaluation.

### B. Foreground conversation

- [x] Remove model-facing `request_finish` and per-input dispositions.
- [ ] Remove frontend request ledgers.
- [ ] Replace frontend SQL ownership/leases with a bounded conversation queue.
- [x] Normal text ends the loop; failures/truncation/cancellation remain distinct.
- [x] Publish paragraphs and plain-prose fragments incrementally.
- [x] Bound retained stream buffers and validate publication through the full
      SSE/transport path before EOS.
- [ ] Update prompts, tools, handlers, output accounting and fixtures together.
- [x] Preserve live provider tool-call/reasoning state within a model loop.

### C. Jobs and application lifetime

- [ ] Replace durable tasks/attempts/revisions/leases with scoped in-process Jobs.
- [ ] Keep start/status/list/cancel/feedback, budgets and child result collection.
- [ ] Remove model-supplied idempotency keys and ordinary task-finish reports.
      Keep structured results only when a caller explicitly requires a contract.
- [ ] Remove restart turn recovery, execution admission journals and durable joins.
- [ ] Remove task browser checkpoint/restore; retain explicitly saved profiles.
- [x] Remove configuration generations/hot reload; simplify startup and shutdown.
- [ ] Route reminders through Jobs and preserve minimal trigger deduplication.

### D. Publication and maintenance

- [ ] Replace durable dispatch/outbox execution with bounded local queues.
- [ ] Keep platform receipts, reference mappings, current-run deduplication and
      conservative handling of uncertain sends.
- [x] Replace embedding maintenance leases with a process-local lock and
      missing-data scans; keep source/version-conditional writes.
- [ ] Replace media/Historian maintenance leases with local scheduling and
      missing-data scans; preserve short transactional publication.
- [x] Delete notification LLM review pipelines and operational debt review.
- [ ] Separate connection retries, individual task failures and fatal core errors.

### E. Context and optional machinery

- [x] Delete task-experience generation, replay, publication and maintenance
      commands. Retain old rows as data without loading learned instructions.
- [x] Delete the online skill factory and certificates; retain static lazy skills.
- [ ] Keep useful raw code mode on the shared tool boundary, without durable
      workflow state or a second authorization/execution path.
- [x] Delete model-driven memory dreaming; retain deterministic processing of
      recorded expiry dates without leases.
- [x] Delete cross-turn raw wire archive replay.
- [ ] Simplify context to recent messages, one sourced summary representation
      and relevant scoped memory; retain history search/expansion and token limits.
- [ ] Replace persistent materialization/CAS traces with derived in-memory state
      and optional sampled diagnostics.

### F. Removal and acceptance

- [ ] Delete unused modules, effects, configuration, SQL, admin surfaces and
      tests belonging to removed behavior. Preserve historical migrations.
- [ ] Stop using old execution tables before archiving/dropping them; retain
      business history and provide an upgrade path from the existing database.
- [ ] Make ordinary chat/tool/cancellation paths directly readable. Use named
      fields, explicit results and locally understandable resource ownership.
- [ ] Update architecture, feature, operations and generated prompt documentation.
- [ ] Publish final core and total-owned-code measurements with a file manifest.
- [ ] Complete local gates, upgrade checks, release and operational acceptance.

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
