# One tool for recall, on trigrams and half-precision vectors

Max recalls with one tool, `history`, which searches when given a query and
reads without one. The design is in [Recall](../design/context.md#recall).

## Context

Recall was first built as two tools, `context_search` (literal and semantic
search) and `context_read` (several read modes). A request like "what
Xiaoming said the day before yesterday" then meant first choosing a tool
and assembling its arguments, though both apply the same filters (who,
when) and differ only in whether there is a query. The Haskell version also
had one entry point for recall; memory isn't searched.

## Decisions

- **One tool, `history`**: with a query it searches, without it reads.
- **Stickers are searched too**: everything can always be searched, though
  a sticker's caption describes what it is and when to use it.
- **`/clear --all` doesn't limit it**, as in the Haskell version: the
  watermark governs only what the context shows.
- **`lower(text) like`**, not `ilike`, which was more than three times
  slower (178 ms against 50 ms).
- **`halfvec(1024)`** for message vectors, not `vector`.

## Measurements

- Search, without indexes, read-only on tank's `maxx`: on the
  largest conversation, 62,000 rows, about 85 ms for 1 term, 97 ms for 2,
  145 ms for 8; summaries (848 in one conversation) 36 ms for 2 terms and
  61 ms for 8.
- With the trigram index, on the old Haskell database (290,000 rows, the
  same index on `rendered_text`): a 3-character term 19 ms, a 4-character
  term 2 ms, two 3-character terms 13 ms. For a 2-character term the custom
  plan scans row by row in 182 ms, while the generic plan reads the whole
  index in 496 ms, hence `force_custom_plan`. The index takes 88 MB there.
- `halfvec` against `vector`, at 225,000 rows: the table and HNSW index
  take about 1.2 GB against 3 GB. In 50 searches over 20,000 random
  vectors (where distances crowd most), the top ten were the same every
  time and in the same order in 49, distances differing by at most
  0.00004.
- HNSW, on dev Postgres 17 on a Mac (`maintenance_work_mem` 64 MB, 225,000
  random unit vectors): building on a filled table took 9 min 30 s with
  `vector` (1.76 GB) and 6 min with `halfvec` (586 MB); the migration
  builds it on an empty table, in milliseconds. Inserting 225,000 `halfvec`
  rows into an indexed table took 17 minutes (with a compilation running);
  20,000 rows took 50 s with `vector` and 38 s with `halfvec`. Queries
  (`halfvec`, limit 90): a 56,000-row conversation 36 ms by HNSW, a
  2,250-row one 16 ms by the btree and a sort.

## Cost

Short Chinese terms have no trigrams and are compared row by row within
the conversation, so searches are capped at 4 at a time across all groups.
