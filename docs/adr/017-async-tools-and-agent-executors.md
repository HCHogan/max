# ADR-017: Async tools, agent executors and projected context

Status: in progress 2026-09-26. Delivery steps 1–2 are implemented: poll-driven
guests, shared per-call scheduling, native async interruption and paused guest
resume/cancel through node interrupts. Projection and node scheduling (steps
3–4), including unified event routing and detached-result routing after a task
ends, remain in progress. Root requests and guest drivers now share per-node
execution permits: async awaits yield immediately, short-tool rounds yield at
five seconds, and ready segments use the priority/FIFO order below. Up to 32
tasks can be open on a root; additional admitted requests remain queued.
Task records and observation-ordered projection now
drive agent polls from frozen observations; raw answers (including reasoning
and signatures), tool results and the initial window remain in the record.
Compaction and media planning use explicit projection checkpoints. Root
polls also observe later canonical public output through a frozen history cut,
excluding their own publications and private traces. These public observations
are bounded to 200 messages/about 32k tokens with context_read recovery.
Frontend and background steering now enter a shared typed node event store;
`ExecutionInbox`, the frontend feedback queue and the job feedback inbox are
removed. One wake predicate classifies interrupts. Delivery and successful
final-answer closure share STM, including already-streamed answers. Pending
child-report references stay in Jobs until the bounded event store accepts them;
progress changes status only. Background `agent_tell` / `agent_ask` and their
SDK functions deliver to the starting task's event log. A parent's answer
settles the pending ask without re-interrupting the guest that receives it;
external/deeper steering also records a normal note in the parent's log.
After the starting task ends, normal messages are bounded and folded into the
final report, preserving its original contract payload. Urgent messages still
use the existing bounded frontend notice relay, which can aggregate messages;
replacing that relay with per-event routing remains unfinished. Replies to an
open root task's trigger or public output now steer that task, while unquoted
`!fb` targets the sender's newest open task. `!btw` starts a separate task that
can itself receive later replies. The old job-output reply map is removed;
canonical output provenance identifies the producing root task. Detached native
calls now retain the execution runtime until they settle: the root executor is
released first, new model/tool admission and publication are fenced, and browser
teardown and shutdown-slot release wait for these calls. Kill/shutdown cancel
retained calls. Native completions now pass through `Node.Router`: an open task
observes a `Settled` event, while a closed task gets a frontend relay under the
original catalog ceiling. Results remain owned until observation or relay;
closing after delivery but before observation also relays exactly once. The
bounded router retains job-generation provenance and fences revoked output.
Tool attachments now belong to their invocation, with the original turn-wide
quota and once-only keys shared across call scopes. Native completion events
and frontend relays carry those attachments through normal media planning;
guest pause/resume snapshots transfer each completed leaf's attachments once.
An explicit wait for a detached native result does not duplicate its event's
attachments. Normal job completion now leaves descendants running under their
original tree budgets and deadlines. Ended ancestors stay retained while live
descendants depend on them. A completed job admits only checkpoints for its
already-running calls; new model/tool reservations remain fenced. Retained native
calls inherit the job deadline even after the model loop ends. Explicit cancel
and replacement still revoke the old generation and its descendants. Child waits
can outlive the parent task, and an unclaimed child report arriving after parent
closure uses the existing frontend relay. Each admitted native or guest leaf now
receives host-owned call authority. Memory, pin, monitor and task mutations use
that authority to finish after a normal terminal checkpoint, rechecking its
validity after acquiring database locks. Identity, source, role and grant checks
remain in force; cancellation, replacement, expiry and invocation return revoke
this permission. New calls and default database callers still require a live
model turn. An admitted agent call can create its child after parent completion
under the original tree grants and deadline. Full routing
(child relays, replacement/cancellation and monitor fires), combined
observation bounds and the open-task tail remain in step 4. Amends
[ADR-016](016-agent-tool-and-native-await.md) (leaf workers, foreground waits)
and the Wasm host ABI of [ADR-012](012-wasm-tool-execution.md). Work stays
process-local; restart persistence is out of scope (§9).

## Summary

Every agent becomes a single-threaded executor: the conversation foreground and
each background agent alike. Tool calls are futures. Tools that may run for a
long time are *async tools*: awaiting one yields the executor, so the agent can
answer other requests or be steered in the meantime. Everything that wakes an
agent is an event in its log, routed by one function and admitted by one wake
rule. The model's transcript is no longer accumulated state. It is a projection
of that log, and each event appears where the task observed it. Codemode
programs become poll-driven coroutines: each completion resumes the program
without waking the model. Children reach their parents through the same events,
and background agents may run code. Monitors are durable streams whose consumers
are frozen data.

## Context

Baseline: `558593f`.

**Codemode is a blocking guest.** `max_wasm_run` instantiates the QuickJS module
and runs `_start` to completion. A tool call goes through the `tool_call` import.
The C shim calls a foreign-exported Haskell callback, which posts to a mailbox
and blocks until the host answers. The SDK queues calls as promises. When no job
can run, it flushes up to 32 of them as one host batch (ADR-016). The batch is a
barrier, which has two effects:

- `Promise.race([agent(a), agent(b)])` waits for both.
- In `Promise.all(xs.map(async x => agent({context: await search(x)})))`, no
  agent starts until every search has returned.

Replies over 64 KiB are paged through `result_ref` requests.

**A waiting foreground holds its conversation.** `Conversation` admits one
`Running` ticket per group. A turn waiting in `agent({wait: true})` can hold it
for up to six hours, and other requests queue behind it. The only input that
reaches a running turn is its initiator's `!fb`. The turn reads it between model
rounds (`Feeding`, `readFeedback`).

**Only some background waits are steerable.** A background agent can wait in
`agent` or `agent_wait`. If its inbox then receives a steer,
`Jobs.waitForChildren` returns `FeedbackPending` and the tool returns
`feedback_pending`. A codemode program is stopped at that point
(`WasmHostStopped`), and the rest of its code is lost. A long `sandbox_exec` or
browser call never looks at the inbox.

**Waiting agents are leaves.** An agent started with `wait` cannot `run_code`,
and neither can its descendants (ADR-016). `Jobs.admitJob` makes `delegated`
inherited, and `taskWorkflowHost` enforces it. ADR-015 introduced the rule as a
scope limit for that batch. The operational reason: a waiting guest pins an OS
thread inside a safe FFI call, plus a Wasm store of up to 64 MiB, at every
level.

**Children cannot tell parents anything before they finish.** `agent_progress`
only records an internal status line. Everything else waits for the final
report.

**Wake-ups have many entry points.**

| Agent | Entry points today |
|---|---|
| Foreground | a direct trigger starts a dispatch; `!fb` feeds the running ticket; a child report goes through `Jobs.PublishJobNotice` to a notice turn; a monitor fire becomes a Job and an `AutomationTurn`; a monitor job's result goes through `RecordMonitorResult`; `!kill` uses `throwTo` |
| Background | `LaunchJob`; `agent_steer` fills the inbox, read by `eiRead` or `FeedbackPending`; `agent_replace` starts a new generation; child reports reach it through `agent_wait` or `agent_status`; cancellation uses `stopChildren` |

`Jobs.Entry` carries `inbox`, `pendingNotice`, `pendingMonitor`,
`noticeInFlight` and `awaiter`. Each is a small event queue with its own rules.

**Context accumulates in the turn thread.** `Effects.Agent.LoopState.history`
starts as the conversation window at dispatch. It then grows with tool rounds
and inbox notes. A turn that waits sees nothing of what happened meanwhile,
unless it arrives as a note. Other turns see nothing of its work.

**Monitors cost a model turn per occurrence.** Each fire becomes a Job and a
foreground `AutomationTurn`. The overlap policy (`coalesce`, or a bounded
`queue`) decides what happens to occurrences that arrive while earlier ones are
still pending.

## Terms

- **Node.** Something that owns one model conversation. Each group has a *root*
  node (the foreground), and each agent job is a node. Nodes form the agent tree.
- **Executor.** A node's scheduler. It runs at most one segment at a time.
- **Segment.** One model call (a *poll* of a task), or one guest step (§2).
- **Task.** A unit of work on a node, with a trigger and its own record. The root
  has one task per request, relay or monitor occurrence. An agent node has
  exactly one task: its objective.
- **Future.** One in-flight tool call.
- **Stream.** A producer that yields items and possibly a final output. A child
  agent and a monitor are both streams.
- **Async tool.** A tool whose await yields the executor, declared in tool
  metadata. Async tools are also *detachable*: when an await is interrupted, the
  call keeps running and the task gets a handle to it. `agent` and `run_code` are
  async; `web_search` is not.
- **Await point.** A place where a task waits for futures. It is the only place
  where tasks interleave, and the only place where steering takes effect.
- **Log, event, observation cursor, projection.** Defined in §4–§5. For a root
  node, the log is the conversation's canonical history plus in-memory events.
  For an agent node, it is in-memory events only.

| tokio | Max |
|---|---|
| `spawn(f).await` | `agent({wait: true})` |
| `spawn(f)` → `JoinHandle` | `agent({})` → `agent#N` |
| `join_all(handles).await` | `agent_wait`; a native tool round; `Promise.all` |
| `select!` | an await that ends on completions or on an interrupting event |
| `Stream::poll_next` | a child's tell; a monitor occurrence |
| current-thread runtime | one executor per node |
| blocking pool and reactor | tool bodies, which run off the executor |

## Decision

### 1. Invariants

1. **One segment at a time per node.** A node's segments are totally ordered.
   Different nodes run concurrently.
2. **Tasks interleave only at await points.** A task holds its executor from
   one await to the next.
3. **Tool bodies run off the executor** and never read a node's context. Model
   calls and guest steps run on the executor.
4. **Every wake-up is an event in a node's log.** One routing function assigns
   each event to a task. One wake rule decides whether that task becomes ready.
5. **A transcript is a projection** of the log and the task's record. Each event
   appears at the poll where the task first observed it. For a given task the
   projection only ever grows at the end, and it is byte-stable.
6. **An interrupted await never cancels its future.** A native call becomes a
   handle; a guest program pauses.
7. **Control flows down the tree; messages and reports flow up.** A node waits
   for an ancestor only through `ask`. The question interrupts the ancestor's
   await, so waits never form a cycle.
8. **Everything here is process-local.** A restart interrupts running work; this
   ADR adds no resumption or replay (§9).

### 2. Codemode guests are poll-driven coroutines

The guest never calls back into Haskell. It stops at the top of its event loop.
At that point the C stack is empty, and the whole JavaScript continuation is data
in the store: pending promise reactions in the QuickJS heap.

**ABI.** The module exports `start` and `resume` instead of `_start`, and the
`tool_call` import is removed. Each export drains the job queue and then writes
one message:

- `{calls: [{id, tool, args}], waiting: n}` lists the calls started since the
  last step (possibly none) and the number of unsettled calls;
- `{done: value}` or `{error: message}` is written when nothing is queued or
  waiting.

`resume` reads `[[id, outcome], …]` from the input channel and settles those
promises before draining. Resuming a guest that is not suspended traps.

**SDK.** Each call gets an id, a promise and an outbox entry:

```js
const submit = call => new Promise((resolve, reject) => {
  const id = nextId++;
  waiting.set(id, {resolve, reject});
  outbox.push({id, ...call});
});
// __maxTake drains the outbox and reports waiting.size;
// __maxSettle resolves promises by id.
```

`tools`, `max.raw`, `max.value`, `max.batch`, `agent()` and `max.phase` keep
their meaning. So does the error raised when a result is read without `await`.

**Host.**

```haskell
data GuestStep
  = GuestCalls ![GuestCall] !Int -- new calls; count still unsettled
  | GuestDone !ByteString
  | GuestTrap !Text

withGuest :: WasmLimits -> ByteString -> ByteString -> (Guest -> GuestStep -> Eff es a) -> Eff es a
resumeGuest :: Guest -> [(Int, Value)] -> IO GuestStep
```

The store lives on between steps:

- Fuel is counted across the whole program.
- Each step has its own epoch deadline.
- Interruption works as it does today.

This removes `dispatchCallback`, the mailbox, the callback `StablePtr`, the
64 KiB reply buffer and `result_ref` paging. One resume carries at most 16 MiB of
outcomes; anything beyond that waits for the next resume.

**Driver.** `Max.CodeMode.Execution` loops over three steps: launch each new call
(§3), wait for any completion, then resume the guest with every completion that
is ready. A completion wakes the program, never the model. As a result:

- `Promise.race` returns with its first result.
- A pipeline starts each agent as soon as its own search returns.

**Returning cancels what is still in flight.** When a program returns, the
result of any call still in flight can no longer reach anything, because the
program is gone. Such calls are cancelled, and so are their descendants. This is
structured concurrency, like dropping a tokio `JoinSet`. It replaces ADR-016's
rule that unawaited calls run before the result is published: a program must
await the work it wants done. Work that should outlive the program is detached
explicitly. `tools.agent` without `wait` returns a handle at once, so it is never
in flight at return. A cancelled call is recorded like any interrupted call:
outcome-unknown if it may already have started an effect, cancelled otherwise.

**Race losers.** `Promise.race` cannot cancel its losers. The program may still
await one later, for example
`await Promise.race([p, max.sleep(60_000)]); …; await p`. So race losers run on
until they finish or the program returns. Two SDK additions give earlier
cancellation:

- `max.race(promises)` settles like `Promise.race` and then cancels the calls
  behind the other promises, like `tokio::select!` dropping its other branches.
- `max.cancel(promise)` cancels one call.

Both act on promises returned directly by tool calls. A derived promise, such as
the result of an `async` function, cannot be traced back to its calls; those
calls are cancelled at return at the latest. A losing call has no reader for its
result. If it is an effectful tool that has already started, cancelling it can
leave the effect partial, which is recorded as outcome-unknown. Races are meant
for redundant reads and redundant agents, where this does not arise.

`max.sleep(ms)` is a host future without effects, for timeouts. It gives the
guest no clock reading.

### 3. One scheduler for native calls and code

`Execution.Tools` replaces the batch barrier with per-call launch:

```haskell
launchCall :: ExecutionSession -> ExecutionHooks es -> [CatalogTool] -> ToolRequest -> Eff es (Async ToolInvocation)
awaitWake :: Node -> TaskId -> Map k (Async ToolInvocation) -> STM (Wake k)

data Wake k = Settled ![(k, ToolInvocation)] | Interrupted
```

Budget reservation, admission and the journal start all happen before the
`Async` exists. The `Async` runs the tool and records its finish. A gate replaces
`batchLock`: `ParallelSafe` and `ParallelIndependent` calls share it, and
`SequentialOnly` calls take it exclusively, in arrival order.

A native tool round is `join_all` over its calls. Provider protocols need every
result before the next model call, so native calls cannot express race, select
or pipelines. A single native call behaves exactly like
`run_code("return await tools.x(args)")`, by construction: both wait through
`awaitWake`.

**Yielding.** An await that includes an async tool yields the executor at once.
An await of short tools only holds the executor for up to five seconds and then
yields. That way fast calls do not interleave tasks for no benefit.

### 4. Nodes, events and one wake rule

```haskell
data Event = Event {target :: Target, body :: EventBody}

data Target = NewTask | ToTask TaskId

data EventBody
  = Said MessageRef                 -- a group message; for an agent node, its objective
  | Steered Text                    -- !fb, agent_steer, or the answer to an ask
  | Replaced Text
  | Cancelled
  | ChildSaid AgentRun Text Urgency
  | ChildDone AgentRun Report
  | Settled CallRef ToolInvocation  -- only for calls that no guest is waiting on
  | Fired Occurrence

-- The only way in.
deliver :: Node -> Event -> STM ()

-- For a task that is awaiting futures. A ready task observes buffered events at
-- its next poll. Events for a running task are buffered and re-checked when its
-- segment ends.
wakes :: Pending -> EventBody -> Bool
wakes pending = \case
  Settled call _ -> completesAwait pending call
  ChildDone run _ -> completesAwait pending run
  ChildSaid _ _ Urgent -> True
  Steered _ -> True
  Replaced _ -> True
  Cancelled -> True
  _ -> False -- buffered; observed at the next poll

runNode :: Node -> Eff es ()
runNode node = forever $ do
  task <- atomically (nextReady node)
  runSegment node task -- a guest step, or: project, call the model, record, launch or finish
```

The ready queue is ordered by class, first to last:

1. guest steps;
2. tasks woken by an interrupting event or by a completed await;
3. new requests;
4. notices.

Within a class, order is first in, first out.

**Routing.** This is the one place that holds policy. At the root:

| Event | Goes to |
|---|---|
| A reply to a task's trigger or output; `!fb` | That task, as `Steered`. An `!fb` that is not a reply goes to the newest open task of the same principal. |
| Any other direct trigger; `!btw` | A new task |
| A child's message or report | The task that started the child. If that task has ended, an urgent message or a report becomes a new relay task, and a non-urgent message joins the child's final report. |
| The outcome of a detached call whose task has ended | A new relay task, as agent reports are today |
| A monitor occurrence | Decided by the overlap policy (§8) |
| `!kill` | `Cancelled`. The running segment is also cancelled at once, so cancellation stays responsive during a model call. |

At an agent node, everything addressed to the node goes to its one task. A steer
may be sent directly to a deeper node. It is then also delivered to that node's
parent, as a non-urgent `ChildSaid` note. This way the parent's context records
that its child changed direction.

**Ending.** A final answer ends the task, unless the task still has an
unobserved interrupting event. In that case it is polled again. This replaces
the late-feedback special case in the agent loop.

**What this replaces:**

- `Conversation`'s tickets (`Waiting`, `Running`, `Feeding`, `Observed`) and
  `readFeedback`;
- `Jobs.Entry`'s `inbox`, `pendingNotice`, `pendingMonitor`, `noticeInFlight`
  and `awaiter`, and `JobWork`;
- the special cases for steering during a wait: `FeedbackPending` in
  `waitForChildren`, `FeedbackFirst` in `TaskControl`, and codemode's
  `feedback_pending` stop;
- the inbox read in `ExecutionInbox`;
- the late-feedback branch of `Effects.Agent`.

`Jobs` keeps job identity, the tree, authority, budgets, deadlines and status.
Per-node bounds on the log and the ready queue take the place of the ticket and
inbox limits.

### 5. The transcript is a projection

```haskell
data TaskRecord = TaskRecord
  { trigger :: !EventRef,
    base :: !Cursor,    -- end of the conversation window when the task began
    polls :: !(Seq Poll)
  }

data Poll = Poll
  { observed :: !Cursor,                    -- log position this poll observed
    output :: !RawAssistant,                -- the provider's message, verbatim, with reasoning
    results :: ![(CallRef, ToolInvocation)] -- delivered before the next poll
  }

project :: NodeLog -> TaskRecord -> Cursor -> [ChatMessage]
```

A projection is built in this order:

1. the system prompt;
2. the conversation window up to `base`;
3. for each poll: the events between the previous and this `observed` cursor,
   then the poll's output, then its results;
4. a volatile tail, outside the cached prefix, listing the node's other open
   tasks (trigger, what each waits for, age).

**Placement by observation.** An event appears where the task first observed
it, never at its wall-clock time. There are three reasons:

1. A tool result must follow its call, so events that arrived during a wait can
   only come after the result.
2. The model's earlier output must stay next to the context it was produced
   from. Placing "stop searching" before a search call would tell the model it
   had ignored the request.
3. Each poll's input is the previous poll's input plus new observations, output
   and results. The prefix therefore stays stable and hits the prompt cache.

Regenerating each poll from the latest conversation window would break all
three.

**Contents.**

- A task's own calls and results appear in full. Other tasks appear only through
  what they published and through the volatile tail.
- Observations are bounded. Beyond the cap, the projection gives a count and a
  `context_read` locator.
- Outputs are replayed verbatim, because reasoning signatures cannot be
  re-rendered.
- Working-context planning (`fitWorkingContext`, the vision budget, compaction)
  moves into `project`. Compaction breaks the prefix, as it does today.
- Rendering must be byte-stable. Times are rendered absolute, which is true
  today. Edited or renamed history is shown as it was observed, or else accepted
  as a cache miss.

**Lifetime.** A record lives in memory with its task. This is the within-loop
state that ADR-005 kept, and it adds no cross-turn replay.

`LoopState.history` and `LoopState.appended` go away, and the agent loop becomes
a step function called by the executor. For a task that is never interrupted,
the projection must equal today's messages byte for byte. `max-prompt-flow`
checks this.

### 6. Interrupted awaits

An interrupting event (§4) ends the await without cancelling anything.

- **Native calls.** Each pending async call's tool result becomes its handle and
  status, for example `{status: "running", agent: "agent#13"}` or
  `{status: "running", result: "t#41:r5"}`. This generalises `feedback_pending`.
  The call keeps running, and its outcome later reaches the same task as
  `ChildDone` or `Settled`. `agent_wait` waits again.
- **Codemode.** The program pauses at its await: calls in flight continue, their
  completions are buffered, and no guest step runs. `run_code` returns
  `{status: "paused", run: "t#41:r3", calls, pending}`. The model may resume the
  program (`run_code_resume`) or cancel it (`run_code_cancel`). Pausing keeps a
  program and the model from issuing calls concurrently for the same task. When
  its task ends, a paused program is cancelled, and so are its in-flight calls
  (§2). An interrupted native call differs: it has already become a handle that
  the model saw, as with `agent` without `wait`.

Non-async tools are not interrupted. An interrupting event waits for them to
finish; they are short by definition.

### 7. Background agents run code; children talk to parents

**Background codemode.** The leaf-worker rule of ADR-016 is removed, together
with `JobSpec.delegated`, its inheritance and `taskWorkflowHost`. With
poll-driven guests, an awaiting program costs memory, not a thread or an
executor.

Live guests are limited globally and per agent tree. A `run_code` over either
limit is rejected before any effect, with retry-safe status; it is never queued.
Queueing could deadlock: an ancestor's paused program would hold the slot its
descendant is waiting for. After a rejection the model can fall back to native
calls. Tree budgets and the 16-level nesting limit stay.

**Messages up the tree.** Agent nodes get two tools, with matching SDK
functions:

| Tool | SDK | Effect |
|---|---|---|
| `agent_tell {text, urgent?}` | `max.tell(text, {urgent})` | Appends `ChildSaid` to the parent's log and returns. A non-urgent tell is observed at the parent's next poll; an urgent one interrupts the parent's await. |
| `agent_ask {question}` | `await max.ask(question)` | An urgent tell, followed by a wait for the next `Steered` from the parent, which is the answer. |

A child is a stream: its items are tells and its output is its report. A parent
that has received something but must keep waiting needs no special case. The
interrupted await leaves the child as a handle, and the parent can do one of
three things:

- wait again with `agent_wait`;
- resume its paused program;
- leave the child to report later.

`agent_progress` stays a status line, visible through `agent_status`. A tell is
a message.

`ask` is the only way a node can wait on an ancestor, and it cannot deadlock.
The question interrupts the ancestor's await, and the ancestor's steer both
answers the question and wakes the asker.

### 8. Monitors are durable streams

A one-shot monitor is a future. A recurring monitor is an unbounded stream of
occurrences:

- Its *state* is its trigger and schedule state: next due time and
  deduplication keys.
- Its *consumer* is the frozen `DefinitionSnapshot`: goal, grants, role,
  profile.

```
occurrences.for_each(|o| spawn(task(snapshot, o)))
```

Neither half is a running computation. That is why monitors survive a restart
and futures do not.

The overlap policies are backpressure:

- `queue` is a bounded buffer that records overflow.
- `coalesce` merges pending occurrences into one.

`decideOverlap` moves into root routing, and an occurrence becomes a `Fired`
event.

This ADR changes only the plumbing. The model makes three extensions natural,
and each needs its own decision:

- **More overlap policies.** `feed` delivers an occurrence to the still-running
  task of the previous one. `replace` cancels that task and starts from the
  newest occurrence.
- **A saved workflow as the consumer.** Code checks each occurrence under the
  frozen grants and wakes the model only through an urgent tell, instead of
  spending a model turn on every fire.
- **In-memory subscriptions.** A program could subscribe with
  `await max.next("m#3")` or `for await (… of max.watch("m#3"))`, and a non-root
  node could own a monitor. Both end with their task or node.

### 9. Restart

Unchanged. Nodes, tasks, records, guests and futures are process-local, like
today's jobs. A restart interrupts them and resumes nothing. Monitor definitions
and trigger facts persist as they do today.

Persistence is deferred, not ruled out. The projection's records are already
plain data. A guest could be rebuilt by deterministic replay: the SDK has no
clock or entropy, results are journaled, and the host would add the wake order.
Neither is worth building while the work being awaited (child agents, in-memory
subscriptions) itself ends on restart.

### 10. Limits

The numbers assume Max runs on tank (20 cores, 62 GiB) rather than h610. Values
marked *live* already apply since `3400fd5`; the rest arrive with the step that
introduces them.

| Limit | Value | Note |
|---|---|---|
| Tool calls per agent tree | 2000 | Live. Spent: calls are refused before effect and each agent writes a tool-free report. |
| Model rounds per agent tree | 2000 | Live. Same wrap-up. |
| Tree deadline / nesting | 6 hours / 16 levels | Unchanged. |
| Model rounds per agent loop | 2000 | Live; matches the tree budget. |
| Report length | 100,000 characters | Live. Empty, oversized or off-contract reports get two correction rounds. |
| Guest fuel per program | 10¹⁰ | Live (was 10⁹). |
| Host calls per program | 4096 | Live (was 1024). |
| Guest memory | 256 MiB store, 192 MiB JS heap | Was 64 / 48 MiB; the heap limit is compiled into the guest. |
| Live guests | 32 global, 16 per tree | Worst case 8 GiB. Over the limit, `run_code` is rejected, never queued (§7). |
| Wall time per guest step | 60 seconds | Fuel still bounds total CPU. |
| In-flight calls per program | 64 | Further calls wait in the outbox. |
| Outcomes per resume | 16 MiB | One tool result stays capped at 4 MiB. |
| Yield threshold for short tools | 5 seconds | Async tools yield at once. |
| Observations per poll | 200 events or about 32k tokens | Beyond that, a count and a `context_read` locator. |
| Volatile tail | 16 open tasks, one line each | Outside the cached prefix. |
| Open tasks per root node | 32 | Further requests wait in the ready queue. |
| Buffered events per task | 256 | As the job inbox today. |
| Non-urgent tells folded into a final report | Last 50, at most 32 KiB | When the starting task has ended. |
| Tell and steer text | 8000 characters | As steering today. |

## Delivery

Each step ships on its own, with the test suites and `max-prompt-flow` passing.

1. **Poll-driven guests and background codemode.**
   - Scope: the new ABI, SDK and driver (§2), using the per-call launch/gate
     foundation from step 2 so race and pipelines do not retain a batch barrier.
   - Removed: the mailbox, the callback and paging, and the leaf-worker rule.
   - Added: guest limits.
   - Tests:
     - `Promise.race` returns with the first completion; `max.race` cancels the
       losers; returning cancels calls still in flight.
     - A pipeline starts each agent after its own search.
     - Each resume delivers completions individually.
     - A waiting background agent can run code.
     - A `run_code` over the limit is rejected before effect.
     - The existing codemode and workflow-agent specs pass.
2. **Shared scheduler and interruption.**
   - Scope: `launchCall`, `awaitWake` and the gate (§3); interruption for every
     async tool, using today's inbox as the event source (§6); paused programs
     with resume and cancel.
   - Tests:
     - A steer interrupts a long async call in a background agent.
     - A paused program resumes with its buffered completions.
     - Cancelling a paused program records its in-flight calls.
3. **Projection.**
   - Scope: `TaskRecord` and `project` replace `LoopState.history` (§5), and
     `ExecutionInbox` feeds observations.
   - Tests:
     - Prompt flow is byte-identical for uninterrupted tasks.
     - Notes that arrive during a round are placed by observation.
4. **Nodes and events.**
   - Scope: node logs, routing, `wakes` and ready queues (§4). The root no
     longer blocks while it awaits. Adds `agent_tell` and `agent_ask`, and turns
     monitor occurrences into events.
   - Removed: the structures listed in §4.
   - Tests, replacing `ConversationSpec` and the notice and inbox parts of
     `JobsSpec`:
     - A second request is answered while the first awaits.
     - The first request then resumes and observes the second.
     - `!fb` interrupts an await.
     - Urgent tells interrupt; non-urgent ones wait.
     - An ask is answered across two levels.
     - `!kill` works during a model call.
5. **Monitor extensions** (§8), each by separate decision.

## Consequences

**What improves:**

- A waiting agent no longer blocks its conversation. Steering works at every
  await, at every level, for every async tool.
- One mechanism lets a resumed task see what happened while it waited, and lets
  other tasks see what is still open.
- Programs can express race and pipelines, and completions cost no model calls.
- Background agents can run code, and children can inform or ask their parents
  while they run.
- Many special cases collapse into routing and one wake rule, which shrinks the
  core code.

**What it costs:**

- Step 4 rewrites dispatch ownership in `Turn.Dispatch`, `Conversation`, `Jobs`
  and the agent loop, along with their tests.
- The root node can now have several live tasks at once. Per-task resources
  (browser workspaces, sandbox sessions) therefore need per-group limits.
- A reply can arrive after replies to later requests. It answers its own trigger
  message.
- State read before an await can be stale after it. The projection shows what
  changed, but does not prevent it.
- Paused guests hold memory until their task ends.
- Urgent tells add model polls. Tree budgets bound them.

## Alternatives considered

- **Delimited continuations or an algebraic-effects library in Haskell** (GHC
  `prompt#`/`control0#`, `eff`). Rejected for four reasons:
  - The continuation that needs capturing lives in the guest, not in Haskell.
  - Callbacks from Wasmtime run on a fresh in-call Haskell thread, so a prompt
    installed on the caller's stack cannot be reached.
  - `effectful`'s environment is bound to its thread, and it does not support
    captured continuations. Captures also cannot be serialized.
  - Nothing needs capturing anyway. GHC threads already are one-shot
    continuations, and at the loop top the guest's continuation is already data.
- **Wasmtime async fibers or Asyncify.** These keep a native stack or instrument
  the module. Neither is needed when the guest suspends with an empty C stack.
- **Parking the conversation ticket.** This would add `Parked` and `Resuming`
  states, inject a "meanwhile" delta on resume, and gate conversation output. It
  is a smaller first step, but it adds special channels and leaves the entry
  points separate. §4 and §5 subsume it.
- **Dropping the model continuation.** A program's result would be delivered as
  a relay turn. Simple, but it loses the task's own trail and forces detach
  semantics.
- **Wall-clock placement, or regenerating each poll from the latest window.**
  Rejected for the reasons in §5.
- **Concurrent segments on one node.** Leads to contradictory replies,
  undefined observations and racing publication.
- **Keeping leaf workers.** No longer justified; see §7.
- **Guest snapshots, or Temporal-style replay to survive restart.** Deferred
  rather than rejected; see §9.
- **Cancelling race losers inside `Promise.race`.** Rejected: it would break the
  legitimate pattern of racing a call against a timeout and then awaiting it
  anyway.

## Open questions

- The format and size of the volatile tail that describes other open tasks.
- Tool names: `agent_tell`, `agent_ask`, `run_code_resume`, `run_code_cancel`.
