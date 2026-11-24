# Lifetimes, cancellation and timeouts

How tasks and resources end, what a cancellation may leave behind, and
where time limits are set. The task tree itself is in
[Runtime structure](../architecture.md#runtime-structure).

## How resources end

A resource ends in one of two ways, and both are normal paths:

- **Closing**: the owner finishes its work and calls `close().await`. It
  can wait, return an error and have its own timeout policy.
- **Cancellation**: the owner itself is cancelled, by `/kill`, a timeout or
  the end of the shutdown grace. Its future is dropped, the resource with
  it, and the resource's `Drop` runs. Every `/kill` takes this path, so it
  is designed and tested as a normal path.

Starting a cancellation is always synchronous: dropping a future,
`CancellationToken::cancel()`, closing an fd, sending a signal, setting a
flag. Normally nobody waits for it to complete; only at shutdown does
`Scope::close` wait.

Rules:

1. **`Drop` only starts, synchronously; it neither blocks nor spawns.**
   There is no reaper.
2. **An external resource's lifetime is bound to a connection or an fd
   where it can be.** When the connection drops the peer winds down by
   itself, and on a crash the kernel closes the fd, so crashes are covered
   too.
   - A model call: dropping the stream closes the connection.
   - A call in the VM (`shell` or `run_code`): a unit of the guest's that
     the host waits for over an SSH channel. When max lets go of a call it
     closes the channel's input, and the guest stops the unit of a call
     whose caller is gone; see [Background commands](jobs.md#background-commands).
   - The VM itself: a unit of the host's systemd. max stops it when it is
     idle, replaced or dead, and leaves it alone when max itself stops; see
     [VMs](vm.md).
   - The browser: a child of the runner, through a pipe. When the runner
     exits Playwright kills it; when the runner is killed, the browser is
     in the same unit and goes with it, so the next run in the VM doesn't
     see the last run's browser.
   - Killing a process means killing its whole tree, by process group or
     cgroup: kill only the child and the grandchildren live on and keep the
     output pipe open.
3. **A peer that answers only to API calls** is stopped by a resident
   service that holds its connection: `Drop` passes it the stop with
   `try_send`, and the service calls the API. The service lives in the
   services scope and is shut down in order.
4. **On a crash `Drop` doesn't run.** The VMs are units of their own and
   run on, with what runs in them: a call the dead max waited for ends at
   its own limit and clears up after itself, a background command tells the
   next max when it ends, and the next max attaches to the VMs as it starts.
5. **Only types that must wait for a result or report an error on normal
   completion have a `close`**: to get an exit code, finish sending what is
   pending, commit a transaction. Everything else has only `Drop`.
6. **`close` follows ownership.** Whoever owns a value calls it at the end
   of its normal path. A struct that owns fields needing `close` has a
   `close` of its own that closes them in reverse order of creation.
   `close` takes `self`, so it can be called in one place only. A `?` in
   the body mustn't skip it: get the result, close, then handle the
   result.
7. **`close` is itself safe to drop.** If any `await` in it is dropped,
   `Drop` still cleans up by the cancellation path. The "fully closed" mark
   is set in the very last step.
8. **No alarms in `Drop`, and no drop bombs.** Cancellation is a drop, so
   alarms would be noise. A forgotten `close` is caught by tests: the fake
   environment counts resources "killed because the connection dropped",
   and normal-path tests assert that count is 0.

Language-level async drop (`#![feature(async_drop)]`) is experimental, on
nightly, with no date for stabilisation. Even stabilised, `select!`,
`JoinSet` and the runtime drop futures synchronously, so cancellation
would still run only the synchronous `Drop`; at most it would save
remembering to call `close`. It isn't used.

## Cancellation safety

With cancellation by drop, any `await` may be the end. A dropped future's
local variables disappear with it and nobody sees them half done; what
needs care is only the state that outlives the drop.

The actor itself is never cancelled; it ends only at shutdown, with the
conversations scope. What is cancelled is the tasks it spawns, and between
them and the actor there are only mailboxes, no shared mutable state. So
what a review asks is: if a task is aborted at any `await`, what does it
leave behind outside itself?

| State that survives | What can go wrong | Rule |
| --- | --- | --- |
| The core | It stops in the middle of a transition. | The core is a field of the actor; transitions are synchronous and happen only while the actor handles an event. Tasks can't touch it. |
| Words already said | A message reaches the group but not the ledger. | The segmenter lives in the model call's task and only produces `Said`; the sender takes only segments the actor has entered. Wherever the task is aborted, the result can only be saying less, never something said and unrecorded. |
| The completion event the actor waits for | It never comes, and the core waits forever. | The receipt sends a "no result" event from its `Drop`; see [I/O tasks and protocol adapters](core.md#io-tasks-and-protocol-adapters). |
| A shared connection | A frame is half written and the connection breaks. | A shared connection is read and written only by its own task; everyone else hands it data through a channel. |
| The database | A write is half done. | Transactions. For a connection whose query was dropped midway, sqlx reads the leftover response before its next use. The actor's database `await`s are dropped only at shutdown. |
| Turn records | The final write is interrupted at shutdown. | The transaction rolls back, which is a crash, and the turn is recorded `Lost` at startup. |

Only cancel-safe branches go in a `select!` loop:

- **Allowed**: `mpsc::Receiver::recv`, `CancellationToken::cancelled`,
  `JoinSet::join_next`; `next()` on a `FramedRead` with `LinesCodec`,
  whose buffer is in the stream, not the future (it splits only on `\n`,
  and needs a maximum line length); `sleep_until(deadline)`, or a `Sleep`
  pinned outside the loop and reused.
- **Not allowed**: `read_line`, `read_exact`, `write_all`; a `sleep(dur)`
  made anew on each iteration, which resets the timer every time.

Invariants aren't changed while a lock is held across an `await`; clippy's
`await_holding_lock` catches some cases.

No test tries every `await`: these rules are kept by review. `/kill` and
a stop that outlasts its grace each have one test through the actor, and
`Scope`'s close and drop have their own (see
[Testing](actor.md#testing)).

## Timeouts

Limits are set only at the boundaries of units of work; the `await`s
inside a unit aren't wrapped in timeouts, since cancelling the owner drops
whatever is stuck inside it.

| Where | Written | What for |
| --- | --- | --- |
| `Scope::close(grace)` | once, in `Scope` | No hang at shutdown. |
| The actor's deadline | one `sleep_until` in its main loop, at the earliest of the idle window, intent's debounce and the stop grace | Policy: the idle window (the provider's `idle_window_secs`, or the conversation's own; see [Settings a conversation sets](config.md#settings-a-conversation-sets)) and the shutdown grace. A turn has no wall-clock limit: the actor waits only on the database, and model calls and tools have limits of their own. |
| A call in the VM | the unit's own `RuntimeMaxSec=` in the guest: `RUN_TIME`, 120 seconds, and a call may ask for up to 600; a background command 6 hours, up to 24 (see [Background commands](jobs.md#background-commands)). A call's unit has `TimeoutStopSec=15`, and max waits `GUEST_MARGIN`, 30 seconds past the limit, for the guest to say how it ended (`tools::wait`) | No hang. A guest that says nothing by then has stopped answering: max lets go of the call, the turn goes on, and Max is told the call may still run. |
| A program's call to one of Max's tools | once, in `service::call`, at the conversation's `call_time_secs` (60 by default, 10 to 600; see [Settings a conversation sets](config.md#settings-a-conversation-sets)); around it max's HTTP service keeps the longest allowed, 600 seconds, for a call that never reaches the actor. Nothing in the tools themselves | No hang. |
| A VM's boot | once, in the VM's machine: SSH must answer within 60 seconds of a boot (`BOOT`), or 10 for a running VM max attaches to, tried every 100 ms | No hang. |
| A VM's idleness | once, in the VM service: a sweep every minute stops VMs idle longer than `idle_minutes` (120 by default), except kept ones (see [Resident programs](jobs.md#resident-programs)) | Policy. |
| Network clients | in the configuration: the LLM's `stream_idle_timeout_secs` (the response headers and each chunk must come within it; the call as a whole has no limit), sqlx's `acquire_timeout`, Postgres's `statement_timeout`, the chat connection's heartbeat. Hard-coded: `max-llm`'s connect timeout; `qqbot`'s REST and gateway timeouts and reconnect backoff; 10 seconds to connect and 60 per chunk for [Host-keyed APIs](tools.md#host-keyed-apis); `maxx events` reconnects after 90 seconds without activity (the host sends a heartbeat every 30), backing off from 1 to 30 seconds | No hang. |
| A question to another conversation | none: it lasts as long as the core that read it, whose idle window is its only clock (see [Asking another conversation](jobs.md#asking-another-conversation)) | Policy. |
| Wait, then escalate | as needed | Policy: a `close` that gives a command time to exit by itself first, say. |
| Waiting tables in resident services | once per table | No leak: the sender's table of messages awaiting receipts, say. Nothing outside a resident service cancels it. |
| Derived-data workers | in each worker, as its constants: download relies on the HTTP client's 10-second connect and 60-second overall timeouts; caption allows 2 minutes a call | No hang; retries and rescans are policy. |
| Model calls outside a turn | once, in `Chosen::complete`: classification and caption call through it; it fetches the whole text and records usage (a failure to record is only logged, as it is for turns). The caller gives the limit (60 seconds for classification, 2 minutes for caption), and there are no retries | No hang. |
| Retry backoff for a turn's model call | once, in the model call's task: 1, 2, 4 and 8 seconds, only while nothing has been said, as many times as the provider's `retries` | Policy. |
| The sender waiting for quota | once, in the QQ sender: past the per-minute quota of proactive messages, it waits until the earliest of them is a minute old | Policy: wait rather than drop. |
| Shutdown graces | once, in `main`: intake 5 seconds, the stop grace 20, the conversation table 25, the sender's drain 15, the runtime 10, all within systemd's 60. Workers aren't waited for | No hang. |

Review rule: `timeout(` and `sleep(` appear only in the places above.

A limit acts only on a future stopped at an `await`. So:

- nothing blocks in async code;
- `spawn_blocking` comes with a cancellation flag, since aborting a
  blocking task that has started does nothing; bounded work may go
  without, such as hashing a file of at most 64 MiB or decoding an image
  within the size limit;
- nothing blocks in `Drop`.

If these rules are broken anyway, systemd's `TimeoutStopSec` is the last
resort.
