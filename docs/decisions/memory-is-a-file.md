# Memory is a file Max writes and tidies itself

Each conversation's memory is one Markdown file that Max writes, keeps in
order and carries in every turn. Nothing on the host extracts memories or
tidies the file. The design is in [Memory](../design/context.md#memory).

## Context

Max has the raw records and a search over them (the ledger and
`history`). With a strong enough model, keeping raw records and letting
the model search works better and costs less than pre-extracted memory
such as Mem0 or Zep ([MemoryTax](https://arxiv.org/html/2610.29823)). But
that paper's questions all prompt the model to look something up. In a
group chat, memory is often needed with no such prompt, and the model
doesn't know what it has forgotten: with no memory at all, people call
Max "小鲨鲨" and it doesn't know the name, though it finds the answer at
once when told it has forgotten.

## Decision

Something is carried in every turn, and the main model decides what goes
into it, modelled on Claude Code's auto memory:

- One Markdown file per conversation in its VM's `/work`, injected into
  the volatile block and kept under a cap.
- No memory table, categories or expiry.
- Max appends a line with `echo`; a new line stays at the end until Max
  rewrites the file.
- The prompt says that recording comes first, before the reply, and that
  a round of waiting for it is fine.
- Tidying is Max's own. The prompt says nobody tidies the file for it,
  and the cap's reminder is what has it go over the whole file.

## Why

- **The model that reads the memory writes it**, in the turn where it
  learns something, and knows what would change how it speaks and acts.
- **Appending, not inserting.** Asked to insert entries by section and
  person, which is laborious with `shell`, and told that every extra call
  keeps people waiting a round, Max writes to the file once in 90 turns.
  A line at the end costs the model that reads the file nothing: each
  carries the name it is about and its date.
- **Recording first.** Asked to put the reply and the recording command
  in one output, reply first, Max doesn't record, and argues from the
  rules that nothing was worth it.
- **What the cap needs is a smaller file**, and only Max can make one: a
  tidy that may change no meaning can't move details out to another file.
- **Nothing else decides what Max's notes look like**, and there is no
  second model, key and failure to keep.

## Cost

- Up to 3k uncached tokens a turn.
- Memory is written in the VM, where the host sees it only at the next
  projection.
- An entry past its date, or said twice, stays until Max next goes over
  the file, which may be weeks.
- Going over the file happens in a turn somebody waits for.

## Alternatives

- **Entries a second model extracts from the chat**, stored in a table
  and picked at injection. Of 733 entries so made, 85% were written
  automatically; most of those labelled group rules were technical
  knowledge, while what should have been permanent, such as what people
  call Max, wasn't recorded. Of 101 dated commitments, 88 had expired
  unattended. Injection picked the 12 most recently changed, which has
  nothing to do with importance.
- **No memory**, only the records and search: see Context.
- **A nightly tidy by a model on the host**, one call a file that
  rewrites it whole: appended lines put under their headings, entries
  that say the same thing merged, those past their date dropped. Over
  three weeks it ran 51 times. Of the 28 runs the journal still had, 21
  left the file with as many lines as it had, and 7 changed the count by
  one to three. The files are far under the cap, 4 to 87 lines, so there
  was next to nothing to merge or drop, and what it did was put the day's
  line under a heading. The one file that did shrink, from 84 lines to 38
  with details moved to a file beside it, was rewritten by Max from its
  VM, as the cap's reminder asks. Four runs failed on the provider's
  errors.
