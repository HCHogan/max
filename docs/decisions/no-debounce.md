# Direct triggers aren't held back

An @ of Max, a reply to Max or a private message wakes the core at once,
however unfinished it looks. A second half that follows is taken up by
making the model call again; intent has no debounce. The design is in
[Intent](../design/intent.md) and
[Starting a model call over](../design/actor.md#starting-a-model-call-over).

## Context

People often finish an @ in a second message. There are two ways to have
both halves in one answer:

- **Hold the trigger.** Intent holds a direct trigger that looks
  unfinished (nothing left once the @ is removed, a trailing `，、；：…`, a
  trailing lead-in such as `但是` or `我跟你讲`, or its sender's third
  message within 5 seconds) until its sender has been quiet for 10
  seconds, at most 20, and what the sender writes meanwhile joins its
  wake. The idea is [qq-bridge](../research/dsh-qq-bridge.md)'s.
- **Start over.** The actor takes back a model call that has said nothing
  when whoever it answers goes on talking, and makes it again with the
  new row.

Four weeks with both, about 10,900 direct messages:

- Of the 163 turns whose start was held, 145 waited the 10 seconds and
  nothing joined them. Twelve messages joined the other 18.
- Looking unfinished tells little. The sender of a held message wrote
  again within 10 seconds 7% of the time; the sender of any other direct
  message, 6%.
- Most holds, 366 of 419, were an @ with no text, and that is mostly a
  whole request: an @ with a picture, or an @ that quotes what Max should
  look at. The trailing marks, the lead-ins and the bursts held 53
  messages between them, and not one was followed within 10 seconds.
- The model call started over about 66 times a day, and each time lost 5
  seconds of a call at the median, 14 at p90. Of 36 looked at, about 30
  were plainly the same person finishing: the rest of a sentence, a
  picture, a voice message.

## Decision

Intent holds nothing back, and `observe` takes no time. Starting the
model call over is what joins a second half.

## Why

- A wait costs 10 seconds nine times in ten, on top of the 30 seconds a
  first word takes at the median.
- Starting over costs something only when a second half does come, and
  then only what the call had done: tools run after it.
- A check for an unfinished message guesses from its text. Starting over
  acts on what its sender does next.
- Less state: a trigger still held at a restart goes unanswered.

## Cost

- A second half that comes after Max's first word isn't joined to the
  first. Max answers the first; the second wakes it again if it is an @
  or a reply, and otherwise waits for the next wake.
- A bare @ is answered at once, perhaps with a question back.

## Alternatives

- **Holding only a bare @**, with no picture and no quote: 197 of them in
  the four weeks, 9% followed within 10 seconds. Still a wait for nothing
  nine times in ten.
- **Another length of wait**: of the second halves that came within 20
  seconds of a held message, nearly as many came after the 10 seconds as
  within them. A shorter wait catches fewer, and a longer one costs more
  each time nothing comes.
