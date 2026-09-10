<div align="center">

# max 🦈

**Group chat agent done right**

[![CI](https://github.com/HCHogan/max/actions/workflows/ci.yml/badge.svg)](https://github.com/HCHogan/max/actions/workflows/ci.yml)
[![GHC](https://img.shields.io/badge/GHC-9.10-5e5086.svg)](https://www.haskell.org/ghc/)
[![Nix](https://img.shields.io/badge/Nix-flake-5277C3.svg?logo=nixos&logoColor=white)](flake.nix)
[![Postgres](https://img.shields.io/badge/Postgres-17%20+%20pgvector-4169E1.svg?logo=postgresql&logoColor=white)](devenv.nix)
[![License](https://img.shields.io/badge/license-MIT-000000.svg)](LICENSE)

</div>

Max treats a chat bot as a correctness problem. Every message, whichever
platform it arrives on, lands in one immutable canonical ledger with a
single typed message IR; deliveries — including mirroring one conversation
across platforms — go through a durable outbox that degrades content
deliberately instead of dropping it; and the LLM's context is a
rebuildable, integrity-checked projection of that ledger, not a sliding
window. The interesting decisions are written down in the ADRs.

```text
chat platforms
      │  adapters normalize losslessly; nothing degrades at ingest
      ▼
canonical message ledger ────┬──▶ mirror deliveries: native where a 
(one phase-indexed IR,       │     platform can, readable text where
 PostgreSQL, durable outbox, │     it can't - never silently dropped
 echo reconciliation)        ├──▶ agent turns: LLM, tools, sandbox,
                             │     browser, files, media
                             └──▶ context projections: episodes,
                                   memories, unified recall
```

## Highlights

- **One message IR, capability-tiered delivery.** Faces, cards, files,
  replies, and mentions keep their structure (and raw payloads for native
  round-trips) all the way to the ledger. Each endpoint declares
  native/text/drop per feature; a single lowering pass folds whatever an
  endpoint can't carry into readable text and records every degradation
  as an auditable note.
  ([ADR 003](docs/adr/003-message-ir-capability-rendering.md))
- **Mirrors that don't lie.** One canonical row per semantic message,
  per-endpoint durable deliveries with leases and idempotency keys, and
  ambiguous sends parked until an echo proves the outcome — a mirrored
  conversation neither drops nor duplicates.
- **Context as a database, not a window.** Raw messages are immutable;
  quiet-period episodes carry tiered summaries with exact, hash-checked
  source coverage; prompts are token-planned projections that degrade
  deterministically under budget and expand back to raw text on demand.
  ([ADR 001](docs/adr/001-context-memory-foundations.md))
- **Memory with an audit trail.** Conversation-scoped memories are
  versioned CAS records with evidence links and actor permissions — even
  the nightly consolidation pass must justify every change. Unified
  recall spans memories, episodes, raw history, pins, and media captions,
  lexical and semantic, with embedding provenance checked in SQL.
- **It reads its own source.** An allowlisted snapshot of this repository
  ships inside the binary; the bot answers questions about itself by
  searching and reading the exact deployed code, ADRs, and schema.
- Plus the table stakes: concurrent turns with streaming, cancellation,
  and mid-turn feedback; multimodal input; persistent per-group sandboxes
  and browser automation; skills, typed monitors, durable orchestration
  plans, proactive participation, and an authenticated local admin panel.

## Quick start

```sh
cp .env.example .env
cp max.yaml.example max.yaml
direnv allow                         # nix-direnv loads the flake devShell
devenv up --detached                 # PostgreSQL on 127.0.0.1:5433
cabal run max
```

Interactive development defaults to direnv with `use flake . --impure`, using
the same devShell as `nix develop --impure`. Entering the project loads the
environment into your current shell; leaving restores the outer environment.
nix-direnv caches the shell, and changes to `flake.nix`, `flake.lock`,
`devenv.nix`, or `.env` are picked up at the next prompt.

direnv loads `.env` with `dotenv_if_exists` after the Nix environment, so local
values override defaults from `devenv.nix`. This does not source `.env` as a
shell script. Plain `nix develop --impure` and CI require explicit environment
variables: devenv 2.3's built-in dotenv is unavailable through flakes.

The shared nix-config dev profile enables direnv and disables native devenv
auto-activation. When switching from the native hook, run `devenv revoke` with
the installed CLI in this repository, run `direnv allow`, and open a fresh
terminal so an existing native subshell or hook does not remain active.

The native CLI >= 2.3 remains an optional entry point through
`devenv.yaml`/`devenv.lock`, with `dotenv.enable` and background shell reload.
Inside the flake environment, `devenv` is a compatibility wrapper for `up`,
`tasks`, and `test`; use the installed native CLI's full path to invoke `shell`.
Native dotenv gives explicit `env` settings precedence and materializes values
in the local Nix store. Source-code compilation and running Max processes are
managed separately from either shell activation mechanism.

`devenv.yaml`/`devenv.lock` pin the same nixpkgs and devenv inputs as
`flake.lock`; after updating either entry point, synchronize the other and run
`python3 scripts/check-devenv-pins.py`. CI checks the resolved input graphs.

The NixOS module provisions native NapCat, browser services and command
sandboxes under `max-stack.target`. Enable `services.max.napcat.enable` for QQ,
then open <http://localhost:6099> on that host to log in. OneBot uses loopback
port 18080 by default. Migrations and derived-data backfills run automatically.
Local Haskell development does not require Docker; executing systemd sandboxes
requires the NixOS runtime services. See the [runtime and migration runbook](docs/runbooks/native-runtime.md).

After a NapCat reconnect, Max also makes a bounded, deduplicated history pass
over QQ conversations it already knows. Imported rows enrich context and media
queues but never trigger replies or mirror as new traffic. This is deliberately
best-effort message recovery, not a durable cursor: NapCat may omit messages
outside the returned windows and does not reconstruct offline reactions or
recalls.

Configuration is layered as CLI flags, environment variables, then YAML;
one LLM API key (OpenAI-compatible, OpenAI Responses, or Anthropic-native)
is the only required value, and optional feature sections stay disabled
when absent. For a real deployment, [`nix/module.nix`](nix/module.nix)
ships the whole thing as a systemd service. Max runs as a single
production instance for its author — a personal agent with
framework-grade plumbing, not a framework.

## Development

```sh
cabal test max-test
MAX_TEST_DB_URL=postgresql://127.0.0.1:5433/max_test cabal test max-test-db
cabal build all
```

| Document | Contents |
|---|---|
| [features.md](docs/features.md) | behaviour and configuration semantics |
| [architecture.md](docs/architecture.md) | runtime, context/memory design, and durability |
| [platforms.md](docs/platforms.md) | platform operations, mirroring, and cutover invariants |
| [ADR 001](docs/adr/001-context-memory-foundations.md) | context/memory invariants and privacy boundaries |
| [ADR 002](docs/adr/002-partial-plans-adaptive-elaboration.md) | historical partial-plan design; runtime contracts retained by ADR 008 |
| [ADR 003](docs/adr/003-message-ir-capability-rendering.md) | the message IR, capability-tiered lowering, and prior-art survey |
| [ADR 004](docs/adr/004-canonical-handles-for-the-model.md) | canonical handles for the model, and the identity it addresses |
| [ADR 005](docs/adr/005-turn-continuity.md) | turn continuity: durable traces, journal projections, verbatim replay |
| [ADR 006](docs/adr/006-monitors-typed-triggers.md) | typed durable monitors and the unified scheduler |
| [ADR 007](docs/adr/007-plans-as-orchestration.md) | existing durable fork/join plans; authoring direction superseded by ADR 008 |
| [ADR 008](docs/adr/008-durable-tasks-conversation-coordination.md) | durable tasks, monitor admission, and conversation coordination; local cutover candidate |
| [development.md](docs/development.md) | tests, evaluation, versioning, and debugging |
| [prompt-flow.md](docs/prompt-flow.md) | generated prompt and tool-round wire examples |

## License

[MIT](LICENSE) © Hank Hogan
