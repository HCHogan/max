# Development

Tests, versioning, and debugging. For layout and internals see
[architecture.md](architecture.md).

## Tests

Two test suites — one in-memory, one against Postgres — plus CI (GitHub Actions)
running build + `max-test` through the same flake dev shell.

```sh
cabal test max-test                          # in-memory: pure logic
cabal test max-test-db                       # DB integration; needs MAX_TEST_DB_URL
cabal test all --test-show-details=direct    # both, verbose
```

### `max-test` (no DB)

Pure logic in `test/` mirroring the library layout:

- `Max.Command.ParserSpec` — every `!cmd` verb + edge cases
- `Max.SessionSpec` — pure session mutators (`addPin`, `clearAll`, …)
- `Max.Effects.LLMSpec` — `ChatMessage` JSON round-trip + `parseToolCall` tolerance
- `Max.MCP.ClientSpec` — Streamable-HTTP body decoding (JSON + SSE)
- `Max.MemoryExtractSpec` — extractor op-JSON parsing (fences, prose, bad actions)
- `Max.PersistenceSpec` — `withEphemeral` Reader scoping
- `Max.PromptSpec` — `renderContext`: section ordering, roster/名片 identity, 私聊 scene,
  memory block placement, quoted-forward expansion, assistant-run merging
- `Max.UtilSpec` — reply paragraph splitting (fences, caps)
- `OneBot.EventSpec` — group + private event parsing

### `max-test-db` (real Postgres)

```sh
createdb -h 127.0.0.1 -p 5433 max_test
export MAX_TEST_DB_URL=postgresql://127.0.0.1:5433/max_test
cabal test max-test-db
```

Without `MAX_TEST_DB_URL` the suite exits 0 (CI without a database stays green).
Every case runs after `TRUNCATE … RESTART IDENTITY CASCADE`.

## Versioning

`version:` in `max.cabal` is the single source of truth (surfaced by `!version`
via `Paths_max`). **Every feature update bumps it** — patch for fixes/tweaks,
minor for features — and releases get an annotated `vX.Y.Z` git tag. Startup
refuses to run against a database that records migrations this binary doesn't
ship, so an old max-bot can never touch a newer schema.

## Debugging

Raw NapCat traffic, no bot needed:

```sh
websocat -s 8080        # trigger a message; NapCat prints raw event JSON
```

Database:

```sh
pgcli "postgresql://127.0.0.1:5433/max"
```

Image blobs: `var/images/<2hex>/<sha256>`. Sandbox/browser containers: per-group
(`max-sb-*` / `max-br-*`), destroyed on `!clear --all` or shutdown, reaped on
boot. Outbox staging: `var/outbox/` (shared with NapCat container).

Bot logs are JSON on stdout with a `domain` field — useful filters: `max/conn-N`,
`max/image-worker`, `max/forward-worker`, `max/llm`, `max/cmd`, `max/memx`
(memory extraction), `max/intent` (proactive-trigger classification),
`max/shutdown` (graceful drain), plus `embed:` lines from the vector worker.
`!debug on` mirrors tool calls into the chat itself.
