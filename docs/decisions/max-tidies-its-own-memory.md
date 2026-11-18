# Max tidies its own memory

Nothing on the host tidies a conversation's memory file. Max, which writes
it, keeps it in order too: the prompt says so, and the cap's reminder is
what has it go over the whole file. The design is in
[Memory](../design/context.md#memory).

## Context

Memory is a file Max appends to
([Memory is a file Max writes itself](memory-is-a-file.md)). In its first
days Max only ever added, so a worker of the host's, the dreamer, went over
each file Max had written that day, at 05:00: one model call a file, asking
for the whole file rewritten, with appended lines put under their headings,
entries that said the same thing merged, and those past their date dropped.

Three weeks of it on the live system:

- It ran 51 times. Of the 28 runs the journal still had, 21 left the file
  with as many lines as it had, and 7 changed the count by one to three,
  five lines more in all. A file and the copy kept from before its last
  tidy differed in one or two lines.
- So what it did was put the day's appended line under a heading. It
  merged and dropped next to nothing, the files being far under the cap:
  4 to 87 lines, the largest 5.4 KB.
- The one file that did shrink, from 84 lines to 38 with details moved to
  a file beside it, was rewritten from its VM during a day, in the way the
  cap's reminder asks for, and not by the dreamer.
- Four runs failed on the provider's errors.

## Decision

The dreamer is gone, with its model in the configuration (`[llm] dreamer`)
and its purpose among the usage rows' (those written stay). The prompt no
longer says a nightly tidy will place an appended line: it stays at the end
until Max rewrites the file, and the prompt says nobody tidies the file for
it.

## Why

- A line under the wrong heading costs the model that reads the file
  nothing: each carries the name it is about and its date.
- What the cap needs is a smaller file, and the one time a file got much
  smaller it wasn't the dreamer's doing. A tidy that may change no meaning
  can't move details out to another file; Max can.
- A worker that rewrites the model's own notes decides for the model what
  they should look like, and is one more model, key and failure to keep.

## Cost

- An entry past its date, or said twice, stays until Max next goes over the
  file, which may be weeks.
- Going over the file happens in a turn somebody waits for.
- The copies the dreamer left, `memory.prev.md`, stay in `/work/.max` until
  someone removes them.
