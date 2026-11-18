# The core

The core is a turn's agent loop, written as a pure state machine:
`Run` in `crates/max-core/src/run.rs`. All its methods are synchronous,
and each call is one complete state transition; it does not `await`,
spawn, read the clock or touch the network. The conversation actor feeds
it messages, tool results and model output, and asks it what to do next
(see [The conversation actor](actor.md)). It is written in-house rather
than taken from an agent framework; why is in
[decisions/own-agent-loop.md](../decisions/own-agent-loop.md).

## Interface

Abridged from the code:

```rust
pub struct RunSpec {
    pub model: ModelTag,
    pub window: u32,              // the model's context window, C
    pub max_output: Option<u32>,  // the model's output limit; C / 8 is reserved when it has none
}

pub struct Run {
    spec: RunSpec,                // fixed for the turn
    base: Context,                // fixed: the base context's entries and roster; the first inputs are in its volatile block
    base_tokens: u32,
    transcript: Vec<Arc<Item>>,   // what this turn produced, append-only
    pending: Vec<Input>,          // inputs since the last model call, shown as one [新消息] block at the next one
    phase: Phase,
    round: u32,
    measured: Option<(u32, usize)>, // the provider's count for the last request and its output, and how much of the transcript that covers
    unhandled: Vec<Wake>,         // wakes since the run was last waiting, the first ones included, that the model hasn't finished with
    roster: BTreeSet<PrincipalId>,// the base roster plus everyone a later input brought a roster line for
    quiet: u32,                   // tool calls since the model last said something to the group, or since the last reminder
    warned: bool,                 // the model has been shown the nearly-full warning
}

enum Phase {
    ModelDue,             // a model call is next: at the start, after the tool results, after a cut-off or malformed call, when a trigger comes
    Calling,
    ToolsDue(Vec<Call>),  // well-formed calls from the last output, not started yet
    Running(Vec<CallId>), // a tool batch in flight: the calls without a result, never empty
    Waiting,              // nothing in flight and nothing due: ending now loses nothing
    Interrupted,
    Failed(FailReason),   // Model { error } or ContextExhausted
}

pub enum Step {
    CallModel(Request),   // complete; nothing changes it afterwards
    RunTools(Vec<Call>),  // already parsed into run_code or shell
    Idle,                 // whether to wait or end is the actor's call
}

impl Run {
    pub fn new(spec: RunSpec, base: Context, first: Vec<Input>) -> Self;
    pub fn busy(&self) -> bool;          // a model call or a tool is in flight; the actor asks for next_step only when it isn't
    pub fn next_step(&mut self) -> Step; // starts a call or a batch; the phase changes with it
    pub fn model_output(&mut self, out: ModelOutput) -> Result<(), Rejected>;
    pub fn partial_output(&mut self, text: String, tokens: u32) -> Result<(), Rejected>; // a call cut off after `text` was said
    pub fn retract(&mut self) -> Result<(), Rejected>;   // takes back the call in flight, which has said nothing
    pub fn tool_result(&mut self, call: CallId, out: ToolOutput) -> Result<(), Rejected>;
    pub fn input(&mut self, input: Input) -> Result<(), Rejected>; // messages and wakes, at any time; the core decides when they take effect
    pub fn interrupt(&mut self) -> Result<(), Rejected>;
    pub fn fail(&mut self, reason: FailReason) -> Result<(), Rejected>;
    pub fn at_limit(&self) -> bool;
    pub fn near_limit(&self) -> bool;
    pub fn fill(&self) -> Fill;          // the context's tokens and their limit: what at_limit compares
    pub fn warned(&self) -> bool;
    pub fn unhandled(&self) -> Vec<Wake>;
    pub fn idle(&self) -> bool;
    pub fn outcome(&self) -> Outcome;    // Answered, Silent, Interrupted or Failed
    pub fn round(&self) -> u32;
    pub fn roster(&self) -> &BTreeSet<PrincipalId>;
    pub fn record(&self) -> RunRecord<'_>; // serialises by borrowing the core's data
}
```

Anything inconsistent with the state (a `ModelOutput` when no model call
is in flight, the result of an unknown call, any input after the end)
returns `Rejected` and changes nothing. Messages that arrive while a model
call is in flight don't belong to that request; they wait for the next
one.

## What the core decides

- **Building requests.** A request is the base context, the transcript
  and the two fixed tools, and is never trimmed. Each input and each tool
  result has a cap (see [Follow-up input](context.md#follow-up-input));
  the whole is governed by the limit below, and reaching it ends the run,
  so a request never exceeds the window. The one exception is images:
  past the vision budget the earlier ones are left out; see
  [Multimodal results](tools.md#multimodal-results).
- **Tools.** `run_code` and `shell`, which never change. What a program in
  the VM may call is no business of the core's; see
  [Pure codemode](tools.md#pure-codemode).
  A malformed call gets an error result at once and never reaches the
  actor.
- **Token counts are data.** The core estimates nothing. The base
  context, each input and each tool result arrive with counts `max`
  estimated; model output carries the provider's usage. A request's size
  is the input tokens the provider reported for the previous request plus
  what was added since, so estimation error falls only on that increment.
  A provider that reports no usage (input 0) isn't a measurement: the
  count goes on from the previous measurement or estimate. The counts are
  stored in the snapshot with the entries.
- **The limit** (`RunSpec::limit`):

  ```
  available  = C − output reserve − C / 20
  core limit = min(available − base context, C / 2)
  ```

  The output reserve is `max_output`, or C / 8 without one; C / 20 is the
  margin for estimation error. With a 400k window, a 128k `max_output` and
  a 100k base context, the core limit is 152k; by C / 2 alone it would be
  200k, and the request would pass the 272k of input the provider allows.
  The limit counts waiting inputs too, so a request cannot overflow. When
  the base context alone fills the available space, the limit is 0.
- **At the limit.** `at_limit` holds when the limit is 0, or when the
  transcript and waiting inputs are over it and the model has been warned
  (below). The actor then ends the run at the next boundary: an idle core
  ends normally; otherwise the run fails with `ContextExhausted` and the
  unhandled direct triggers get a one-line reply. The next trigger
  projects afresh from the ledger. This is Max's compaction: rather than
  compressing a transcript, it projects again.
- **Handled.** An input the model has seen is handled when the model
  reaches an output with no tool calls and the core becomes waiting,
  whether or not it said anything; the mark is set at that moment. A
  warned model that says something has also handled what it saw, even if
  the same output calls tools (to hand over to an agent), so a run that
  reports its progress, hands over and then reaches the limit adds no
  error line. `unhandled` returns the wakes not yet handled; messages are
  never in it, as they are in the ledger. On failure or interruption the
  actor uses it to find the direct trigger that gets a reply; see
  [What the group sees](actor.md#what-the-group-sees).
- **When inputs take effect.** After every result of the current tool
  batch is back, before the next model call. A batch of inputs causes a
  model call only if it holds a trigger (a `Wake`); messages alone are
  kept for the next call. When to wake is [Intent](intent.md)'s
  decision.
- **Reminder after too many quiet calls.** After `QUIET_CALLS` (12) tool
  calls in a row with nothing said to the group (output the segmenter cuts
  no message from doesn't count, nor does `[silence]`), a `[maxx 提醒]`
  follows the batch's last result: say in the group what it is doing and
  how long it will take, hand long work to a background agent, and answer
  whoever is waiting first. Saying something resets the count, and so does
  the reminder. Without it, a turn once made 49 calls over 41 minutes
  before its first word, while two more people asked it something.
- **Nearly-full warning.** When the transcript and waiting inputs pass
  nine tenths of the limit (`near_limit`), the next model call ends with
  `WARNING`, once per run: the context is nearly used up; say in the group
  how far it got, what it found and what is left, since the next turn sees
  only what was said; hand the rest to a background agent, and call no
  other tool.
  - Until the warning has been shown, a run over its limit isn't at it:
    it still gets the call that shows the warning. On a small window the
    gap between nine tenths and the limit is a few thousand tokens, while
    one tool result may be 15% of C; that call spends the headroom, the
    output reserve and the margin.
  - An idle core past nine tenths ends at once, without waiting for the
    idle window, and the next trigger starts afresh.
  - Without the warning, a run that reached the limit lost everything its
    tools had found and said only that it couldn't finish.
- **Interruption.** Tool calls without a result get `已取消`, so that the
  history stays valid: Responses requires an output for every
  `function_call`.
- **Taking back a call.** `retract` returns a model call that has said
  nothing to `ModelDue`; the next step makes it again with what came
  since. The actor uses it when someone finishes what they were asking;
  see [Starting a model call over](actor.md#starting-a-model-call-over).
- **Idle.** When the model's latest output is text only and no trigger
  waits, `next_step` returns `Idle`. When to end is the actor's: the idle
  window, the limit, `/kill`, failure, a restart. A run that never said
  anything ends `Silent`; whether something was said is decided by running
  the model's text through the segmenter.

## I/O tasks and protocol adapters

The actor spawns the I/O the core asks for as tasks in that core's `io`
scope, and their results return to its mailbox as events. Tasks share no
mutable state with one another or with the actor.

- **Model calls**: one task per `CallModel`. It holds the model client and
  the segmenter: it has the protocol adapter downgrade the request into
  the wire format, sends it and reads the stream, sends `Said` for each
  segment cut from the streamed text and `ModelDone` when the stream
  ends. A retryable error is retried within the task only while no `Said`
  has been sent; after that the error is reported at once and the actor
  records what was said as `partial_output`, since a retry would send the
  paragraphs already sent again. As soon as a `run_code` or `shell` call
  appears in the stream, the VM service is told to start the group's VM.
- **`run_code` and `shell`**: one task per call, run in the group's VM,
  sending `ToolDone`. Calls in a batch run concurrently, and whichever
  finishes first is fed first.
- **Intent classification**: in `side`, sending `Verdict`; see
  [Intent](intent.md).
- **Receipts**: each task holds a `Report`. It sends the task's completion
  event on the normal path, and a "no result" event from its `Drop` if the
  task is aborted or panics. Every task therefore has exactly one
  completion event, queued in the same mailbox after its `Said` events.
- **Stale events**: each task has a number, increasing within the
  conversation and never reused, that all its events carry. Events from a
  task not in flight for the current core are dropped.

The protocol adapter layer is stateless. Downgrading only removes entries
or changes their shape; it never adds content:

- An `opaque` whose `source` isn't the current model is dropped. The
  model is fixed for the turn, so this is only a safety net.
- **Responses**: every reasoning entry of the current turn is sent back.
- **Chat**: the entries of one round are joined back into one assistant
  message; `reasoning_content` is sent back within the current turn's
  tool-call loop.
- For images and videos in tool results, see
  [Multimodal results](tools.md#multimodal-results).
