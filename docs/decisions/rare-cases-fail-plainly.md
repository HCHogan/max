# Rare cases fail plainly

Where something is rare and the cost of not handling it is that someone
asks again, Max has no machinery for it: a turn cut off by a restart
isn't resumed, a core at its limit isn't handed over, and intent has few
rules.

## A restart interrupts a turn

The turn gets a grace and is interrupted when it runs out
([Restarts](../design/actor.md#restarts)). A turn is rarely running at
the moment of a deploy, and whoever was interrupted can ask again.

The other way is to suspend a running turn at its next boundary, store a
snapshot, and resume it after the restart within a window, with
unfinished tools given "进程重启，结果未知". That takes attempts, several
snapshots per turn, an event for a turn resumed, an outcome for one that
expired, and permissions checked again on resumption.

## A run stores what it showed the model

A run stores the base context and the transcript
([principle 3](../architecture.md#principles-of-the-data-and-execution-model)),
not the inputs fed to its core.

Storing the inputs lets a core be rebuilt by replaying them, which is
what resuming a turn needs. With no resuming, replay serves only tests,
while model output is stored twice, in the log and in the transcript, and
reasoning blobs with it.

## A core at its limit gives up

The run fails with `ContextExhausted` and the unhandled direct triggers
get a one-line reply ("At the limit" in
[The core](../design/core.md#what-the-core-decides)); the next trigger
projects afresh. A run near its limit is warned, so that it reports what
it found before it stops. Turns hardly ever reach the limit.

The other way is to replace the core: its unhandled triggers go to a new
core with a handover note that lists the calls with side effects the old
one made, so they aren't made again; a trigger may be handed over once;
and a turn has a wall clock.

## Intent keeps a small model and a cap

[Intent](../design/intent.md) wakes Max at once for a direct trigger,
asks a small model about the rest, and caps the wakes that model causes
in an hour. It has no configuration. The small model judges alone, and a
rule is added only when it is shown to be needed.

Not there:

- **A gate before the model**: chatter classified only if it contains
  "max" or Max spoke in the last minutes, and other chatter at most once
  in a while.
- **Categories of verdict** (called, follow-up, topic) with a cooldown
  for topics.
- **Signals in the prompt**: how often Max has spoken in the last hour,
  how often people took up what it said, whether someone found it
  annoying. The last is a line of the classifier's prompt.
- **"A follow-up to Max" as a case that wakes it.** Whenever a model of
  four billion parameters sees that Max has just spoken, it calls
  whatever comes next a follow-up, and verdict wakes chain one after
  another. Answers to Max are replies or @s, which wake it directly.
- **A wait for a second half of an @**: see
  [Direct triggers aren't held back](no-debounce.md).

## See also

- [Features deliberately left out](features-removed.md).
- [Matrix is deferred](matrix-deferred.md).
