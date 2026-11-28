# What wakes Max from outside the chat is a row

The words of a `maxx wake`, and what the VM service tells Max of its VM,
are rows of the timeline that are never sent to the chat. The design is
in [The timeline](../design/ledger.md#the-timeline).

## Context

A wake from outside the chat carries a background command's end, an
agent's report, a timer's reminder. What Max says to it is a row.

If the wake itself is only an item shown to the core it reaches, it is in
that turn's record and nowhere a later core or `history` looks. The next
core then reads, in its tail, Max speaking up in the chat with nothing
before it that says why: the build that failed, the report it was passing
on. It can't say what an agent found beyond what it repeated in the chat,
and a wake that carries something to do later, for when a person comes
back, is gone with the core that read it.

## Decision

The actor enters a wake's words as a row of Max's account, marked
`said_by: wake` (or `vm`), and doesn't hand it to the sender. The row is
the wake's trigger: it is fed to the running core, or is among the first
inputs of the one it starts, as an @ is. It renders with a tag in place
of a name, `[12:00 max-wake #45]: …`. No count of wakes is shown to Max;
`/status` has it.

Why the classifier woke Max, `[判定：…]`, is an item: the rows it judged
are in the ledger already. The run's own reminders are items too: they
are about one run.

## Why

- **A later core sees why Max spoke.** The tail is the record of what
  happened in the conversation as Max saw it, and a wake is part of that.
- **One rule for what a core sees.** A core is its snapshot and every row
  after it, with no input that is neither.
- **`history` finds it.** An agent's report, or what a program said last
  week, can be searched and read by its number, and a long one is read in
  full that way where the wake shows only its beginning.
- **Nothing counts wakes for the model**: they are there to read.
- **Marked by `said_by`**, as a program's and the host's rows are: no
  change to the table and no new kind of content for every reader to
  handle.

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
- A wake doesn't say which program it came from: everything in a VM is
  one caller.

## Alternatives

- **An item only the core it reaches is shown**, with a count of the
  hour's wakes beside it, since a turn can't see the earlier ones: see
  Context.
- **A kind of its own in `messages.kind`**: it would say plainly that the
  row is no chat, at the cost of a migration and of every query that
  takes `chat` to mean what the model reads.
