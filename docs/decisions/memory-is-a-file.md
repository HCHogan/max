# Memory is a file Max writes itself

Each conversation's memory is one Markdown file that Max writes itself and
every turn carries. The design is in [Memory](../design/context.md#memory).

## Context

- In the Haskell version, memory was entries the historian extracted. Of
  733 entries, 85% were written automatically; most of those labelled
  group rules were technical knowledge, while what should have been
  permanent, such as what people call Max, wasn't recorded. Of 101 dated
  commitments, 88 had expired unattended. Injection picked the 12 most
  recently changed, which had nothing to do with importance.
- maxx went live with no memory. People called Max "小鲨鲨" and it didn't
  know the name; only when told "不记得了" did it search, and
  it found the answer at once.
- [MemoryTax](https://arxiv.org/html/2610.29823): with a strong
  enough model, keeping raw records and letting the model search works
  better and costs less than pre-extracted memory (Mem0, Zep). Max has the
  raw records and the search (the ledger and `history`). But the paper's
  questions all prompt the model to look something up; in a group chat,
  memory is often needed with no such prompt, and the model doesn't know
  what it has forgotten.

## Decision

Something carried in every turn, with the main model deciding what to
record, modelled on Claude Code's auto memory: one Markdown file per
conversation in its VM's `/work`, injected into the volatile block, kept
under a cap, and tidied nightly by the dreamer. No memory table,
categories or expiry. The Haskell version's memories were moved into an
initial file per group by hand, by a sub-agent, dropping everything of no
use.

## What was learned in use

- **Append, don't insert**: on its first day Max wrote to the file once in
  90 turns. It had been asked to insert entries by section and
  person, which is laborious with `shell`, and a prompt line ("每多跑一次
  run_code 群友就多等一轮") made it reluctant to make an extra call. It now
  appends one line with `echo`, and the dreamer places it.
- **The dreamer**: the model only ever added and never tidied.
- **Record first, then reply**: the prompt had asked Max to put
  the reply and the recording command in one output, reply first, and write
  `[silence]` after recording; it never did. Its only write that day came
  when someone asked it to delete an entry, and asked whether it had
  recorded anything lately, it argued from the rules that nothing had been
  worth it. The prompt now says plainly that recording comes first and a
  round of waiting is fine.

## Cost

Up to 3k uncached tokens a turn, and memory written in the VM, where the
host sees it only at the next projection.
