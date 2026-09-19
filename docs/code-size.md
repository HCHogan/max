# Code size and responsibility

Counts expose maintenance cost; they do not justify deleting major features.
This checkpoint includes sections 7–8 and 13: monitor lease/replay removal,
explicit Agent outcomes, named loop state and dispatch ownership. See the separate
[deployment observations and limits](research/simplification-release-20260919.md).

## Reproduce

Use tokei and an isolated database with exactly the shipped migrations:

```sh
cabal run -v0 max-prompt-flow -- --stats > /tmp/max-prompt-size.json
MAX_TEST_DB_URL='postgresql://127.0.0.1:5433/max_test' python3 scripts/count-code.py \
  --schema --prompt-stats /tmp/max-prompt-size.json > /tmp/max-code-size.json
```

Without `--schema`, the script measures source only. It validates every
non-ignored `src`/`app` Haskell file against [code-scope.json](code-scope.json).
With `--schema`, read-only PostgreSQL catalog queries validate every public
table/view against [schema-scope.json](schema-scope.json). `pg_dump` supplies
standard schema formatting; tokei counts effective code, comments and blank
lines separately. The JSON report includes the source file breakdown, schema
classification, migration ledger and optional prompt statistics.

## Source checkpoint

Measured with tokei 14.0.0 and PostgreSQL 17.11:

| Responsibility | Effective code lines |
|---|---:|
| Core Haskell | 31,979 |
| Platform/provider adapters | 4,192 |
| Concrete tools/media | 3,401 |
| Isolation/runtime adapters | 3,420 |
| Optional admin Haskell | 1,815 |
| Additional owned production code | 7,361 |
| Tests | 20,513 |
| Development/evaluation tools | 3,250 |
| Historical migration files | 4,275 |
| Vendored code | 8 |

`src + app` is **44,807 effective Haskell lines**, down 7,820 from the initial
52,627 baseline. Owned production source totals **52,168** before installed SQL.
Tests, developer tools, migration history and vendored code are reported
separately. Patch files, configuration, data and binary assets are excluded from
source LOC; they remain maintenance costs, not deleted features.

Compared with the clean pre-change `15316a9` checkpoint, core including SQL is
33,842 → **33,726** (−116); `src + app` is 44,908 → **44,807** (−101).
Named capability records and SQL decoders intentionally take more lines. The
reduction comes from deleted runtime protocols, not removed product features
or changed counting scope. Historical SQL falls separately when obsolete debt
views are removed; old evidence tables remain.

## Installed SQL

| Installed schema | Effective SQL lines |
|---|---:|
| Active relations and shared functions | 1,747 |
| Retained archival structures | 678 |
| Complete public schema | 2,425 |

There are 53 active tables/views and 31 archival tables/views. Sequences follow
their owning table; unowned sequences (including public Job IDs) remain active.
All installed functions and legacy columns on active tables are counted in full.
The archival category retains old execution, materialization and review history;
it does not erase rows or remove their integrity constraints. Historical migration
files describe the upgrade path and are not counted a second time as active SQL.

The measured core is therefore **33,726 lines including active SQL**. Owned
production source plus active SQL is **53,915 lines**; retained archival schema
adds another 678. The aspiration of a core below 10,000 has not been reached.
Moving business policy into adapters or hiding SQL would not change that fact.

Largest core Haskell files:

| File | Effective code lines |
|---|---:|
| `src/Max/Platform/Store.hs` | 2,555 |
| `src/Max/Handler.hs` | 1,949 |
| `src/Max/Config.hs` | 1,374 |
| `src/Max/EpisodeStore.hs` | 1,043 |
| `src/Max/MemoryStore.hs` | 835 |
| `src/Max/DB/Monitor.hs` | 683 |
| `src/Max/Prompt/Render.hs` | 689 |
| `src/Max/Recall.hs` | 558 |
| `src/Max/Command/Dispatcher.hs` | 538 |
| `src/Max/Historian.hs` | 536 |

## Prompt fixture

`max-prompt-flow --stats` measures the same source-backed fixture and request
builders as [prompt-flow.md](prompt-flow.md), without calling a model. The fixed
system message is 11,182 UTF-8 bytes. Its deliberately small two-tool catalog
has an estimated 407 tokens.

| Protocol | First request bytes | After tool return bytes | Estimated message tokens, first / second |
|---|---:|---:|---:|
| Chat Completions | 16,555 | 17,095 | 4,895 / 5,101 |
| Anthropic Messages | 16,629 | 17,266 | 4,895 / 5,128 |
| Responses | 16,564 | 17,116 | 4,895 / 5,102 |

Token figures use the production conservative estimator; tool schemas and the
attachment reserve are additional. Byte counts use compact wire JSON including
fixture media, not Markdown formatting. This fixture is not the full enabled
tool catalog, representative live traffic, provider billing or a model-quality
comparison. Those claims require separately recorded runtime evidence.

The [live comparison](research/simplification-evaluation.md) records a separate
small experiment. Its JSON stores the one-off runner verbatim as historical data;
it adds no executable target or runtime mechanism.
