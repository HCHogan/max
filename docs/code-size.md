# Code size and responsibility

This records the Haskell responsibility boundary before the main conversation,
Jobs and context replacement. Counts help identify complexity; they do not
justify deleting major features. Preserving functionality and readability takes
priority over reaching a particular number.

Run `python3 scripts/count-code.py > /tmp/max-code-size.json` from the checkout.
The script uses tokei and validates every non-ignored `src`/`app` Haskell file
against [code-scope.json](code-scope.json), rejecting missing or duplicate
classifications. New files require an explicit responsibility review.

Snapshot after `6f64255`, measured with tokei 14.0.0:

| Responsibility | Effective code | Comments | Blank |
|---|---:|---:|---:|
| Core Haskell | 36,083 | 4,613 | 2,881 |
| Platform/provider adapters | 4,172 | 621 | 346 |
| Concrete tools/media | 3,525 | 435 | 258 |
| Isolation/runtime adapters | 3,435 | 371 | 339 |
| Optional admin Haskell | 2,043 | 114 | 77 |
| Additional owned production code | 7,466 | 1,308 | 449 |
| Tests | 21,629 | 1,123 | 2,044 |
| Development/evaluation tools | 3,157 | 119 | 228 |
| Historical migrations | 4,120 | 1,440 | 1,078 |
| Vendored code | 8 | 3 | 0 |

The core Haskell component is **36,083 lines**. Active SQL schema and database
functions must be added before final acceptance. The sub-10,000 core aspiration
is therefore still far away and is not an acceptance gate. `src + app` totals
49,258 effective Haskell lines; additional owned production code brings the
measured production subtotal to
56,724 lines, excluding active SQL, historical migrations, tests and developer
tools. Patch files, prompt/configuration documents and binary assets are not
source LOC in this report and remain separate maintenance costs.

The manifest keeps all business repositories, generic IR/lowering, routing and
publication in core. It also includes browser task/profile authority, tool
interfaces, context policies, command permissions, shared HTTP/SSE and startup.
A mixed module is counted whole; moving business policy into an adapter does
not justify moving it out of the core budget. Native codecs, concrete
integrations, OS isolation and the optional admin surface are shown separately.

Largest core files in this snapshot:

| File | Effective code |
|---|---:|
| `src/Max/Platform/Store.hs` | 2,763 |
| `src/Max/Handler.hs` | 2,146 |
| `src/Max/Config.hs` | 1,361 |
| `src/Max/EpisodeStore.hs` | 1,309 |
| `src/Max/Prompt/Render.hs` | 841 |
| `src/Max/MemoryStore.hs` | 835 |
| `src/Max/DB/Monitor.hs` | 798 |
| `src/Max/DB/AgentTurn.hs` | 710 |
| `src/Max/Historian.hs` | 644 |
| `src/Max/Recall.hs` | 558 |
| `src/Max/Command/Dispatcher.hs` | 535 |
| `src/Max/Platform/Delivery.hs` | 503 |
| `src/Max/Reply.hs` | 481 |
| `src/Max/IR.hs` | 463 |
| `src/Max/Prompt/Collect.hs` | 445 |

These measurements prioritize replacing durable task/conversation control,
publication state and context materialization. Removing comments, hiding SQL
in migration files or relabeling policy modules does not advance the core goal.

## Jobs checkpoint

Working tree following `7835971`, measured with the same manifest and tokei:
core Haskell **33,596**; src/app Haskell **46,728**. This is 1,928 fewer src/app
lines than the foreground checkpoint and 5,899 below the initial 52,627 baseline.
Tests now have 20,330 effective code lines. Obsolete execution-protocol tests were
retired; current behavior and upgrade coverage remain. Active SQL accounting and
the remaining simplification stages are still pending.
