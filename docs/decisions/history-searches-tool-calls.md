# `history` searches tool calls when asked

`history` with `tools: true` searches the tool calls of the conversation's
turns, what each was given and what it returned, and `{ call: "t#12.3" }`
reads one whole. They are kept as text in a table of their own, written
with each turn's outcome. The design is in
[Recall](../design/context.md#recall).

## Context

Tool output lives only in its turn's transcript: the next turn is
projected afresh from the ledger, and sees what Max said, not what its
tools returned. The transcripts were kept, in each outcome's run, but
nothing read them. So Max couldn't look up what a search, a page or a
command gave it a few turns before, or how it had done something, short
of doing it again.

The runs held about 16,500 tool calls after four weeks: 60 MB of results
and 5.6 MB of arguments, against some 320,000 chat rows. Searching the
runs' JSON directly took 850 ms in the busiest conversation, and grows
with every turn.

## Decision

- **A switch, off by default.** A search goes through the chat unless it
  asks for tool calls; one search looks at one or the other.
- **A table of text**, `tool_calls`: per call, the tool, its arguments a
  line `key: value` each, and the text of its result, under a trigram
  index as messages' text has.
- **Derived in the database**, by a SQL function from the run: the
  outcome's insert writes the calls in the same statement, and the
  migration fills in the runs before with the same function.
- **Read by `t#N.n`**, the n-th call of turn t#N, whole and in pages.
- **Not reasoning**, which stays its turn's own, and not background
  agents' calls, which are in pi's sessions in the VM.

## Why

- **The chat stays the default.** Tool output is bulky and noisy, web
  pages, command output and JSON, and much of it says how things stood
  then: a price, a service's state, a file. Mixed into every search it
  would crowd out what people said, and old output would be taken for
  news.
- **A search a model asks for.** "What did that page say" and "how did I
  do it last time" are questions the model knows it is asking; a switch
  costs it one argument.
- **A table, not the runs.** The trigram index finds a call in tens of
  milliseconds however many turns there are, and the runs can lose their
  bulk later (their base context and opaque fields) without losing it.
- **One extraction.** What a call's text is is written once, in SQL, for
  the turns before and the turns after, and written with the outcome it
  comes from: there is never an outcome without its calls.

## Cost

- **The run's JSON is read in SQL.** `tool_calls_of` knows how an item is
  serialized; a change to it needs a migration that replaces the function.
- **About 65 MB of text and its index**, growing with the turns.
- **Whatever went into a call can be found**: an account's password Max
  typed for someone, a token a command printed. Only from the same
  conversation, which is the unit of permission anyway.
- **A turn lost in a crash has no calls**, as it has no run.
- **Output is as it was shown**: a result cut to 16 KiB is cut here too;
  the whole is in the VM's `/work/.max/out/` while Max keeps it.

## Alternatives

- **Tool output in every search**: no argument to learn, but every search
  wades through it.
- **A tool of its own** (`turn_read(t#N)`, reading a whole turn): reading
  without finding, and a second recall tool where one applies the same
  filters.
- **Searching the runs' JSON**: nothing to write, but a scan of every run
  in the conversation for each search.
- **Writing the rows from max** as the turn ends: the same text made in
  Rust for new turns and in SQL for the old, two versions to keep alike.
