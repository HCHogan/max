# No historian, no summaries

2026-11-02, the owner, after a first removal on 2026-10-30 and a
comparison between groups.

## Context

On 2026-10-27, following [magic-context](https://github.com/cortexkit/magic-context),
a historian and three-level summaries were built: the historian cut the
chat into segments and summarised each, summaries decayed by age, and the
context carried a summary block before the raw tail.

## What happened

- **2026-10-30**: the owner removed all of it, for four reasons:
  - **Cost**: over the preceding day the historian made 49 calls and wrote
    406,000 output tokens, more than every turn's output together
    (304,000), and output is the most expensive part.
  - **Second-hand errors**: summaries misremember; the original words
    don't. That day Max said in the group it had been misled by a summary
    that recorded "13 块搓完整个原型" as "修一轮 bug 花 13 块".
  - **Complexity**: scheduling, validation, retries and discard-last, the
    decay curve, watermarks and publication timing, `/compact`, and the
    summary vectors and search came to more than 3,000 lines.
  - **Direction**: with a strong enough model, raw records plus its own
    search work better than pre-processed material (MemoryTax; see
    [decisions/2026-10-30-memory-is-a-file.md](2026-10-30-memory-is-a-file.md)).
    What summaries gave most was an index of "what was discussed those
    days", which `history` now gives by reading the original text by time
    and speaker.

  The tail's high watermark was raised the same day from 32k to 128k,
  since on a 1M window the tail was only 270 to 540 messages and people
  found Max forgetful; that evening it went back to 64k, as 128k doubled
  the input and changed how Max spoke.
- **The same evening**: after the removal Max's way of speaking had
  changed, and the owner wanted a long comparison. The historian, the
  summary block, decay and `/compact` came back unchanged behind a
  per-group switch, `/historian on|off` (owners only, off by default;
  `conversation_settings.historian`, migration 0021).
- **2026-11-02**: the owner ended the comparison; only conversation 12
  still had it on. Removed again, without a switch: the historian worker
  (`max/src/historian`, `max-core/src/historian.rs`), `[llm] historian`
  (also from tank's `hosts/tank/maxx.nix`, since max won't start with a key
  it doesn't know), the summary block, decay (`project/decay.rs`),
  `/historian` and `/compact` (ordinary messages now), the historian line
  in `/status`, and the summary queries. Migration 0023 drops the switch.

## Kept

The tables `summaries`, `summary_runs` and `summary_embeddings` with their
rows, and `llm_usage` rows of purpose `historian`; nothing reads or writes
them. A long-standing set of facts from the old summaries (running jokes,
names, group rules, people) was moved into the memory files by hand, since
without the summaries Max could no longer follow the groups' old jokes.
The historian's and decay's design is in `docs/rust-rewrite.md` at
`672f74ee`.

## Cost

The context holds the raw tail and the memory file only, so anything older
is found only if the model thinks to search for it.
