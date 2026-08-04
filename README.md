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
canonical message ledger ────┬──▶ mirror deliveries: native where a platform
(one phase-indexed IR,       │     can, readable text where it can't —
 PostgreSQL, durable outbox, │     never silently dropped
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
  and browser automation; skills, reminders, proactive participation, and
  an authenticated local admin panel.

## Quick start

```sh
direnv allow                         # or: nix develop --impure
cp .env.example .env
cp max.yaml.example max.yaml
devenv up                            # PostgreSQL on 127.0.0.1:5433
docker compose up -d napcat
cabal run max
```

Open <http://localhost:6099> to log the bot account into QQ. Migrations and
derived-data backfills run automatically. Build `sandbox-image/` and
`browser-image/` only when those tools are needed.

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
| [ADR 002](docs/adr/002-partial-plans-adaptive-elaboration.md) | partial plans, adaptive elaboration, and safe deoptimization |
| [ADR 003](docs/adr/003-message-ir-capability-rendering.md) | the message IR, capability-tiered lowering, and prior-art survey |
| [development.md](docs/development.md) | tests, evaluation, versioning, and debugging |
| [prompt-flow.md](docs/prompt-flow.md) | generated prompt and tool-round wire examples |

## License

[MIT](LICENSE) © Hank Hogan
