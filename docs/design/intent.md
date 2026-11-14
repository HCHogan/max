# Intent

Intent decides when to wake the core. **Every inbound message goes
through it**, @s and replies included, so it sees everything, and the
rules, the debounce and the small model's classification are in one place.
What is left is deliberately small: a debounce for messages that look
unfinished, the small model, and an hourly cap; why the Haskell version's
gates and signals went is in
[decisions/2026-10-29-first-round-of-cuts.md](../decisions/2026-10-29-first-round-of-cuts.md).

Like [the core](core.md), intent is a pure state machine in `max-core`
(`intent.rs`), a field of the conversation actor:

```rust
// Synchronous, no I/O, no clock: the actor passes the time in
impl Intent {
    pub fn observe(&mut self, entry: &Entry, now: Instant) -> Vec<Decision>; // every row entered: others' messages, events and commands
    pub fn verdict(&mut self, v: Option<Verdict>, now: Instant) -> Vec<Decision>; // the answer for the batch in flight; None on failure
    pub fn tick(&mut self, now: Instant) -> Vec<Decision>;  // a debounce ran out
    pub fn deadline(&self) -> Option<Instant>;              // part of the actor's deadline
    pub fn forget(&mut self);                               // /stop: drop everything held
    pub fn set_proactive(&mut self, on: bool);              // /proactive
}

pub enum EntryKind { Direct /* an @, a reply to Max, a private message */, Command, Chatter /* the rest, events included */ }

pub enum Decision {
    Wake { ids: Vec<MessageId>, reason: Reason }, // feed the core an Input::Wake, or start one
    Classify { batch: Vec<MessageId> },           // the actor runs the small model in side
}

pub struct Verdict { pub trigger: bool, pub reason: String }
```

Its values are constants in `max-core`; there are no configuration
options.

## Direct triggers and the debounce

- **Direct triggers**: an @ of Max, a reply to Max, and any message in a
  private chat. They don't call the small model, aren't capped, and wake at
  once by default.
- **The debounce**: a direct trigger that looks unfinished is held, and
  wakes once its sender has been quiet for 10 seconds (`QUIET`), after at
  most 20 (`HOLD_AT_MOST`). Their messages meanwhile, commands aside, join
  the same `Wake` and reach the core together as its first inputs;
  otherwise the trigger would be in the volatile block and the rest of the
  sentence in the tail, in the wrong order. "Looks unfinished" is a pure
  function, true when:
  - nothing is left once the @ is removed;
  - the message ends with punctuation such as `，、；：…`;
  - it ends with a lead-in such as `但是、然后、我跟你讲、对了、就是、所以、而且、还有、那个、因为`;
  - it is the same person's third message within 5 seconds (`BURST`).

  The idea comes from [qq-bridge](../research/dsh-qq-bridge.md).
- **A second half starts the model call over**: an @ that looks finished
  wakes the core at once, and if its sender's next message arrives before
  the call has said anything, the call is taken back and made again with
  it; the conditions are in
  [Starting a model call over](actor.md#starting-a-model-call-over). The
  two work together: when nothing follows an @, typing a second half often
  takes longer than the first output, so the debounce waits only when the
  message looks unfinished. Of 554 direct turns in a week, 99 had another
  message within a minute, 61 of them before Max's first sentence; the
  second half came 3 to 38 seconds after the @, while a call's first output
  takes 10 seconds at the median and 22 at p90.
- **Commands** aren't triggers; the actor runs them.

## The small model

- **What is classified**: all chatter, while `/proactive` is on. A
  hand-typed "@max" is plain text and goes this way too.
- **Batching**: a conversation has at most one classification in flight.
  Chatter arriving meanwhile is collected and classified together when it
  returns, the latest 30 messages (`BATCH`). So classification keeps pace
  with the small model: in a lively chat one batch follows another, rather
  than one call per message.
- **Input**: the first 500 characters of the persona, the latest 15
  messages as context (the tail's line format), and the messages to judge.
  `[mention#N]` becomes `@name`, and an @ of Max `@maxx`: the small model
  has no roster, so it tells from names whom a message is for.
- **Output**: one line of JSON, `trigger` and a short `reason` (cut at 40
  characters, as it becomes the `[判定 …]` line). The prompt names when Max
  should join in (addressed by name without an @; a topic where Max can add
  something concrete and useful) and when not (members talking to each
  other, @-ing or replying to someone else included; telling someone to go
  ask an AI; merely mentioning Max; finding Max annoying; other bots;
  pasted code or notifications). When in doubt, Max stays out. A follow-up
  to Max's own words isn't a reason: answers to Max are replies or @s,
  which wake it directly, and a small model that sees Max just spoke
  calls whatever comes next a follow-up.
- **Where a verdict goes**: it comes back to the mailbox and the actor
  passes it to `intent.verdict`. With one classification in flight and its
  batch remembered, no task id is needed; a failed or panicked
  classification must still send `None`, or the conversation would never
  classify again. A positive verdict becomes `Wake { reason: Judged }` with
  the batch's ids. Every `Wake`, a debounced direct trigger's too, follows
  one rule: if every message it concerns is at or below `seen`, it is void,
  since those messages were already in a request and the model made its own
  choice about them (messages before a `/kill` are voided so too). A wake
  that isn't void becomes an `Input::Wake`: it starts a core, recorded as
  its trigger, or is fed to the running one. A verdict shows as a line in
  `[新消息]`, such as `[判定：在追问你刚才的回答]`; a direct trigger adds no
  line, since its message is already marked `@你` or `回复你的 #123`.
- **The cap**: at most 8 verdict wakes per conversation per hour
  (`JUDGED_WAKES_PER_HOUR`), against a runaway small model; direct triggers
  don't count. Verdicts past it are dropped. `/proactive` switches
  classification per conversation, and `/status` shows it.
- **Output limit**: 1000 tokens (`MAX_OUTPUT` in `classify.rs`): a model
  that reasons first (`deepseek-v4.1-flash` at low effort thinks for about
  100 tokens, and up to 280) was cut off one call in eight at 300, and a
  cut-off call is a failure.
- **Failure**: no retry; it is logged and the batch dropped. Intent only
  advises, the messages are all in the ledger, and the provider's own
  retries cover transient errors.
- **The model**: `[llm] intent` picks a small model. A turn started by a
  verdict uses the conversation's own model, as an @'s turn does.
- Each classification records an `llm_usage` row of purpose `intent`.

## State held only in memory

Held triggers, collected chatter, the batch in flight and the hourly
counts live in the actor's memory and are lost on restart; there is no
table for them. A direct trigger still held at shutdown or a crash gets no
answer, which is accepted.
