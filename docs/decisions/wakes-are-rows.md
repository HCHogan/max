# What wakes Max from outside the chat is a row

The words of a `maxx wake`, and what the VM service tells Max of its VM,
are rows of the timeline that are never sent to the chat. The design is in
[The timeline](../design/ledger.md#the-timeline).

## Context

A wake from outside the chat was an item only the core it reached was
shown: `[max-wake] …`, with a background command's end or an agent's
report in it. It was in that turn's record and nowhere a later core or
`history` looks.

What Max said to it was a row. So the next core read, in its tail, Max
speaking up in the chat with nothing before it that said why: the build
that failed, the agent's report it was passing on, the reminder a timer
gave it. It couldn't say what an agent had found beyond what it had
repeated in the chat, and a wake that carried something to do later, for
when a person came back, was gone with the core that read it.

A count was shown with each wake from the second in an hour, because a
turn couldn't see the earlier ones.

## Decision

The actor enters a wake's words as a row of Max's account, marked
`said_by: wake` (or `vm`), and doesn't hand it to the sender. The row is
the wake's trigger: it is fed to the running core, or is among the first
inputs of the one it starts, as an @ is. It renders with a tag in place
of a name, `[12:00 max-wake #45]: …`. The count goes from what Max is
shown; `/status` keeps it.

Why the classifier woke Max, `[判定：…]`, stays an item: the rows it
judged are in the ledger already. The run's own reminders stay items too:
they are about one run.

## Why

- **A later core sees why Max spoke.** The tail is the record of what
  happened in the conversation as Max saw it, and a wake is part of that.
- **One rule for what a core sees.** A core is its snapshot and every row
  after it; a wake was the one input that was neither.
- **`history` finds it.** An agent's report, or what a program said last
  week, can be searched and read by its number, and a long one is read in
  full that way where the wake showed only its beginning.
- **Nothing counts wakes for the model**: they are there to read.

Marking the row by `said_by`, as a program's and the host's rows are,
needed no change to the table and no new kind of content for every reader
to handle. A kind of its own in `messages.kind` was the other way: it
would say plainly that the row is no chat, at the cost of a migration and
of every query that takes `chat` to mean what the model reads.

## Cost

- **Wakes take room in the tail.** A program that wakes Max often, or
  agents with long reports, push chat out of the tail sooner; each row is
  cut to one item's cap, and nothing else bounds them.
- **The row is of Max's account**, since a row has a sender and nothing
  else in the VM is one. What tells it from Max's words is the mark, and
  a reader that ignores `said_by` takes it for something Max said. The
  classifier's context and `maxx events` leave such rows out for that
  reason; a program that reads `rows` has to look.
- **`maxx events` doesn't give them**, so a program can't follow what
  wakes Max there. One that follows the chat and wakes Max for what it
  sees would otherwise be woken by its own wakes.
- A wake still doesn't say which program it came from: everything in a VM
  is one caller.
