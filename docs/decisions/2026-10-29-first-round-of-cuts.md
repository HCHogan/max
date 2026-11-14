# The first round of cuts

2026-10-29, at the owner's request, the day the Rust version first ran
in the test group (step 7 of
[archive/v1-implementation-order.md](../archive/v1-implementation-order.md)).
Each cut removed machinery for something rare, where the cost of not
having it is that someone asks again.

## Restarts interrupt a turn instead of resuming it

Before: at a normal restart a running turn was suspended at its next
boundary and a snapshot stored; after the restart it was resumed within a
window, with unfinished tools given "进程重启，结果未知". That needed attempts,
several snapshots per turn, `TurnResumed`, an `Expired` outcome and
permissions checked again on resumption.

Now: the turn gets a grace and is interrupted when it runs out
([Restarts](../design/actor.md#restarts)), as the Haskell version did. A
turn is rarely running at the moment of a deploy, and whoever was
interrupted can ask again. Migration 0006 dropped what recovery used.

## The core is no longer stored as an input log

Before: the inputs fed to the core were stored, and a core was rebuilt by
replaying them. Once recovery was gone, replay served only tests, while
model output was stored twice, in the log and in the transcript, and
reasoning blobs with it. Now a run stores what it showed the model: the
base context and the transcript
([principle 3](../architecture.md#principles-of-the-data-and-execution-model)).
Starting a model call and starting a tool batch, recorded as inputs so that
replay could tell them apart, became phase changes inside `next_step`.

## A core at its limit gives up, with no handover

Before: a core at its limit was replaced. Its unhandled triggers went to a
new core with a one-line handover note listing the calls with side effects
the old one had made, so they wouldn't be made again; a trigger could be
handed over once; and a turn had a 30-minute wall clock. A first batch too
big for a core started none and recorded `InputTooLarge`.

Now: the run fails with `ContextExhausted` and the unhandled direct
triggers get a one-line reply ("At the limit" in
[The core](../design/core.md#what-the-core-decides)); the next trigger
projects afresh. At the time not one turn had reached the limit. (The
nearly-full warning came later, on 2026-11-01, so that a run near the end
reports what it found before it stops.)

## Intent keeps only the debounce, the small model and a cap

Removed from [Intent](../design/intent.md):

- the Haskell version's gate: chatter was classified only if it contained
  "max" or Max had spoken in the last 3 minutes, and other chatter at most
  once every 15 minutes;
- its three verdict categories (called, followup, topic) and the topic
  cooldown;
- signals added the day before: the group's participation counts ("你近 1
  小时发言 N 次…", as "本群情况"), Max's uptake rate (whether anyone answered
  an interjection within minutes), and "found annoying" (`dismiss`), which
  survives only as a line in the classification prompt;
- the `[intent]` configuration section.

The plan was to see how well the small model judges alone, and to add
rules back only if needed. The "follow-up to Max" situation went from the
prompt the same day: whenever the 4B model saw Max had just spoken, it
called whatever came next a follow-up, and verdict wakes chained one after
another.

## Also that day

- Max stopped sending QQ face emoticons, which the official API can't
  send; see [features removed](2026-10-28-features-removed.md).
- Matrix was deferred: [2026-10-29-matrix-deferred.md](2026-10-29-matrix-deferred.md).
