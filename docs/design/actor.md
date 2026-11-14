# The conversation actor

## The conversation actor

The conversation actor is a conversation's only thread of control: it is both the only writer of the timeline (see [The timeline](ledger.md#the-timeline)) and the driver of the core. On 2026-10-26 it was decided to be ordinary async code with no persisted state; on 2026-10-27 it changed to a single core instance, with at most one core per conversation at any moment and no request queue; on 2026-10-28 it changed so that the actor drives the core directly.

The core is a field of the actor. Model calls, tool calls and intent classification are all spawned as I/O tasks (see [I/O tasks and protocol adapters](core.md#io-tasks-and-protocol-adapters)), and their results return to the same mailbox as events. The actor itself awaits only the database and never waits on models, tools or the network, so a `/kill` can always be handled immediately. A conversation has only this one thread of control, so there are never two copies of state to keep in agreement.

```rust
struct Conversation {
    head: MessageId,           // see "The timeline"
    seen: MessageId,
    core: Option<Active>,
    intent: Intent,            // a pure state machine, see "Intent": hold, accumulated messages, the classification in flight, counters
    side: Scope,               // intent classification
    stopping: Option<Instant>, // when the stop grace period expires
    // shared handles: database, sender, conversation table, models; the sending end of its own mailbox, handed to I/O tasks
}

struct Active {
    turn: TurnId,
    run: Run,                  // the core; for its interface see "The core"
    from: MessageId,           // snapshot position
    io: Scope,                 // model calls and tool calls in flight
    live: HashSet<TaskId>,     // numbers of the tasks in flight; events from tasks not listed here are stale
    said: String,              // text from this model call already entered in the ledger; on interruption, this is the partial_output
    idle_since: Instant,       // when the last model output ended; the idle window is counted from here
    started: Instant,          // for /status
}

enum Event {
    Inbound(Inbound),                                  // from a platform connection, via the conversation table
    Bound(Inbound),                                    // the `/bind <code>` that has just bound this group, see "The official QQ bot"
    Said { task: TaskId, segment: Segment },           // a segment cut out by the segmenter in the model-call task
    ModelDone { task: TaskId, out: Result<ModelOutput, String> },
    ToolDone { task: TaskId, call: CallId, out: ToolOutput },
    Verdict(Option<Verdict>),                          // the verdict for the batch in flight; None on failure
    Stop,                                              // a normal restart
    // Later: Post (another conversation, an MCP tool or the scheduler sending here, carrying the originating turn), JobDone, Fire
}

impl Conversation {
    async fn run(mut self, mut mailbox: UnboundedReceiver<Event>) -> Result<()> {
        loop {
            let deadline = self.deadline(); // the earliest of the idle window, the debounce and the stop grace period
            tokio::select! {
                event = mailbox.recv() => match event {
                    Some(event) => self.handle(event).await?, // awaits only the database
                    None => self.stop(),
                },
                () = sleep_until(deadline.unwrap_or_else(Instant::now)), if deadline.is_some() => {
                    self.timer().await?;
                }
            }
            self.advance().await?;
            if self.stopping.is_some() && self.core.is_none() {
                return Ok(());
            }
        }
    }

    /// Called once after every event: when the core has no I/O in flight, decides the next step
    async fn advance(&mut self) -> Result<()> {
        let Some(a) = self.core.as_mut() else { return Ok(()) };
        if a.run.busy() {
            return Ok(()); // wait for events from the tasks in flight
        }
        if self.stopping.is_some() && a.run.idle() {
            return self.end(End::Idle).await; // stopping: a core with nothing on hand ends at once, without waiting for the idle window
        }
        if a.run.at_limit() || (a.run.idle() && a.run.near_limit()) {
            // at the limit, give up; nearly full with nothing to do, end; the next trigger projects afresh from the ledger and starts a new core
            let how = if a.run.idle() { End::Idle } else { End::Failed(FailReason::ContextExhausted) };
            return self.end(how).await;
        }
        match a.run.next_step() {
            Step::CallModel(req) => {
                self.seen = self.head; // the request includes all accumulated input, which is exactly ..=head
                a.spawn_model(req);
            }
            Step::RunTools(calls) => {
                for call in calls {
                    a.spawn_tool(call);
                }
            }
            Step::Idle => {} // deadline() computes the idle window from idle_since
        }
        Ok(())
    }
}
```

`handle` does two things in order, and the third is the `advance` above:

1. **Entering in the ledger**: messages and events from platforms, `Post`s, and segments that Max has said are first entered in a single transaction, `head` advances, and then an entry notification is sent to the derived-data workers (see [The three roles](../architecture.md#the-three-roles)). After a `Said` is entered, it is handed to the platform sender without waiting for a receipt; see [Outbound](ledger.md#outbound).
2. **Routing**:
   - Commands: always handled by the actor itself and never passed into the core (decided 2026-10-28). So `/model` does not become input to the model, and `/kill` need not queue behind a tool batch. The command message itself is still entered in the ledger and is visible in the next core's tail. Intent sees it too.
   - If there is a core: the entry is fed to it, except for what the current turn itself has said and done, which is already in the transcript. Actions taken through tools are recognised by the `origin` of their `Post`; see [Outbound](ledger.md#outbound). The same applies to job results and automations. (Since 2026-11-12 a `Post` has no origin: what a tool says or does isn't fed to the running core whoever called it, as its row is Max's account's own.)
   - [Intent](intent.md#intent-1): every entry is passed to `intent.observe`, verdicts are passed to `intent.verdict`, and `intent.tick` is called when a deadline is reached. A returned `Wake` is first checked against `seen`: if none of the messages it concerns lies beyond `seen`, it is dropped; otherwise, if there is a core, it is fed an `Input::Wake`, and if there is not, a core is started (step 3 of [Processing flow](#processing-flow)). `Classify` spawns the small model in `side`. When there is neither a core nor a `Wake`, nothing is done: the messages are on the timeline and will be in the next core's base context.
   - `ModelDone` and `ToolDone` are fed to the core; those whose task number is not in `live` are dropped.

`Stop` only records when the stop grace period expires (20 seconds), and the core carries on as usual. When a deadline is reached: if it is the stop grace period that has expired, `end(End::Stopped)` follows, and if it is the idle window, `end(End::Idle)`; see [Cancellation](#cancellation). Expiry of a debounce is handled by `intent.tick`.

Two further points:

- The mailbox is unbounded. The writers to a mailbox include the shared platform connections and other actors: if they had to wait on a bounded mailbox, one stuck conversation would hold up every conversation, and two conversations sending `Post`s to each other could deadlock. The actor itself never awaits on a bounded channel either.
- Ending a core needs no handover channel. Whatever is entered in the ledger after the end is handled directly by the actor; if there is a trigger, the actor starts the next core, using the same function as for "a trigger arrives when there is no core".

In this way, when several people @ Max at the same time, the model responds to all of them together within the same batch of input and does not answer twice; nor do problems arise of queue order, per-person limits, expiry, or "feedback or a new request". The correspondence with Claude Code: new messages in the group are steers, job results are background-task completion notifications, and automations are scheduled triggers. A restart loses the following:

- The running core: on a normal restart it is given a grace period and is interrupted when that expires; on a crash it is simply lost. See [Restarts](#restarts).
- The questions another conversation asked the running core: who asked them hears nothing more, and may ask again. What runs in the VM is not lost with max: a background command and a background agent are units of the guest's, and run on.
- All of intent's state: the hourly counts are reset to zero, chatter awaiting classification is no longer classified, and direct triggers still being debounced are dropped and go unanswered (accepted 2026-10-28).

## Processing flow

Each step is the conversation actor handling one event.

1. **A message comes in**: the platform connection normalises the message or event into an `Inbound` and hands it, via the conversation table, to the conversation actor; the actor converts it into a `Message` and enters it in the ledger in a single transaction. The platform connection does not touch the database.
   - The group allowlist (decided 2026-10-28) is enforced at the conversation-table step: messages from a QQ group that has not been bound with `/bind` (see [The official QQ bot](qq.md#the-official-qq-bot-1)) are simply dropped: no conversation is created, no actor is started and nothing is entered; only a debug log line is written. Commands and the owner's messages are dropped in the same way, the only exception being `/bind <code>`. A `Post` from another conversation or a tool to an unbound group is also refused here, and if it carries a reply channel, an error is sent back. Private chats do not pass through this check; see step 2.
2. **Classification** (changed 2026-10-28): every entry is passed to [Intent](intent.md#intent-1), which decides when to wake the core: an @ or a reply to Max wakes it immediately, though a message that looks unfinished waits a few seconds first; other messages are judged by the small model. Job results and automations do not go through intent; they are triggers in themselves. For trigger sources, see [The three roles](../architecture.md#the-three-roles). Commands are handled by the actor itself; see [The conversation actor](#the-conversation-actor-1).
   - If a core is running: messages are still fed to it immediately, but only triggers make it call the model.
   - If there is no core: a trigger proceeds to step 3; otherwise nothing is done.
   - Private chats (decided 2026-10-28): every message in a private chat counts as a direct trigger, equivalent to an @ in a group. On QQ, the only people who can chat privately with Max are the trial users added in the management console, and that list is the private-chat allowlist; see [The official QQ bot](qq.md#the-official-qq-bot-1). If a platform connected later lets anyone chat privately, a separate allowlist will be added, and an empty allowlist will mean serving no one, the opposite of the Haskell version's "empty means serve everyone".
3. **Starting a turn**: the snapshot position is set, `from = head`. The base context is projected from the ledger (reading only `id <= from`) plus memory and trimmed to the budget; see [Context projection](context.md#context-projection-1). The first batch of input is in the volatile block: the trigger that woke the core, with the `Wake` carrying the messages it concerns (several messages from the same person, when debounced). All other messages are in the tail. `TurnStarted` is written (with the trigger and `from`), and `Run::new(spec, base, first)` is called. If the first batch alone exceeds the core's limit (see "Round and token limits" in [The core](core.md#the-core-1)), the core hits the limit as soon as it starts: `Failed(ContextExhausted)` is recorded and a one-line reply quoting the trigger is sent (changed 2026-10-29; previously no core was started, and a separate `InputTooLarge` was recorded).
4. **Advancing**: each time the actor has finished handling an event and the core has no I/O in flight, the actor asks for `next_step`. No turn records are written midway:
   - `CallModel`: `seen = head`, and a model-call task is spawned. Each `Said` is entered in the ledger and handed to the sender; on `ModelDone`, `model_output` is called. Accumulated input is rendered as one `[新消息]` ("new messages") block appended to the end of the request; see [Follow-up input](context.md#follow-up-input).
   - `RunTools`: one task is spawned for each tool call in the batch, and they run concurrently in the group VM; `tool_result` is called once for each `ToolDone`.
   - `Idle`: nothing is done, and whatever is entered afterwards is still fed in; if it is only chatter, `next_step` remains `Idle` and the window is not reset. The run ends after a full window of idleness since the last model output ended (the provider's `idle_window_secs`, 300 seconds by default, decided 2026-10-27, unless the conversation set its own; see [Settings a conversation sets](config.md#settings-a-conversation-sets)). If a trigger arrives within the window, the model still holds the tool results from just before, so follow-up questions need no repeated lookups. When expiry and a trigger arrive at the same time, the actor always handles one of them first: if expiry comes first, the run ends and the trigger then starts a new core; if the trigger comes first, the run continues. Both outcomes are correct.
   - **Hitting the limit**: when the core reports `at_limit`, the run ends at this boundary: if the core is idle, this counts as a normal end; otherwise `Failed(ContextExhausted)` is recorded, and the unhandled direct triggers get a one-line reply (changed 2026-10-29). Past 90%, the model is first reminded to wrap up, and an idle core past 90% also ends; see the nearly-full reminder in [The core](core.md#the-core-1) (2026-11-01). The next trigger projects afresh from the ledger and starts a new core as usual; this is our compaction: rather than compressing the transcript, we project again.

     Originally (decided 2026-10-27) the core was replaced at this point: the unhandled triggers were handed to a new core together with a one-line handover note listing the calls with side effects that the old core had made, so that they would not be made again; each trigger could be handed over at most once; and there was a 30-minute wall clock. Hitting the limit almost never happens, and the cost of giving up is only that someone has to ask again, so these mechanisms were not worth having (removed 2026-10-29).
   - **Failure**: `ModelDone` carries an error. The text from this call already entered in the ledger is recorded as `partial_output`, `fail` is called, and the snapshot and outcome are written.
5. **Cancellation (`/kill`)**: see [Cancellation](#cancellation). Accumulated input is discarded.
6. **Normal restart and startup**: see [Restarts](#restarts).

## What the group sees

Changed 2026-10-28: no status is shown during processing. The Haskell version put a "托腮" (chin in hand) face on the triggering message and replaced it with "裂开" (cracking apart) on failure; the official QQ API has no reactions.

- When a turn fails or is interrupted by a restart, a one-line error is sent, quoting the newest of the direct triggers that have not yet been handled (see "Definition of handled" in [The core](core.md#the-core-1)). There is no reaction to swap, and without a reply the person who @-mentioned Max would see nothing. Triggers woken by classification get no reply: Max is free not to join in anyway.
- The error looks like a log line (changed by the owner 2026-11-06): it is placed in a `text` code block as `error: <what happened>: <cause>`, with the cause given as it is, newlines and runs of whitespace collapsed into a single space, and anything beyond 300 characters truncated with `…`, so that, as with command responses, it is obvious at a glance that the system sent it. Previously it was plain human language such as "出错了，这条没回上。" ("something went wrong, this one didn't get a reply") or "我要重启一下，这条没回上，等会儿再问一次吧。" ("I need to restart, this one didn't get a reply, please ask again in a while"), which gave no indication of what had actually gone wrong. The kinds of error:
  - Provider error: `error: the model call failed: the provider answered 429: …`; the cause is the error from max-llm.
  - `ContextExhausted`: `error: the context is full: 530000 tokens, limit 524288`; it can be resolved by rephrasing, pasting less and sending again.
  - Restart: `error: interrupted: Max is shutting down, and the turn outlasted the 20s grace`.
  - Conversation actor error: `error: the conversation failed: <error chain>`; see [Restarts](#restarts).
- `/kill` gets no reply: someone stopped the turn deliberately. `/stop` (see [Commands](context.md#commands)) ends the turn the same way, and its reply says only that Max is stopped.
- This line is entered in the ledger as usual and does not go into the core. It was not written by Max: its `raw` is `{"said_by": "host"}`, and when rendered, its header carries an extra `  系统发的 ` ("sent by the system") (`Mark::Host`): `[12:00 maxx #45 系统发的]: error: the model call failed: …`. Command responses and the line reporting a stopped job are treated the same way (added 2026-11-04). Previously these lines looked just like Max's own words, and the next core would take them as things it had said itself and carry on in the same tone. The prompt explains this mark. In `maxx events`, `by` is still `max`: the message was sent from Max's account, and programs simply should not reply to it.

## Cancellation

`/kill` is simply an event that the actor handles; it needs no separate signal and no waiting inside `select!`: `seen = head`, and if there is a core, `end(End::Kill)`. The core's other ways of ending go through the same function and differ only in the middle step:

```rust
enum End {
    Kill(String), // /kill
    Failed(FailReason),
    Idle,         // idle: the window expired, or Max is stopping
    Stopped,      // Max is stopping, and the core was still not idle when the grace period ran out
}

async fn end(&mut self, how: End) -> Result<()> {
    let Some(mut a) = self.core.take() else { return Ok(()) };
    drop(a.io); // aborts the model stream and tool calls in flight: initiated synchronously, without waiting
    if !a.said.is_empty() {
        a.run.partial_output(a.said.join("\n\n"), tokens); // text from the interrupted model call already entered in the ledger
    }
    match &how {
        End::Kill(reason) => a.run.interrupt(reason.clone()), // fills in "已取消" ("cancelled") for tool calls that have not returned
        End::Stopped => a.run.interrupt("Max 在重启".into()), // "Max is restarting"
        End::Failed(reason) => a.run.fail(reason.clone()),
        End::Idle => Ok(()),
    };
    turns::finish(&mut conn, a.turn, &a.run.record(), &a.run.outcome(), now).await?; // snapshot plus outcome, in one transaction
    self.report_unanswered(&a.run, &how).await // unhandled direct triggers get a one-line reply, see "What the group sees"
}
```

- Events that tasks in `io` have already sent but that have not yet been processed are dropped when they arrive, since their task numbers are no longer in `live`. Whether something was "said" is determined by its entry in the ledger: a `Said` that is already in the mailbox but not yet entered is dropped and counts as not said; the sender never received it either.
- Expiry of the idle window and hitting the limit both happen at boundaries, with no I/O in flight, so there `drop(a.io)` does nothing.
- Writing the turn record awaits the database; events that arrive in the meantime queue in the mailbox and are processed once the write is complete.

Places where drop alone is not enough and an extra step is needed:

- **The outermost level of every task that owns a scope**: a single `run_until_cancelled` or `select!`. For the conversation actor, this is its main loop.
- **Things with external side effects that drop does not stop automatically**: for example, commands in the VM and pi processes. Their lifetime is bound to a connection, and `Drop` only initiates the shutdown synchronously; see [How resources end](lifetimes.md#how-resources-end).
- **Things that must not be done halfway**: sending a message enters it in the ledger first and then hands it to the platform sender; database writes use transactions, and an sqlx transaction that is dropped before it commits rolls back. For the rest, see [Cancellation safety](lifetimes.md#cancellation-safety).
- **Long CPU computations without an `await` point**: these cannot be dropped. They go into the scope's `spawn_blocking`, paired with a cancellation flag.

## Restarts

Decided 2026-10-29: on a normal restart, a running turn is given a grace period and is interrupted when it expires; it is no longer suspended and continued after the restart. The Haskell version also interrupts turns on restart.

Originally (decided 2026-10-26, brought into v1 on 2026-10-28), the turn was suspended at the next boundary and a snapshot was stored; after the restart it was resumed (`resume`) within a window, with unfinished tools given the result "进程重启，结果未知" ("process restarted, result unknown") before continuing. This required attempts, several snapshots per turn, `TurnResumed`, `Expired`, and re-checking permissions on resumption. It is rare for a turn to be running at the moment of a deploy, and the person who was interrupted can simply ask again, so this was not worth it.

- **Normal restart (deploy, SIGTERM)**: the conversation actor receives a stop event and records when the grace period expires (20 seconds). If the core is idle, it ends immediately, without waiting for the idle window. If it is not, it keeps running: model calls, tool batches and subsequent model calls all proceed as usual, and if it becomes idle within the grace period, it ends normally. If it is still not idle when the period expires, it ends with `End::Stopped` (see [Cancellation](#cancellation)):
  - `io` is closed, and the text already entered in the ledger is recorded as `PartialOutput`;
  - tools in the same batch that have finished record their results as usual, and unfinished ones are given "已取消" ("cancelled");
  - the outcome is `Interrupted`, and the snapshot and outcome are written together;
  - a direct trigger that has not yet been handled gets a reply quoting it, `error: interrupted: …` (see [What the group sees](#what-the-group-sees)); this line is handed to the sender as usual, and at shutdown the sender exits only after its queue has drained.
- **Crash**: nothing is written.
- **Conversation actor error** (added 2026-10-30): if the actor hits an error while handling an event (most likely a database error), it gives up on that conversation. The core and the jobs are stopped; the conversation's turns that have no outcome are recorded as `Lost`, as with a crash, so that they do not appear to be still running; unhandled direct triggers get a one-line reply, `error: the conversation failed: <error chain>` (joined with ` :  ` as `{:#}` does; sqlx database errors already end with their source, and such duplicates are not appended again); until 2026-11-12 the jobs it stopped were reported too, with a line `stopped: agent#3, shell#4` below the same error; the actor keeps none now, and a failing actor stops nothing in the VM. If the database cannot be reached, only a log entry is written, and those turns are left for the next startup to record. Afterwards, the conversation table starts the actor again when it receives the next message for that conversation; messages that arrive at the very moment the actor exits are lost with it. Errors are not isolated per event with the actor left to continue, because after an error the in-memory `head` and `seen` may no longer match the database.

At startup, every turn without an outcome is recorded as `Lost`: a normal restart leaves no turn without an outcome, so any that remain can only be turns that were running at a crash. The messages such a turn had already sent are still in the ledger and can be found by turn id. Each conversation's `seen` starts from the `head` at that moment, and intent's state starts empty.

The QQ gateway resumes (Resume) across restarts: what was said in groups during the restart is redelivered by the server, and is entered in the ledger and passed through intent as usual, so people who @ Max while it is down still get replies; see [The official QQ bot](qq.md#the-official-qq-bot-1). The only message that has to be asked again is the one being answered at the moment of shutdown.

Whether to announce in the group a turn that was lost in a crash is **TBD**: a notice could be sent after startup on the basis of `Lost`.

## Size and retention

- **Size**: reasoning blobs are a few KB to a few tens of KB each and do not compress well; a turn running dozens of rounds comes to roughly a few hundred KB to a few MB, capped by the core limit. In v1 everything is stored in the snapshot's JSONB and left to Postgres's TOAST. If size becomes a problem later, content above a threshold will be moved, uniformly, to a blob table addressed by sha256; the same applies to tool output and the base context.
- **Retention**: N days after a turn ends, the `opaque` fields and the base context are cleared from its snapshot, and the readable text and token counts are kept. The turn can still be viewed afterwards, but its requests can no longer be resent exactly as they were. N is **TBD**.

## Testing the core and the actor

- The core and intent are tested with synchronous unit tests that feed inputs from a script and check the outputs, needing neither tokio nor a fake provider; intent's time is passed in by the test. Intent tests cover at least: direct triggers waking at once, debouncing merging several messages from the same person, batching, the hourly cap and `/proactive`. Core tests cover at least: when input is delivered, no model call when there is only chatter, completing the results on interruption, malformed tool calls, the round and transcript limits, and which triggers count as unhandled on failure.
- The conversation actor is tested with a real database (`#[sqlx::test]`), a scripted model and a sender that only records, covering cancellation, stopping and its grace period, the idle window, hitting the limit, stale events, and the filtering of `Wake`s by `seen`; for the exhaustive insertion of `/kill` between any two events, see [Cancellation safety](lifetimes.md#cancellation-safety). Changed 2026-10-29: actor tests use real time, not `start_paused`. While the actor is waiting on Postgres, a paused clock automatically jumps to the next deadline, so the idle window and the debounce would arrive early. The waits in the tests are therefore all short, and bounded; purely time-based logic (intent, the sender's quota) still uses `start_paused`.
- The protocol adapter layer uses recorded Responses and Chat responses as fixtures, testing that reasoning entries and opaque fields make the round trip unchanged.
- The snapshot holds the content of every request, so any model call made in production can be resent exactly, offline.
- The segmenter's cutting (`segment/chunk.rs`) is written in the subset of Rust that Aeneas can translate (decided 2026-11-06): `verify/extract` uses Charon and Aeneas to translate it into Lean, the translated code is committed in `verify/MaxCore/`, and `verify/` proves properties on top of it. The Rust code remains the only implementation. Proved so far: pushing the text in in several pieces is the same computation as pushing it all at once; used as `segment.rs` uses it (with a fresh `out` for each push), it also cuts out the same segments; and every segment except the last closes its fences (as judged by `closes_fences`). The last property relies on a check in `cut` that emits only closed segments; that this check never holds back a segment outside a fence is checked by the tests in `chunk.rs`. However UTF-8 text is split into pushes, even when characters are split apart, every segment cut out is UTF-8 (added 2026-11-06), so the lossy fallback in `segment.rs`'s conversion to `String` is never used; for this, `trim` was changed to look only at `s[from..to]`, and the bounds check in `space_at` was rewritten in a form that cannot overflow. The segmenter always returns (added 2026-11-06): it never goes out of bounds, never overflows and never loops forever, and as long as the text is shorter than roughly half of `usize::MAX`, every `Vec` fits; what it holds and emits never exceeds twice the size of the text. For this, the counter in `is_break` was changed from an inferred `i32` to `usize`; otherwise a line with more than 2³¹ non-whitespace bytes would overflow it. Apart from `<think>` segments, whitespace, `[split]` and thematic breaks, nothing in the text is lost (added 2026-11-07): however the text is split into pushes, and not counting newlines, the segments cut out, concatenated, are the lines of the text outside `<think>` segments, cut at `[split]` and at image handles, with thematic breaks removed and some whitespace removed, in the original order. To keep the statement simple, what is proved is slightly broader than what actually happens: newlines are disregarded on both sides, a `[split]` inside code is also treated as droppable, and a `<think>`, wherever it appears, may or may not count as the start of a segment. When `chunk.rs` or `verify/` changes, CI's Verify workflow (`.github/workflows/verify.yml`) translates the code again, compares the result with the committed `verify/MaxCore/` and builds the proofs; it does not run otherwise, because Charon and Aeneas are not in any binary cache and require downloading a Rust toolchain of more than ten GB. The hand-written character-level model and `verify/diff/`, which cross-checked the code against it, were removed (decided 2026-11-06): the properties to be proved are all proved on the translated code, and the model was merely a second implementation that had to be changed whenever the Rust changed.

## Other uses of the same pattern

The criteria are protocol state, complex rules and a need for precise testing. The following meet them:

- The streaming segmenter: fed increments of text, it emits paragraphs ready to be sent.
- The QQ gateway session: heartbeat, Resume and reconnection.
- Mirrored delivery (not in v1): reconciling receipts and echoes.

The conversation actor is ordinary async code: the rules all live in the core and the segmenter, and the actor is responsible only for entering messages in the ledger, routing, and spawning tasks as the core directs.

## Open questions

- ~~How the base context is stored~~: decided (2026-10-27): the rendered result is stored; see [Context projection](context.md#context-projection-1).
- The retention period N.
- The margin in the core limit (proposed: 5% of C).
- ~~Permissions for `/kill`~~: decided (2026-10-29): the group owner, administrators and the owners; see [Permissions](identity.md#permissions).
- ~~Trimming rules~~: decided (2026-10-28): no trimming; see "Building requests" in [The core](core.md#the-core-1).
- ~~How long the recovery window should be~~: there is no longer any recovery (2026-10-29); see [Restarts](#restarts). Whether turns and jobs lost in a crash should be announced in the group.
