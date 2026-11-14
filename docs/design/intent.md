# Intent

## Intent

Decided 2026-10-27 to include intent in v1; originally it classified only messages that did not @ Max. Changed 2026-10-28: **every inbound message goes through intent**, and @s, replies and the like do not bypass it; intent decides when to wake the core. This way it sees all the information, the rules and the small-model classification are in one place, and debouncing naturally belongs here as well.

Simplified 2026-10-29: only the debounce for messages that are "not finished yet" and the small-model classification remain, plus an hourly cap as a safeguard. Removed were the Haskell version's gate, its three verdict categories (called, followup, topic) and the topic cooldown, as well as the "state of this group", uptake rate and "found annoying" signals added on 2026-10-28. The plan is to see first how well the small model judges on its own, and to add rules only if they turn out to be needed. For the Haskell version's behaviour, see Proactive triggering in its `docs/features.md`.

Like [The core](core.md#the-core-1), intent is a pure state machine in `max-core`, and it is a field of the conversation actor:

```rust
// Synchronous, no I/O, no clock reads; time is passed in by the actor
impl Intent {
    fn observe(&mut self, entry: &Entry, now: Instant) -> Vec<Decision>; // every entered message, event and command from others
    fn verdict(&mut self, v: Option<Verdict>, now: Instant) -> Vec<Decision>; // result for the in-flight batch; None on failure
    fn tick(&mut self, now: Instant) -> Vec<Decision>; // a debounce has expired
    fn deadline(&self) -> Option<Instant>;              // merged into the actor's deadline()
    fn set_proactive(&mut self, on: bool);              // /proactive
}

enum EntryKind { Direct /* @, reply to Max, private chat */, Command, Chatter /* everything else, events included */ }

enum Decision {
    Wake { ids: Vec<MessageId>, reason: Reason }, // wake the core: feed it an Input::Wake if there is one, otherwise start one
    Classify { batch: Vec<MessageId> },           // the actor spawns the small model in side
}

enum Reason { Direct, Judged { note: String } }
struct Verdict { trigger: bool, reason: String }
```

All values are constants in `max-core`; there are no configuration options (the `[intent]` section was removed on 2026-10-29). They are tuned during v1.

### Direct triggers and debouncing

- **Direct triggers**: an @ to Max, a reply to Max, and messages in private chat (see step 2 of [Processing flow](actor.md#processing-flow)). They do not call the small model, are not subject to the cap, and by default `Wake` immediately.
- **Debouncing** (decided 2026-10-28, from [Research: DSH and qq-bridge](../research/dsh-qq-bridge.md#research-dsh-and-qq-bridge-1)): if a direct trigger looks unfinished, it is held first, and the `Wake` happens once the person has stopped for 10 seconds, after at most 20 seconds of waiting. Their follow-up messages in the meantime (except commands) are merged into the same `Wake` and go to the core together as its first batch; otherwise the trigger would be in the volatile block while the second half of the sentence was in the tail, in reverse order. "Looks unfinished" is a pure function, true when:
  - nothing remains after removing the @;
  - the message ends with punctuation such as "，、；：…";
  - the message ends with "但是、然后、我跟你讲、对了、就是、所以、而且、还有、那个、因为" ("but", "then", "let me tell you", "oh right", "I mean", "so", "and also", "plus", "um, that", "because");
  - it is the same person's third message within 5 seconds.
- **A second half restarts the model call** (added 2026-11-04, proposed by the owner): an @ that looks finished wakes the core immediately; if the person's next message arrives early, while the model call has not yet said anything, the call is retracted and resent, and the new request includes that message. The conditions: the sender has @ed or replied to Max, or talked to it in private chat, within the last 60 seconds, and the core has not said anything since; the message does not @ or reply to anyone else (replying to oneself is fine); and the in-flight call has not yet uttered a single segment (a `Said` goes out only once the actor has processed it; a `Said` or `ModelDone` that arrives late from a retracted call is discarded as stale; tools run only after the call ends). A call is restarted at most 3 times. Retraction is the core's `retract`: the core returns to "should call the model", input that arrived in the meantime goes into the next request as usual, the prefix is unchanged, and the provider has it cached. Usage cannot be read from an interrupted call, so it is not recorded. Only the person's own words can restart a call: job results, `maxx wake`, verdicts and other people's @s all wait for the next call. They do not change the answer owed to the person who is waiting for it; restarting would only make that person wait longer, and in a busy group the call might keep restarting. A turn woken by a verdict usually has no one waiting: if no one has talked to Max within 60 seconds, there is no restart.
  - Background: on 2026-11-04, the 554 directly triggered turns of the previous 7 days were examined. In 99 of them the person sent another message within 60 seconds, and 61 of those messages arrived before Max's first sentence. About 20 of these landed during the call that ended up giving the answer, and Max answered the first half on its own ("这是什么" ("what is this") did not wait for the image that followed; "推荐用哪个？" ("which one do you recommend?") did not wait for "如果我要给nix用的话" ("if I want it for nix")). The second half usually arrives 3 to 38 seconds after the @, and a debounce that waited that long would make every @ half a minute slower. The first output of such a call has a p50 of 10 seconds and a p90 of 22 seconds, and most second halves fall within this window. The debounce above is still kept: when nothing follows the @, typing the second half often takes longer than the first output, so waiting first is better.
- **Commands** are not triggers; the actor executes them.

### Small-model classification

- **When to classify**: while `/proactive` is on, all chatter is classified (changed 2026-10-29; previously the Haskell version's gate was kept: chatter was classified only if the text contained "max" or Max had spoken within the last 3 minutes, and other chatter at most once every 15 minutes). A hand-typed "@max" is plain text and also takes this path (decided 2026-10-20; it is not parsed as a mention).
- **Batching**: each conversation has at most one classification in flight at a time. Chatter that arrives meanwhile is accumulated and classified together when the in-flight classification returns, taking the latest 30 messages. Classification frequency therefore follows the small model's speed: in a lively chat, one batch follows another, rather than one classification per message. The Haskell version's 2-second debounce timer is not used.
- **Input and output**: the input is the first 500 characters of the persona, the latest 15 messages as context (in the same line format as the tail), and the messages to be classified. `[mention#N]` in these lines is replaced with `@name`, and an @ to Max becomes `@maxx`: the small model has no roster like the core's, so it tells from names whom a message is addressed to (changed 2026-10-29: before, it could not tell whom an @ was for and took @s of other people as @s of Max). The output is one line of JSON: `trigger` and a `reason` of at most 20 characters. The prompt describes the two situations in which Max should chime in (being addressed by name without an @, and topics on which Max can offer something concrete and useful) and those in which it should not (conversations between members, including @ing or replying to others; telling someone to go and use an AI; merely mentioning Max; finding Max annoying; other bots, and pasted code or notifications); when in doubt, Max does not chime in. There used to be one more situation, "a conversation Max took part in has a follow-up", which was removed on 2026-10-29: whenever the 4B small model saw that Max had just spoken, it classified whatever anyone said next as a follow-up, so verdict wakes chained one after another. Responses to Max are replies or @s anyway, and those wake the core directly. The classification task reads the database itself to assemble its input; building the prompt and parsing the output are both pure functions in `max-core`.
- **Where a `Wake` goes**: the verdict comes back to the mailbox, and the actor passes it to `intent.verdict`. Since only one classification is in flight at a time and intent remembers the batch, no task id needs to be carried; if the classification task fails or panics, it must still return a `None`, or this conversation would never classify again. A positive verdict becomes `Wake { reason: Judged }`, whose ids are the messages of this batch. Every `Wake`, including a direct trigger whose debounce has expired, goes through the same rule: if every message involved is at or below `seen`, the `Wake` is void. Those messages have already been in some model request, and the model has already made its own decision about them; messages from before a `/kill` are all voided the same way. A `Wake` that is not void enters the core as one input (`Input::Wake`): if there is no core, one is started with this `Wake` recorded as its trigger; if there is a core, the input is fed to it. So when the core is idle and the chatter has not yet been in a request, a verdict wakes the core; when the core has ended because its idle window ran out, a verdict starts a new core. A verdict appears as one line in the `[新消息]` ("new messages") block, such as `[判定：在追问你刚才的回答]` ("[verdict: following up on your previous answer]"); direct triggers add no line, since the message lines are already marked "@你" ("@ you") or "回复你的 #123" ("reply to your #123"). For `seen`, see [The timeline](ledger.md#the-timeline).
- **Cap**: verdict wakes are limited to 8 per conversation per hour, as a safeguard against a runaway small model; direct triggers do not count. Verdicts beyond the cap are simply dropped. Each conversation switches proactive replies on and off with `/proactive`, and `/status` shows whether they are on.
- **Output limit**: 1000 tokens (`MAX_OUTPUT` in `classify.rs`). It used to be 300, enough for one line of JSON. After intent switched to `deepseek-v4.1-flash` (low) on 2026-11-04, the model first thinks for about 100 tokens, and up to 280; on that day one call in eight was cut off at 300 (`length`), which, counted as a failure, meant no wake.
- **Failure**: there is no retry; the failure is logged and the batch dropped. Intent is only advisory, and the messages are all in the ledger. Transient errors are covered by the provider's own retries, and no further layer is added on top. The Haskell version retried up to 3 more times on top of the provider's retries.
- **Model**: `[llm] intent` selects a small model. A turn started after a verdict uses the conversation's own model, just like an @-triggered turn; the model and reasoning effort are not switched by trigger type.
- Each classification records one `llm_usage` row with purpose intent.

### State held only in memory

Decided 2026-10-28: held triggers, accumulated chatter, the in-flight batch and the hourly counts all live in the actor's memory and are reset on restart; no table is created for them. The cost is that a direct trigger still being held at shutdown or at a crash is lost and gets no reply. This is accepted.
