# Code size and responsibility

Counts expose maintenance cost; they do not justify deleting major features.
The September 22 checkpoint includes restored layered summaries and the
responsibility split for ingress, dispatch and platform storage. See the earlier
[deployment observations and limits](research/simplification-7-8-13-release-20260919.md).

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
| Core Haskell | 32,909 |
| Platform/provider adapters | 4,203 |
| Concrete tools/media | 3,431 |
| Isolation/runtime adapters | 3,404 |
| Optional admin Haskell | 1,819 |
| Additional owned production code | 7,361 |
| Tests | 20,970 |
| Development/evaluation tools | 3,262 |
| Historical migration files | 4,275 |
| Vendored code | 8 |

`src + app` is **45,766 effective Haskell lines**, down 6,861 from the initial
52,627 baseline. Owned production source totals **53,127** before installed SQL.
Tests, developer tools, migration history and vendored code are reported
separately. Patch files, configuration, data and binary assets are excluded from
source LOC; they remain maintenance costs, not deleted features.

Compared with the immediately preceding `cdabd21` source checkpoint, core
Haskell is 32,121 → **32,909** (+788), and `src + app` is 44,961 → **45,766**
(+805). Explicit module imports, exports and named records add lines while
making responsibility and capability boundaries local. This pass preserves
features and SQL behavior; it is not a source-size reduction. Active and archival
SQL are unchanged.

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

The measured core is therefore **34,656 lines including active SQL**. Owned
production source plus active SQL is **54,874 lines**; retained archival schema
adds another 678. The aspiration of a core below 10,000 has not been reached.
Moving business policy into adapters or hiding SQL would not change that fact.

Largest core Haskell files:

| File | Effective code lines |
|---|---:|
| `src/Max/Config.hs` | 1,374 |
| `src/Max/EpisodeStore.hs` | 1,065 |
| `src/Max/MemoryStore.hs` | 789 |
| `src/Max/Prompt/Render.hs` | 705 |
| `src/Max/DB/Monitor.hs` | 683 |
| `src/Max/Platform/Store/Ingest.hs` | 619 |
| `src/Max/Recall.hs` | 558 |
| `src/Max/Handler/QQ.hs` | 548 |
| `src/Max/Historian.hs` | 547 |
| `src/Max/Command/Dispatcher.hs` | 538 |

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
