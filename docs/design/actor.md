# The conversation actor

The conversation actor (`crates/max/src/conversation/actor.rs`) is a
conversation's only thread of control: the only writer of its timeline
(see [The timeline](ledger.md#the-timeline)) and the driver of its core.
There is at most one core per conversation at a time, and no request
queue.

The core is a field of the actor. Model calls, tool calls, intent
classification and the calls of programs in the group's VM are spawned
as tasks (see [I/O tasks and protocol adapters](core.md#io-tasks-and-protocol-adapters)),
and their results return to the same mailbox as events. The actor itself
awaits only the database, never a model, a tool or the network, so a
`/kill` is always handled at once, and there are never two copies of a
conversation's state to keep in agreement.

## State and events

Abridged from the code:

```rust
pub struct Conversation {
    place: Arc<Place>,          // the conversation and its chat
    settings: Settings,         // what the conversation set with /config; see config.md
    head: MessageId,            // the last row entered; see "The timeline"
    seen: MessageId,            // everything up to here has been in a model request
    core: Option<Active>,
    intent: Intent,             // a pure state machine; see intent.md
    side: Scope,                // the classifier, and the calls of programs in the VM
    stopping: Option<Instant>,  // when the stop grace runs out
    addressed: HashMap<IdentityId, Instant>, // who addressed Max lately; see "Starting a model call over"
    asked: asking::Asked,       // questions from other conversations, kept for their answers
    woken: woken::Woken,        // the VM's wakes in the last hour, shown to Max with each wake
    subscribers: broadcast::Sender<Arc<Message>>, // every row entered, for `maxx events`
    // plus shared handles and the sending end of its own mailbox, handed to tasks
}

struct Active {
    turn: TurnId,
    run: Run,                   // the core; see core.md
    chosen: Chosen,             // the model the turn uses
    io: Scope,                  // the model call and tool calls in flight
    live: HashSet<TaskId>,      // tasks in flight; events from any other are stale
    voice: Voice,               // what its model calls have said, and the call in flight
    from: MessageId,            // the snapshot position
    idle_since: Instant,        // when the last model output ended; the idle window counts from here
    started: Instant,           // for /status
    // plus the turn's ordinal and the time of the last row the core saw, for date lines
}

pub enum Event {
    Inbound(Inbound),           // from the chat's connection, through the conversation table
    Bound(Inbound),             // the `/bind <码>` that just bound this group; see qq.md
    Post(Post),                 // something to say or do that isn't the model's text, such as a tool's picture
    Said { task, segment },     // the segmenter cut a message out of the model's stream
    ModelDone { task, out },
    ToolDone { task, call, out },
    Verdict(Option<Verdict>),   // the classifier's answer; None if it failed
    Request(Request),           // a tool asks something of the conversation: configure, ask, answer, wake, may a mute go ahead
    Heard(Heard),               // a wake from outside the chat: the VM service, or another conversation's question or answer
    Call { tool, args, reply }, // something in the group's VM calls one of Max's tools
    Subscribe(reply),           // a program in the VM follows the timeline: `maxx events`
    Stop,                       // Max restarts
}
```

The main loop waits on the mailbox and on one deadline, the earliest of
the idle window, intent's debounce and the stop grace (a single
`sleep_until`). After every event it calls `advance`:

1. If the core has I/O in flight, there is nothing to do.
2. If Max is stopping and the core is idle, the core ends.
3. If the core is at its limit, or idle and past nine tenths of it, the
   core ends: normally if idle, otherwise with `ContextExhausted`.
4. Otherwise it asks for `next_step`. `CallModel` sets `seen = head`
   (the request holds every waiting input, which is exactly `..=head`)
   and spawns the model call; `RunTools` spawns one task per call;
   `Idle` does nothing, and the deadline counts the idle window from
   `idle_since`.

Handling an event does two things, in this order:

1. **Entering it in the ledger.** Messages and events from the chat,
   `Post`s and the segments Max said are entered in one transaction each,
   `head` advances, and an entry notification goes to the derived-data
   workers (see [The three roles](../architecture.md#the-three-roles)). A
   `Said` is handed to the platform sender after it is entered, without
   waiting for a receipt; see [Outbound](ledger.md#outbound).
2. **Routing it.**
   - Commands are handled by the actor itself and never reach the core,
     so `/model` is no input to the model and `/kill` doesn't wait behind
     a tool batch. The command's message is still entered, and the next
     core and intent see it. See [Commands](context.md#commands).
   - If there is a core, the entry is fed to it, except what Max's own
     account said or did through a tool, which isn't fed back to the core
     whoever called the tool.
   - Every entry goes to `intent.observe`, verdicts to `intent.verdict`,
     and `intent.tick` runs at its deadline. A returned `Wake` is dropped
     if none of its messages is past `seen`; otherwise it is fed to the
     core as `Input::Wake`, or starts a core if there is none (step 3 of
     the [Processing flow](#processing-flow)). `Classify` spawns the small
     model in `side`.
   - `ModelDone` and `ToolDone` are fed to the core; those from a task
     not in `live` are dropped.

The mailbox is unbounded: its writers include the shared chat connection
and other actors, and if they had to wait on a bounded mailbox, one stuck
conversation would hold up all the others, and two conversations asking
each other could deadlock. The actor never awaits a bounded channel
either.

Ending a core needs no handover. What is entered after the end is handled
by the actor; a trigger starts the next core by the same path as a
trigger with no core.

So when several people @ Max at once, the model answers them together in
one batch of input and never twice, and there is no queue order, no
per-person limit and no expiry to get right. In Claude Code's terms, new
messages in the group are steers and wakes from the VM are background
completions.

## Processing flow

Each step is the actor handling one event.

1. **A message comes in.** The chat's connection normalises it into an
   `Inbound` and hands it, through the conversation table, to the actor,
   which converts it into a `Message` and enters it. The connection never
   touches the database.
   - The conversation table drops messages from a QQ group that hasn't
     been bound with `/bind` (see [The official QQ bot](qq.md)): no
     conversation is created, no actor started, nothing entered, only a
     debug line logged. Commands and the owner's messages are dropped the
     same way, except `/bind <码>` itself. What the VM service or another
     conversation sends is addressed to a conversation, which a group has
     only once it is bound; the table starts its actor if it isn't
     running. Private chats don't pass this check: one gets a
     conversation the first time someone writes.
2. **Intent.** Every entry goes to [Intent](intent.md), which decides
   when to wake the core: an @ or a reply to Max wakes it at once, after
   a few seconds' wait if the message looks unfinished; other messages are
   judged by the small model. Wakes from outside the chat (`maxx wake`,
   the VM service, another conversation's question or answer) don't go
   through intent; they are triggers themselves.
   - With a core running, messages are fed to it at once, but only
     triggers make it call the model.
   - With no core, a trigger goes on to step 3; anything else is left on
     the timeline for the next core's base context.
   - Every message in a private chat is a direct trigger, like an @ in a
     group. On QQ the only people who can chat privately with Max are the
     trial users added in the management console, and that list is the
     allowlist. A platform where anyone can chat privately would need an
     allowlist of its own, empty meaning no one.
3. **Starting a turn.** The snapshot position is set, `from = head`. The
   base context is projected from the ledger (rows up to `from`) and the
   memory file, within the budget; see [Context projection](context.md).
   The first inputs are in its volatile block: the trigger, with the
   `Wake` carrying the messages it concerns (several from one person when
   debounced). `TurnStarted` is written with the trigger and `from`, and
   `Run::new` is called. If the first inputs alone are over the limit, the
   core is at its limit from the start: it fails with `ContextExhausted`,
   and the trigger gets a one-line reply.
4. **Advancing.** Each time the core has no I/O in flight, the actor asks
   for the next step. No turn record is written midway.
   - `CallModel`: each `Said` is entered and handed to the sender; on
     `ModelDone`, `model_output`. Waiting inputs are shown as one
     `[新消息]` block at the end of the request; see
     [Follow-up input](context.md#follow-up-input).
   - `RunTools`: one task per call, concurrently in the group's VM;
     `tool_result` for each `ToolDone`.
   - `Idle`: nothing. Whatever is entered later is still fed in; chatter
     alone leaves the core idle and doesn't reset the window. The run ends
     after a full idle window since its last model output (the provider's
     `idle_window_secs`, 300 seconds by default, or the conversation's own;
     see [Settings a conversation sets](config.md#settings-a-conversation-sets)).
     A trigger within the window finds the model still holding its tool
     results, so a follow-up question needs no repeated lookups. If the
     window and a trigger arrive together, whichever the actor handles
     first wins, and both outcomes are correct.
   - **At the limit**: see "At the limit" in [The core](core.md#what-the-core-decides).
   - **Failure**: `ModelDone` carries an error. What the call had said is
     recorded as `partial_output`, `fail` is called, and the snapshot and
     outcome are written.
5. **`/kill`**: see [Cancellation](#cancellation). Waiting inputs are
   dropped.
6. **Restart and startup**: see [Restarts](#restarts).

## Starting a model call over

People often finish an @ in a second message, seconds after the first.
When someone who addressed Max in the last minute (`FOLLOW_UP`) sends
another message, and it is to Max or to nobody else (it mentions no one
and quotes no one but its sender), the model call in flight is taken back
and made again with the new row (`follow_up.rs`), if:

- the call has said nothing yet,
- the core hasn't spoken since that person addressed Max, and
- the call hasn't started over three times (`MOST_RESTARTS`) since one
  last finished.

Nothing is lost: tools run only after the call, and the new request is
the old one with a row added, which the provider has cached. Other wakes,
a program's or the classifier's, wait for the next call: they don't
change the answer someone is waiting for.

## What the group sees

No status is shown while Max works: the official QQ API has no reactions.

- When a turn fails or is interrupted by a restart, a one-line error
  quotes the newest direct trigger not yet handled (see "Handled" in
  [The core](core.md#what-the-core-decides)); without it, whoever @-ed Max
  would see nothing. Wakes from the classifier get no such line: Max is
  free not to join in anyway.
- The line looks like a log line, so that it is plainly the system's: a
  `text` code block holding `error: <what happened>: <cause>`, the cause
  as it is, whitespace collapsed and cut at 300 characters with `…`:
  - `error: the model call failed: the provider answered 429: …`
  - `error: the context is full: 530000 tokens, limit 524288`; rephrasing
    or pasting less and asking again helps.
  - `error: interrupted: Max is shutting down, and the turn outlasted the 20s grace`
  - `error: the conversation failed: <error chain>`; see [Restarts](#restarts).
- `/kill` gets no reply: someone stopped the turn on purpose. `/stop` ends
  the turn the same way, and its reply says only that Max is stopped.
- The line is entered in the ledger and doesn't go into the core. Its
  `raw` is `{"said_by": "host"}`, and its header renders with
  `系统发的` (`Mark::Host`): `[12:00 maxx #45 系统发的]: error: …`, so the
  next core doesn't take it for its own words and carry on in its tone.
  Command responses are marked the same way, and the prompt explains the
  mark. In `maxx events` its `by` is still `max`, since Max's account sent
  it; programs simply shouldn't answer it.

## Cancellation

`/kill` is an event like any other: `seen = head`, and if there is a core,
`end(End::Kill)`. Every way a core ends goes through `end`:

```rust
enum End {
    Kill(String),       // /kill
    Failed(FailReason),
    Idle,               // the window ran out, or Max is stopping
    Stopped,            // Max is stopping and the core wasn't done within the grace
}
```

`end` drops `io` (aborting the model stream and tool calls: started at
once, not waited for), refuses the questions the turn was asked, records
what a cut-off model call had said as `partial_output`, interrupts or
fails the run, writes the snapshot and outcome in one transaction
(`turns::finish`), and for a failure or a stop sends the line above.

- Events tasks in `io` already sent arrive after their numbers left
  `live`, and are dropped. Whether something was said is decided by its
  entry in the ledger: a `Said` still in the mailbox counts as unsaid, and
  the sender never had it.
- The idle window and the limit end a core at a boundary, with nothing in
  flight, so there dropping `io` does nothing.
- While the turn record is written, events queue in the mailbox.

Where dropping isn't enough:

- **The outermost level of every task that owns a scope** is a single
  `run_until_cancelled` or `select!`; for the actor, its main loop.
- **Side effects a drop doesn't stop**, such as a command in the VM, are
  bound to a connection, and `Drop` only starts the stop; see
  [How resources end](lifetimes.md#how-resources-end).
- **What mustn't be done halfway**: a message is entered before it is
  handed to the sender, and database writes are transactions, which roll
  back when dropped. See [Cancellation safety](lifetimes.md#cancellation-safety).
- **Long computations without an `await`** can't be dropped: they go into
  the scope's `spawn_blocking`, with a cancellation flag.

## Restarts

A restart loses the running turn and nothing in the VM: background
commands, agents and resident programs are units of the guest's and run
on (see [Jobs](jobs.md)). Turns are interrupted rather than suspended and
resumed; why is in
[decisions/2026-10-29-first-round-of-cuts.md](../decisions/2026-10-29-first-round-of-cuts.md).

- **A normal restart (a deploy, SIGTERM)**: the actor gets `Stop` and
  notes when the grace runs out (20 seconds). An idle core ends at once.
  A busy one goes on as usual, and ends normally if it becomes idle within
  the grace; if not, it ends with `End::Stopped`: `io` is closed, what was
  said is recorded as partial output, finished tools of the batch keep
  their results and the rest get `已取消`, the outcome is `Interrupted`,
  and the newest unhandled direct trigger gets `error: interrupted: …`,
  which the sender delivers before it exits.
- **A crash**: nothing is written.
- **An actor error** (most likely the database's): the actor gives up on
  the conversation. The core stops; the conversation's turns without an
  outcome are recorded as `Lost`, as after a crash; unhandled direct
  triggers get `error: the conversation failed: <error chain>` (joined as
  `{:#}` does). Nothing in the VM is stopped. If the database can't be
  reached, only a log line is written and the next startup records the
  turns. The conversation table starts the actor again with the
  conversation's next message; messages arriving at the very moment it
  exits are lost with it. Errors aren't isolated per event, because after
  one the in-memory `head` and `seen` may not match the database.
- **Questions** another conversation asked the running core go
  unanswered; who asked hears so and may ask again.
- **Intent's state** is lost: hourly counts start at zero, chatter
  awaiting classification isn't classified, and direct triggers still in
  their debounce go unanswered.

At startup every turn without an outcome is recorded as `Lost`: a normal
restart leaves none, so any left were running at a crash. What such a
turn had said is in the ledger, findable by turn id. Each conversation's
`seen` starts at its `head`, and intent starts empty.

The QQ gateway resumes across restarts: what was said in the groups in
the meantime is delivered again, entered and passed through intent as
usual, so people who @ Max while it is down still get answers (see
[The official QQ bot](qq.md)). Only a message being answered at the moment
of shutdown has to be asked again.

## Size and retention

- **Size**: a reasoning blob is a few KB to a few tens of KB and doesn't
  compress well; a turn of dozens of rounds is a few hundred KB to a few
  MB, bounded by the core limit. Everything is stored in the snapshot's
  JSONB and left to Postgres's TOAST. If size becomes a problem, content
  past a threshold goes to a blob table addressed by sha256; the same for
  tool output and the base context.
- **Retention**: none yet. The plan is to clear the `opaque` fields and
  the base context from a snapshot N days after its turn ends, keeping
  the readable text and token counts: the turn can still be read, but no
  longer resent exactly.

## Testing

- The core and intent have synchronous unit tests that feed inputs from a
  script and check outputs, with no tokio and no fake provider; intent's
  time is passed in. Intent's cover direct triggers waking at once, the
  debounce, the hourly cap and `/proactive`. The core's cover when inputs
  take effect, no model call for chatter alone, the results filled in on
  interruption, malformed calls, the limit, and that the record is what
  the model saw and said.
- The actor is tested with a real database (`#[sqlx::test]`), a scripted
  model and a sender that only records, once for each way a turn starts
  and ends: an @ that is answered, a tool's result going back to the model,
  chatter that wakes nobody, rows that reach a running core, a call that
  fails, `/kill`, a stop that outlasts its grace, `/stop` and `/start`, a
  wake by the classifier's verdict, what a program says, and what a stopped
  conversation refuses. Actor tests use real time, not `start_paused`:
  while the actor waits on Postgres a paused clock jumps to the next
  deadline, so the idle window and the debounce would come early. Their
  waits are short and bounded. Purely time-based logic (`Scope`, a model
  call's retries) uses `start_paused`.
- The protocol adapters are tested against recorded Responses and Chat
  responses from four providers, and each protocol's request is held to
  its shape.
- Which tests there are, and which there aren't, is a decision:
  [decisions/2026-11-16-tests-on-the-critical-path.md](../decisions/2026-11-16-tests-on-the-critical-path.md).
- A snapshot holds every request it made, so any production model call
  can be resent exactly, offline.
- The segmenter's cutting (`segment/chunk.rs`) is written in the part of
  Rust that Aeneas translates, and its properties are proved in Lean on
  the translation; [verify/README.md](../../verify/README.md) lists the
  theorems. The Rust is the only implementation: there is no second model
  to keep in step with it. CI's Verify workflow translates the code again,
  compares it with the committed `verify/MaxCore/` and builds the proofs,
  only when `chunk.rs` or `verify/` changes, since Charon and Aeneas are in
  no binary cache.

The same pattern, a pure state machine driven by a thin async shell, is
used where there is protocol state, complex rules and a need for precise
tests: the streaming segmenter, and the QQ gateway session (heartbeat,
Resume, reconnection). The actor itself is ordinary async code: the rules
live in the core and the segmenter, and the actor enters, routes and
spawns as the core directs.

## Open

- Retention: the period N, or whether to clear anything.
- Whether to tell a group about a turn lost in a crash, from its `Lost`
  record, after startup.
