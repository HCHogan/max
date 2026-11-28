# The tail is split into messages by turn

The raw tail of a context is one message for each turn, not one message
that grows, so that a provider's cache can match it. The rule is in
[Rules for a stable prefix](../design/context.md#rules-for-a-stable-prefix).

## Context

With the raw tail as one user message that grows, a turn's first model
call almost never hits Gemini's cache. It isn't the cache expiring: with
a byte for byte identical prefix there is no hit even with turns less
than two minutes apart.

Measured through cliproxy, Flash and Argon alike, six minutes after a
request:

- Appending to the previous request, left unchanged: about 90% reused.
- Appending lines within the same last message: 0.
- Keeping the messages before the previous request's last one and
  starting a new message after them: about 90%.
- Earlier boundaries (after the system prompt, after the third-to-last
  message): 0.

Within a few seconds Gemini's implicit cache reuses any identical prefix,
at token granularity; after a few minutes it keeps only the part of each
request before its last message, and a later request hits only if it
begins with exactly those messages. Turns are at least an idle window
(300 seconds) apart, so with one growing message the first calls of
Argon's 99 turns hit 2%, leaving about 5.7 million uncached tokens, most
of Argon's input cost; later calls within a turn hit 80 to 90%.

## Decision

Every turn after the tail's mark cuts the tail where its own tail ended,
and each piece is one user message. The previous turn's first call is
then present unchanged, with one more piece at the end. No table of its
own: the cut points come from `turns.from_id`.

## Cost

A busy group's request has dozens to more than a hundred user messages
before a truncation, and they can't be merged without missing once. A
call right after someone spoke between the waking row and the turn's
start misses once.
