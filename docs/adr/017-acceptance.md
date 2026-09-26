# ADR-017 acceptance audit

Status: in progress. This is the requirement inventory for
[ADR-017](017-async-tools-and-agent-executors.md), not a completion declaration.
`Reviewed` means the implementation and the stated assertions have been read;
`Pending` means the final cross-path review is still required, even when existing
tests pass. Source paths below are relative to the repository root. Validation
is local implementation/test evidence, not deployment evidence.

## Invariants (§1)

| Requirement | State | Evidence / remaining review |
|---|---|---|
| 1. One segment per node; independent nodes progress concurrently | Reviewed | `Node.Executor` grants a single owner; `ExecutorSpec`, `ConversationSpec`, `Effects/AgentSpec` and `CodeMode/JavaScriptSpec` exercise competing model/guest actors. |
| 2. Interleave only at awaits | Reviewed | `runSteps` retains ownership between polls; only `Executor.await` yields. Executor tests distinguish no-await corrections, fast short tools and async awaits. |
| 3. Tool bodies off the executor; model/guest steps gated | Reviewed | `Execution.Tools.launchCall` starts the body in an Async; `Effects.Agent` calls `runSteps`; guest driver reacquires its actor before `resumeGuest`. |
| 4. One event admission, routing policy and wake rule | Pending | Trace every producer through `Node.Events`, `Node.Router`, frontend admission and monitor routing; verify no alternate model wake bypass. |
| 5. Observation-ordered, byte-stable projection | Reviewed | `Context.Projection.projectPolls`; projection specs compare encoded prefixes, raw reasoning and interleaved task isolation. Prompt-flow has an independent uninterrupted append oracle. |
| 6. Interrupted await preserves future | Reviewed | `Execution.Tools` detaches owned native futures; `CodeMode.Execution` parks the program. Native and JavaScript interruption tests verify no replay/cancellation. |
| 7. Downward controls; upward reports/messages; only ask waits upward | Pending | Review all tree-control and task-tool paths, including cancellation of a guest's awaited descendants. |
| 8. Process-local; no replay after restart | Pending | Review startup recovery and shutdown against §9, including retained calls and terminal monitor receipts. |

## Guest ABI and SDK (§2; delivery step 1)

| Requirement | State | Evidence / remaining review |
|---|---|---|
| `start`/`resume`, no Haskell callback, continuation in heap | Reviewed | `codemode/quickjs.c` drains jobs then returns; `cbits/max_wasm.c` defines only the three bounded data-channel imports. `CodeMode/WasmSpec` rejects old imports and invalid exports. |
| Calls/waiting, done/error packets; settle individual ids; invalid resume traps | Reviewed | Guest `drain`/`resume`, SDK `take`/`settle`, Haskell `GuestStep`; Wasm store-retention and resume-state tests. |
| Keep tools/raw/value/batch/agent/phase semantics and missing-await error | Reviewed | `codemode/sdk.js`; embedded JavaScript tests cover raw outcomes, batch order, waiting agent arguments, serialized awaits, manual examples and missing-await diagnostics. |
| Lifetime fuel, independent step deadline, interruption joins before freeing | Reviewed | C sets fuel once at open and resets only epoch deadlines per step. `Wasm.timed` and Wasm interruption/fuel/deadline tests. |
| Remove mailbox, callback StablePtr, reply buffer and result_ref paging | Reviewed | No old bridge symbols in `src`, `app`, `cbits` or `codemode`. The guest's 64 KiB final-output limit is not the removed callback reply buffer. |
| Per-completion resume, first-result race and incremental pipeline | Reviewed | Embedded `JavaScriptSpec` uses blocked sibling calls to prove first completion and starts a pipeline's next stage before unrelated searches finish. |
| Program return cancels running calls and their descendants | Pending | Direct-call cancellation/receipts are covered; finish auditing the real agent tool's child-tree cancellation path. |
| Promise.race losers remain awaitable | Reviewed | Test races a pending promise, releases it through another call, then awaits its actual result. |
| max.race/max.cancel cancel only direct tool promises; no duplicate effects | Reviewed | SDK WeakMap identity and cancellation outbox; race-cancel test waits for loser cleanup before continuing, outbox cancellation test asserts no calls. |
| max.sleep is a host future without clock access | Reviewed | SDK strips Date/Math.random; driver handles `$sleep`; embedded sleep test. |
| Awaited background agent can run code | Reviewed | DB `ExecutionSpec` runs a real admitted/attached awaited child through `runAgentRuntime`, loads web/codemode, executes a leaf, verifies journal rows and returns the actual report to its waiting parent. Model and leaf service are deterministic fixtures. |
| Guest-limit refusal before effects; existing workflow-agent behavior | Pending | `JavaScriptSpec` and `JobsSpec` cover guest admission; include workflow suite and actual global/tree bounds in final gate review. |

## Shared scheduler (§3; delivery step 2)

| Requirement | State | Evidence / remaining review |
|---|---|---|
| Reservation, admission and journal start before worker creation | Reviewed | `Execution.Tools.launchCall` orders these before `asyncWithUnmask`; native/guest share that function. |
| ParallelSafe/Independent share gate; SequentialOnly exclusive FIFO | Reviewed | Gate tickets are reserved synchronously; `Execution/ToolsSpec` proves an exclusive call cannot be overtaken and queued cancellation releases its ticket. |
| Native join_all returns protocol-order results; guest waits for any | Reviewed | Native `requestMap`/completed map and guest driver use the same `awaitWake`; native result-order and guest race tests. |
| Async yields immediately; short tools yield at five seconds | Reviewed | `Executor.await`/`shortDeadline`; executor tests cover both branches and ownership reacquisition. |
| Long background async await is steerable | Pending | Verify integrated background steering, not only a generic interrupt STM fixture. |
| Paused program resumes original await and records cancellation | Reviewed | `JavaScriptSpec` checks preserved local state, buffered completions, unfinished effect receipts and task-end cancellation. |

## Node events and routing (§4; delivery step 4)

| Requirement | State | Evidence / remaining review |
|---|---|---|
| Immutable real trigger and node log per task | Reviewed | `Node.Log`, `Node.Events.startTask`; trigger identity, frozen generations, shared observation snapshots and retirement tests. |
| Wake predicate matches selected settlements, urgent tells, steering and controls | Reviewed | `Events.wakes` and `EventsSpec`; non-urgent messages remain buffered. |
| Ready order guest, resumed, request, notice; FIFO within each | Reviewed | `Executor.Priority` and ready sequence; ordering, cancelled queued actor and open-task cap tests. |
| Reply to trigger/output routes to owner; unquoted !fb to newest same-principal task | Pending | Final producer-to-frontend routing trace and canonical provenance review. |
| Direct triggers / !btw create independent tasks | Pending | Review command classification and Conversation admission together. |
| Child messages/reports reach starting task; normal late tell folds, urgent/report relays | Pending | Review source ownership through task close, observation, retry and replacement. |
| Detached native completion relays after starting task ends | Pending | Review retained runtime and source grants through delivery/publication. |
| Monitor occurrence enters as Fired under overlap policy | Pending | Review frozen consumer, admission rollback and durable overflow. |
| !kill logs Cancelled and interrupts an active model call | Pending | Connect command entry to Tasks control and agent cancellation assertions. |
| Deeper steering also sends non-urgent provenance to parent | Pending | Review direct/deeper/ask-answer distinctions. |
| Final answer closes atomically unless an interrupt is unobserved | Pending | Review both ordinary and streamed final publication paths. |
| Remove Conversation tickets, Jobs inbox/notice/waiter/JobWork, old feedback paths | Reviewed | Current source search has no `readFeedback`, `ExecutionInbox`, `FeedbackPending`, `FeedbackFirst`, `feedback_pending`, `pendingNotice`, `noticeInFlight`, `JobWork`, `childWaiters`, `taskWorkflowHost`, `delegated` or `batchLock`. Generic status constructors are not old tickets. |

## Projection (§5; delivery step 3)

| Requirement | State | Evidence / remaining review |
|---|---|---|
| Frozen base/window; polls store raw output and ordered results | Reviewed | `Context.Projection.TaskRecord`, `Poll`, `projectPolls`; window/prefix/raw-reasoning tests. |
| Own full trail; other tasks visible only through published observations/tail | Reviewed | Owner-filtered `Node.Log.observedBetween`; interleaved/private-trail isolation tests. |
| Observation cap with count and context_read locator | Pending | Inspect archive authorization, recovery/expiry and combined conversation/event caps. |
| Volatile tail outside cache, budgeted, never stored | Pending | Review provider cache boundaries and TaskRegistry selection in addition to projection tests. |
| Compaction/media/skills planning in project; raw evidence retained | Reviewed | `planProjection` creates explicit checkpoints; compaction/media tests verify raw transcript and future-prefix behavior. |
| Absolute/frozen rendering under later edits and renames | Pending | Verify durable conversation-cut rendering and observation-time deduplication. |
| Step function replaces loop-owned history; uninterrupted bytes unchanged | Reviewed | `Effects.Agent` uses `Executor.runSteps`; independent prompt-flow oracle compares encoded messages and unredacted wire requests for all three protocols. |

## Interruption, children, monitors and restart (§6–§9)

| Requirement | State | Evidence / remaining review |
|---|---|---|
| Native handles remain live; subsequent wait receives real value | Reviewed | Native detach/retain and waitExecution paths; interruption and retained-call specs. |
| Paused guest retains store, buffers futures, admits no steps until resume | Reviewed | Resume TMVar/paused flag, guest actor await and buffered-results test. |
| Paused task-end cancels program/calls; short tools defer steering | Reviewed | Program ownership cleanup and `Execution/ToolsSpec` non-async test. |
| Background leaf-worker restriction removed; global/tree limits reject immediately | Pending | Finish tree-limit and profile/tool-directory audit. |
| agent_tell/max.tell and agent_ask/max.ask; urgent/normal distinction | Pending | Trace production tool metadata, SDK, parent routing and returned values. |
| Ask answered across two levels; agent_progress only status | Pending | Review Jobs/TaskExecution/Tasks tests and implementation together. |
| Frozen monitor consumer; durable schedule/dedup; bounded queue/coalesce | Pending | Review §8 source and database assertions. |
| No running-work replay; monitor definitions/trigger facts persist | Pending | Startup/shutdown review. |
| feed/replace overlap, workflow consumer and subscriptions | Deferred by ADR | Each requires its own decision; delivery step 5 is explicitly outside this implementation. |

## Numeric limits (§10)

All rows remain subject to the final configuration-and-boundary-test review.
These are the required values, not claims derived from default fixture limits.

| Requirement | Required value | Source to verify |
|---|---|---|
| Tree tool calls and model rounds | 2000 each; tool-free wrap-up | `Task.Policy`, `Jobs`, `Effects.Agent` |
| Tree deadline and nesting | 6 hours / 16 levels | `Jobs.admitJobWithAuthority`, runtime deadline binding |
| Model rounds per loop | 2000 | Agent runtime assembly |
| Report length and corrections | 100000 characters / two retries | `Task.Delegation`, `Turn.Job`, `Effects.Agent` |
| Guest fuel | 10^10 total | `CodeMode.JavaScript.javaScriptLimits`, C store creation |
| Guest host calls | 4096 | JavaScript limits and driver submitted counter |
| Guest store / heap | 256 / 192 MiB | JavaScript limits / compiled `codemode/quickjs.c` |
| Live guests | 32 global / 16 per tree | `Jobs.acquireGuestSlot` |
| Guest step wall time | 60 seconds | JavaScript limits / Wasm timed step |
| Calls in flight | 64 | SDK outbox and host GuestCalls validation |
| Resume outcomes / one result | 16 MiB / 4 MiB | `resumeChunk`, `boundedOutcome`, Wasm channel limits |
| Short-tool yield | 5 seconds | `Node.Executor.shortDeadline` |
| Observations | 200 / about 32000 tokens | `Agent.Runtime`, `DB.Observation`, `Node.Render` |
| Volatile tail | 16 open tasks | `Node.Render`, Jobs/Tasks selection |
| Open root tasks | 32 | `Node.Executor.dispatch` |
| Buffered events | 256 including reserved terminal control | `Node.Events.deliverTracked` |
| Folded tells | Last 50 / 32 KiB | `Jobs.boundedMessages` |
| Tell / steer text | 8000 characters | Jobs and frontend command admission |
| Browser workspaces per group | 4 including startup/failed cleanup | `Browser.Registry`; concurrent-start, mixed-owner, cross-group, failed-cleanup and cancellation tests |

## Completion gates

- Run both `max-test` and `max-test-db` with the current poll-driven embedded
  Wasm artifact and the isolated PostgreSQL database.
- Run `cabal build all`, `scripts/check-architecture.py`, formatting and diff
  checks.
- Run `cabal run max-prompt-flow`, include the document if changed, then run
  `cabal run max-prompt-flow -- --check` before every commit. Both commands now
  also refuse an uninterrupted projection mismatch against the append oracle.
- Resolve every Pending row, inspect each numbered limit, then update the ADR
  status and settle its tail-format/tool-name open questions. Green suites alone
  are not the completion audit.
