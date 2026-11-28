# No historian, no summaries

The context holds the raw tail and the memory file, and nothing
summarises older chat. What the context holds is in
[Context projection](../design/context.md).

## Context

The chat is longer than a context. Something has to stand for what is
older than the raw tail, or the model has to go and look for it.

## Decision

Nothing stands for it. Older chat is in the ledger, and Max reads it with
`history`, by content or by time and speaker. The tail's high watermark
is 64k tokens.

## Why

The other way is a historian: a worker that cuts the chat into segments
and summarises each, summaries at three levels that decay by age, and a
summary block before the raw tail, after
[magic-context](https://github.com/cortexkit/magic-context).

- **Cost**: in one day a historian made 49 calls and wrote 406,000 output
  tokens, more than every turn's output together (304,000), and output is
  the most expensive part.
- **Second-hand errors**: summaries misremember; the original words
  don't. Max once said in a group that it had been misled by a summary
  that recorded "13 块搓完整个原型" as "修一轮 bug 花 13 块".
- **Complexity**: scheduling, validation, retries, the decay curve,
  watermarks and publication timing, a command to compact by hand, and
  the summaries' own search come to more than 3,000 lines.
- **Direction**: with a strong enough model, raw records plus its own
  search work better than pre-processed material (see
  [memory is a file](memory-is-a-file.md)). What summaries give most is
  an index of "what was discussed those days", which `history` gives by
  reading the original text by time and speaker.

The tail is 64k because a 32k tail on a 1M window is only 270 to 540
messages, and people find Max forgetful; 128k doubles the input, and
changes how Max speaks.

## Cost

Anything older than the tail is found only if the model thinks to search
for it. Running jokes, names and rules that only old chat holds have to
be in the memory file.
