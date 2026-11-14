# Lifetimes, cancellation and timeouts

## How resources end

Decided 2026-10-27. A resource can end in two ways, and both are normal paths:

- **Closing**: the owner finishes its work and calls `close().await`. It can wait, it can return an error, and it has its own timeout policy.
- **Cancellation**: the owner itself is cancelled, for example by `/kill`, a timeout, or the expiry of the shutdown grace period. The owner's future is dropped, the resource is dropped along with it, and its `Drop` runs. Every `/kill` takes this path, so it must be designed and tested as a normal path.

Initiating a cancellation is always synchronous: dropping a future, `CancellationToken::cancel()`, closing an fd, sending a kill signal, setting a cancellation flag. Normally nobody waits for a cancellation to actually complete; only at shutdown does `Scope::close` wait for it.

Rules:

1. **`Drop` only initiates, synchronously; it neither blocks nor spawns.** There is no reaper and no Background.
2. **For external resources, the lifecycle is preferably bound to a connection or an fd.** Once the connection drops, the peer winds down on its own; on a crash the kernel also closes the fd, so even crashes are covered.
   - LLM requests: dropping the stream closes the connection.
   - pi: it runs over stdio, so the process can simply be killed.
   - VM commands: each command is a transient unit in the guest (`systemd-run --pipe --wait`, with `RuntimeMaxSec` as the backstop). When the SSH channel closes, the guest does not kill the unit on its own, so rule 3 applies; see `VmCommand` below. The codemode runner is also a VM command (until 2026-11-12 it had a session with the service, revoked synchronously in `Drop`).
   - The VM itself: a unit of the host's systemd, which max has systemd stop (`Machine::stop`) when it is idle, evicted or dead, and leaves alone when max itself stops; see [VM processes](vm.md#vm-processes). Until 2026-11-12 it was a child process of the main process, killed when dropped.
   - The browser: a child process of the runner, connected through a pipe. When the runner exits, Playwright kills it; when the runner is killed, the browser is in the same unit as the runner and is killed along with it. Tested live on 2026-10-29: the next run in the same VM does not see the previous run's browser process.
   - Killing a process means killing the whole tree, using a process group or a cgroup. If only the direct child is killed, the grandchildren stay alive and keep the output pipe open.
3. **For peers that respond only to API calls**, `Drop` uses `try_send` to pass a stop command to the resident service that holds that connection, and that service calls the API. It lives in the services scope and is shut down in order at shutdown.
4. **On a crash, `Drop` does not run.** The VMs are units of their own and run on, with what runs in them: a call the dead max waited for ends at its own limit and clears up after itself, a background command tells the next max of its end, and that max attaches to the VMs as it starts (2026-11-12; until then systemd killed the VMs with the main process, and everything in them). Until 2026-11-12 the service's sessions existed only in memory, so they all became invalid once the process was gone; there are none now, and a call is the VM's.
5. **Only types that must wait for a result or report an error on normal completion have a `close`**, for example to obtain an exit code, to finish sending pending messages, or to commit a transaction. All other types have only `Drop`.
6. **`close` follows ownership.** Whoever owns a value calls it at the end of its own normal path. A struct that owns fields needing `close` must itself have a `close`, which closes those fields in reverse order of creation. `close` takes `self`, so a value can be closed in only one place. A `?` in the body must not skip `close`: first obtain the result, then close, and only then handle the result.
7. **`close` must itself be safe to drop.** If any `await` along the way is dropped, `Drop` can still clean up through the cancellation path. The "fully closed" marker is set in the very last step.
8. **No alarms in `Drop`, and no drop bombs.** Cancellation is a drop, so alarms would only be noise. A forgotten `close` is caught by tests: the fake environment counts the resources that were "killed because the connection dropped", and normal-path tests assert that this count is 0.

```rust
pub struct VmCommand {
    channel: Channel,             // russh channel, closed on drop
    unit: Option<UnitName>,       // transient unit in the guest; set to None once close finishes normally
    stop: mpsc::Sender<UnitName>, // the task that holds this VM's SSH connection
}

impl VmCommand {
    pub async fn read_output(&mut self, limit: usize) -> Result<Output>;

    /// Closing: give the command `grace` time to exit on its own; when time is up, stop its unit, then wait for the exit code.
    /// grace is policy, not insurance against hangs; if it hangs, the timeout of the enclosing tool call drops it.
    pub async fn close(self, grace: Duration) -> Result<ExitStatus>;
}

impl Drop for VmCommand {
    // Only initiates, synchronously: the holder of the connection sends `systemctl stop` over the same connection
    fn drop(&mut self) {
        if let Some(unit) = self.unit.take() {
            let _ = self.stop.try_send(unit); // if it cannot be sent, RuntimeMaxSec takes care of it
        }
    }
}

async fn exec(call: ExecCall, vm: &Vm) -> Result<ToolOutput> {
    let mut cmd = vm.spawn(&call.command).await?;
    let output = cmd.read_output(call.limit).await; // no ? here yet
    let status = cmd.close(EXIT_GRACE).await;       // reached whether or not output succeeded
    Ok(ToolOutput::exec(output?, status?))
}
```

Language-level async drop (`#![feature(async_drop)]`) is still an experimental feature on nightly, with no timeline for stabilisation. Even once it is stabilised, `select!`, `JoinSet` and the runtime all drop futures synchronously, so what runs on cancellation would still be only the synchronous `Drop`; the most it could save is the step of "remembering to call close". It is not used.

## Cancellation safety

With cancellation by drop, every `await` may be the end. The local variables of a dropped future disappear with it, and nobody can observe them stopped halfway; what needs care is only the state that outlives the drop.

The conversation actor itself is never cancelled; it ends only at shutdown, along with the conversations scope. What is normally cancelled is the I/O tasks it spawns. Between the I/O tasks and the actor there are only mailboxes, with no shared mutable state. What a review must examine, therefore, is this: if an I/O task is aborted at an arbitrary `await`, what does it leave behind outside itself?

| Surviving state | What can go wrong | Rule |
| --- | --- | --- |
| The core | It stops in the middle of a state transition. | The core is a field of the actor; transitions are synchronous and happen only while the actor is handling an event. I/O tasks cannot touch it. |
| Words already spoken | A message is sent to the group but not recorded in the ledger. | The segmenter lives in the model-call task and only produces `Said`; the sender takes only segments that the actor has entered in the ledger. Wherever the task is aborted, the result can only be saying less, never something said going unrecorded. |
| The completion event the actor awaits | It never arrives, and the core waits forever. | The receipt sends a substitute "no result" in `Drop`; see [I/O tasks and protocol adapters](core.md#io-tasks-and-protocol-adapters). |
| Platform connections | A frame is half-written and the whole connection breaks. | A shared connection is read and written only by its own task; everyone else hands data over through a channel. |
| The database | A write is left half-done. | Transactions are used. For a connection whose query was dropped midway, sqlx first reads the leftover response before the connection's next use. The actor's database `await`s can be dropped only at shutdown. |
| Turn records | The final write is interrupted at shutdown. | The transaction rolls back, which is equivalent to a crash, and the turn is recorded as `Lost` at startup. |

Only cancel-safe branches go in a `select!` loop:

- **Allowed**:
  - `mpsc::Receiver::recv`, `CancellationToken::cancelled`, `JoinSet::join_next`;
  - `next()` on a `FramedRead` with `LinesCodec`: the buffer lives in the stream, not in the future. `LinesCodec` splits only on `\n`, which meets pi's requirement; a maximum line length must be set;
  - `sleep_until(deadline)`, or a `Sleep` that is pinned outside the loop and reused.
- **Not allowed**:
  - `read_line`, `read_exact`, `write_all`;
  - a `sleep(dur)` created anew on each iteration: every re-creation resets the timer.

Invariants are not modified while a lock is held across an `await`; clippy's `await_holding_lock` catches some of these cases.

Testing has two layers, both of which use tokio's `start_paused`, so the results are deterministic:

1. **The actor**: run a script with a fake provider, fake tools and a fake sender, and record the sequence of events the actor handles, of length N. Then run it N more times, inserting a `/kill` after the k-th event on the k-th run; do one round the same way for stop. Each run checks that:
   - what the fake sender received is exactly Max's messages that were entered in the ledger;
   - old events that arrive after the insertion are all discarded;
   - no commands leaked.
2. **I/O tasks**: drop the task once at each poll point, and check that exactly one completion event was sent, that the fake connection received no half-frame, and that no resources leaked.

## Timeouts

Limits are set only at the boundaries of units of work, and the `await`s inside a unit are not wrapped in timeouts: as soon as the owner is cancelled, any future stuck inside it is dropped along with it.

| Location | How many times it is written | Nature |
| --- | --- | --- |
| `Scope::close(grace)` | Once, in `Scope` | Prevents hangs at shutdown |
| The conversation actor's deadline | One `sleep_until` in the actor's main loop; the deadline is the earlier of the idle window and the stop grace period | Policy: the idle window (the provider's `idle_window_secs`, or the conversation's own; see [Settings a conversation sets](config.md#settings-a-conversation-sets)) and the shutdown grace period. A turn has no wall-clock limit: the actor waits only on the database, and model calls and tools each have limits of their own |
| Tool-call limits | In two places. One per run for `run_code` and `shell`: the limit is the unit's own, `RuntimeMaxSec=` in the guest (120 seconds by default, and a call may ask for up to 600; a background command 6 hours, up to 24; see [Background commands](jobs.md#background-commands)), and max waits 30 seconds past it for the guest to say how the unit ended (`tools::wait`): a call's unit has `TimeoutStopSec=15`, so what won't end at the limit is killed within that wait (2026-11-13; with systemd's own 90 seconds, a call whose processes took longer than 30 to die was told the VM hadn't said how it ended, and lost its output). Until 2026-11-12 max stopped the unit at the limit itself, and the guest's `RuntimeMaxSec` was the later one. One for each call that a program makes to a Max tool, at the conversation's `call_time_secs` (60 seconds by default; see [Settings a conversation sets](config.md#settings-a-conversation-sets)): in `service::call`, which the actor runs for every call (until 2026-11-12 a run's calls were timed in their session's executor, and only a resident program's by the actor); around it max's service keeps the longest allowed, 600 seconds, for a call that never reaches the actor. Nothing is written in the individual tools. A guest that hasn't said how a call ended by then has stopped answering: max lets go of the call, the turn goes on, and Max is told that it may still run. Letting go of a call closes its channel, and the guest stops the unit of a call whose caller is gone, as it does for a killed turn's (2026-11-13; until then a task of the VM's, the stopper, stopped such units by name, side by side, each for 120 seconds) | Prevents hangs |
| VM boot | Once, in the VM service: SSH must be reachable within 60 seconds, tried every 100 ms; 5 seconds of waiting for virtiofsd to create its socket; an outer limit of 70 seconds around both | Prevents hangs |
| VM idle | Once, in the VM service: a scan every minute shuts down VMs that have been idle for longer than `idle_minutes` (default 120), except those that are always on (see [Resident programs](jobs.md#resident-programs)), and those booted from an image a deploy has replaced once they have been quiet for 10 minutes (`QUIET`), to boot the new one. A VM in which a background command runs isn't idle: the same scan's task asks the guest | Policy |
| Network clients | Once, in the configuration: the LLM's `stream_idle_timeout_secs` (the response headers and each subsequent chunk must arrive within this time; the call as a whole has no limit), sqlx's `acquire_timeout` and Postgres's `statement_timeout`, and the platform connection's heartbeat. Hard-coded: the connect timeout in `max-llm`; the REST connect and read timeouts, the gateway's connect timeout and the reconnect backoff in `qqbot`; a 10-second connect timeout and a 60-second per-chunk timeout for [Host-keyed APIs](tools.md#host-keyed-apis); `maxx events` reconnects after 90 seconds without activity (the host sends a heartbeat every 30 seconds), with a backoff from 1 second to 30 seconds; see step four of [Resident programs](jobs.md#resident-programs) | Prevents hangs |
| A question's wait | None since 2026-11-12: a question lasts as long as the core that read it, whose idle window is its only clock. Until then once, in the job the asking actor kept for it: `ASK_WAIT`, 2 hours | Policy; see [Asking another conversation](jobs.md#asking-another-conversation) |
| Wait first, then escalate | As needed | Policy, for example `close` first giving the command time to exit on its own |
| Waiting tables in resident services | Once per table | Prevents leaks, for example the sender's table of messages awaiting receipts. No cancellation from outside a resident service acts as a backstop for it |
| Derived-data workers | One place in each worker, with the values as its constants: download relies on the HTTP client's 10-second connect timeout and 60-second overall timeout, and waits 1 second and then 4 seconds before retrying; caption allows 2 minutes per call; embedding allows 30 seconds per request | Prevents hangs; retries and rescans are policy |
| Model calls outside a turn | One place, `Chosen::complete`. Classification and caption both call through it; it fetches the full text and records usage (if usage cannot be recorded, it only logs this and the result is still used; the same now applies to turns and jobs, changed on 2026-10-30: previously, a failure to record a turn's usage made the whole conversation actor exit). The limit for the whole call is given by the caller (60 seconds for classification, 2 minutes for caption), and there are no retries | Prevents hangs |
| Retry backoff for model calls | Once, in the model-call task: 1, 2, 4 and 8 seconds. A call is retried only while nothing has been said yet, and the number of retries is the provider's `retries` | Policy |
| The sender waiting for quota | Once, in the QQ sender: when proactive messages exceed the per-minute quota, it waits until the earliest of them is a full minute old | Policy: wait rather than drop |
| Grace periods at each level of shutdown | One place, in `main`: intake 5 seconds (to save the gateway session), conversation stop 20 seconds (letting the core finish what it is doing, then interrupting it on expiry), conversation table 25 seconds, sender drain 15 seconds, runtime 10 seconds, which together fit within systemd's 60 seconds. Derived-data workers are not waited for: the units they are working on are either filled in by a scan at the next startup or abandoned | Prevents hangs |

Review rule: `timeout(` and `sleep(` appear only in the places listed in the table above.

Precondition: a limit only takes effect on a future that is stopped at an `await`. Therefore:

- there is no blocking in async code;
- `spawn_blocking` is paired with a cancellation flag, because abort has no effect on a blocking task that has already started running; bounded computations may go without one, such as hashing a file of at most 64 MiB or decoding an image within the size limit;
- there is no blocking in `Drop`.

If these rules are nevertheless broken, systemd's `TimeoutStopSec` still provides the backstop at the outermost level.
