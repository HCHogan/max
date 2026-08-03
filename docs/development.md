# Development

Tests, versioning, and debugging. For layout and internals see
[architecture.md](architecture.md).

## Tests

Two test suites — one in-memory, one against Postgres — plus CI (GitHub Actions)
running the build and both suites through the same flake dev shell. CI provides
PostgreSQL 17 with pgvector; the database suite is a required release gate.

```sh
cabal test max-test                          # in-memory: pure logic
cabal test max-test-db                       # DB integration; needs MAX_TEST_DB_URL
cabal test all --test-show-details=direct    # both, verbose
```

### `max-test` (no DB)

Pure logic in `test/` mirroring the library layout:

- `Max.BilibiliSpec` — BV / b23.tv / URL extraction from cards and plain text
- `Max.Command.ParserSpec` — every `!cmd` verb + edge cases
- `Max.Command.PermissionSpec` — tier resolution and capability gating
- `Max.ConversationScopeSpec` — opaque current-scope authority and the only
  permitted directional group-to-DM recall proof
- `Max.Effects.AgentSpec` — full in-memory Agent loop using a fake LLM, fake
  validated tool catalog, explicit TurnRuntime, and typed AgentEvent sink;
  mutating multi-call rounds are proven sequential, and feedback/kill/late
  streaming cleanup all cross the runtime seam
- `Max.Effects.BlobSpec` — opaque digest references, byte round-trips, the
  explicit host-path escape hatch, and rejection of path-shaped references
- `Max.Effects.EmbeddingSpec` — injectable embedding space, validated records,
  typed provider/shape failures, timeout injection, and model/dimension cutover
- `Max.Effects.LLMSpec` — `ChatMessage` JSON round-trip, `parseToolCall`
  tolerance, and the streamed assistant message rebuilt from deltas
- `Max.Effects.OutboundSpec` — in-memory interpreter seam and the distinction
  between failed, delivered-unrecorded, and durably recorded sends
- `Max.Effects.ToolOutputSpec` — turn-scoped media draining, fresh interpreter
  state, and attachment budgets that survive per-round drains
- `Max.Effects.ToolsSpec` — catalog uniqueness/schema/metadata validation,
  argument rejection before execution, and typed recovery outcomes
- `Max.LLM.StreamSpec` — SSE framing and the OpenAI/Anthropic delta reducers,
  replayed from recorded wire bytes
- `Max.LogSpec` — compact log line formatting
- `Max.HandlerSpec` — durable-ingest gating, `[silence]` parsing, message
  recording classification, and ReplySend marker-cleanup regressions
- `Max.IntentSpec` — proactive verdict parsing and the heuristic gate
- `Max.MatrixSpec` / `Max.IMessageSpec` — native event/relation normalization,
  secret-redacted configuration, and iMessage send-status classification
- `Max.MCP.ClientSpec` — Streamable-HTTP body decoding (JSON + SSE)
- `Max.HistorianSpec` / DB counterpart — token-sized episode prefixes, explicit
  identity provenance, structured-call publication, and raw-output retention
- `Max.ContextMaterializationSpec` (DB) — active-projection validation,
  optimistic revision publication, append-only versions, and stale-source
  rejection at the prompt cache-bust boundary
- `Max.EpisodeStoreSpec` — strict capture schema, evidence validation,
  source-hash/CAS rollback, leases, rebuild/backfill, and proposal isolation
- `Max.MemoryExtractSpec` — nightly-maintenance op JSON plus quiet-scheduler
  retry/race behavior
- `Max.MaintenanceLeaseSpec` (DB) — same-domain serialization, independent
  maintenance domains, expiry takeover, and fencing against stale owners
- `Max.PlatformSpec` — platform-id mapping
- `Max.Platform.DeliverySpec` — canonical inline/blob/base64 media resolution
  and bounded delivery projection
- `Max.PlatformStoreSpec` (DB) — native-event dedupe, cursor CAS, dispatch and
  delivery leases, mirror fan-out, outcome-unknown parking, echo/status
  reconciliation, and endpoint diagnostics
- `Max.PromptSpec` — `renderContext`: the flat transcript and the
  `history_as_turns` shape (including that neither can produce two consecutive
  same-role messages), section ordering, roster/名片 identity, 私聊 scene,
  memory block placement, quoted-forward expansion, in-flight hiding, and
  deterministic P1/P2/P3/P4 decay before a token-sized raw tail; context
  candidates and selected plans are distinct types, and selection uses one
  full-prompt measurement plus block-local cost deltas
- `Max.PromptFlowSpec` — generated `docs/prompt-flow.md` matches the live
  Prompt → Agent → LLM rendering path, including P1/P2/P3/P4 omission,
  unified recall result rendering, and one-turn episode expansion (regenerate
  with `cabal run max-prompt-flow`)
- `Max.RenderSpec` — markdown table → typst
- `Max.ReplySpec` — reply paragraph splitting (fences, `[split]`, chunk ceiling)
- `Max.ReplySendSpec` — that splitting a reply at a `readyPrefix` boundary sends
  the same messages as never splitting it, plus the per-reply chunk ceiling
- `Max.Sandbox.DockerSpec` — package wrapping and exec argv
- `Max.SessionSpec` — pure session mutators (`addPin`, `clearAll`, …)
- `Max.ShutdownSpec` — drain flag / in-flight counter transitions
- `Max.SelfSourceSpec` — the allowlisted compile-time bundle, stable identity,
  literal search, bounded numbered reads, and host-path rejection
- `Max.SkillsSpec` — builtin skills parsed from `skills/`, including the
  `docs/features.md` and live `!help` splices into `self-knowledge`
- `Max.TasksSpec` — explicit TurnRuntime lifecycle/phase/cancellation plus task
  feeding, aimed `!feedback`, in-flight bookkeeping, and unserved-note recovery
- `Max.Http.JsonSpec` — buffered HTTP retry policy
- `Max.HttpRuntimeSpec` — connection reuse, bounded bodies, status previews,
  timeout classification, and response cleanup under cancellation
- `OneBot.EventSpec` — group + private event parsing
- `OneBot.SegmentSpec` — segment codec, mention conversion, card parsing

### `max-test-db` (real Postgres)

```sh
createdb -h 127.0.0.1 -p 5433 max_test
export MAX_TEST_DB_URL=postgresql://127.0.0.1:5433/max_test
cabal test max-test-db
```

Without `MAX_TEST_DB_URL` the suite exits 0 for local workflows that do not have
Postgres available. CI always supplies the variable and requires the suite.
Every case runs after `TRUNCATE … RESTART IDENTITY CASCADE`.
`Max.DB.TransactionSpec` additionally proves that every statement in the
application transaction runs on one physical pooled connection by throwing
after an insert and checking that rollback removed it. This guards row locks,
advisory transaction locks, and atomic cursor/publication boundaries against
connection-pool drift.
The prompt integration cases also publish real active compartments, assert
gap annotations for partial backfill, and exercise the all-conversation
compartment-to-raw-tail reader end to end. EpisodeStore cases additionally
page opaque `context_expand` handles over the exact raw range, deny the same
handle from another conversation, and verify that a superseded projection's
handle remains expandable. `Max.ContextMaterializationMigrationSpec` runs 043
over a pre-existing development revision, checking that current-state naming
and UUID handles backfill without mutating the append-only revision ledger.
`Max.RecallSpec` builds memory, episode, raw, pin, and caption candidates in a
real conversation, checks lexical and compatible-pgvector fusion, exercises
provenance/message dedup and source quotas, and probes the same queries from a
foreign conversation. The pure Recall spec separately fixes quota, overflow,
deduplication, and deterministic ordering semantics. `Max.MemoryStoreSpec`
also checks that maintenance receives current evidence and that evidenced
supersession appends its lifecycle version, evidence, and audit atomically.

### Unbounded-context release gate

The checked-in Historian fixtures cover attribution, corrections, ambient
chatter, dated decisions and commitments, relative dates, rejected jokes,
Reminder separation, media/reply handles, and evidence-backed memory updates.
Validate all labels and the disabled direct-auto-recall policy without an API
call:

```sh
cabal run max-context-eval -- --offline-only
```

Replay the exact production Historian path against a candidate profile and
repeat every fixture to expose stochastic schema/quality failures:

```sh
cabal run max-context-eval -- --eval-profile PROFILE --runs 3 \
  --min-pass-rate 1
```

`--case TEXT` narrows Historian fixtures while tuning one failed expectation.
The evaluator counts a bounded schema-repair call in both latency and
per-capture token totals. Passing recall fixtures never enables auto-hints;
production injection remains disconnected until a separate product decision.

The final cutover gate replays the manually anonymized, production-derived
fixture independently from the synthetic wiring baseline:

```sh
cabal run max-context-eval -- \
  --historian-fixture context-eval/fixtures/historian-real.jsonl \
  --eval-profile PROFILE --runs 3 --min-pass-rate 1
```

### Context operations console

The authenticated admin panel's `上下文` tab exposes the release and incident
diagnostics for the new lifecycle. All endpoints accept an optional `group`
query filter where relevant:

```text
GET  /api/context/status
GET  /api/context/captures
GET  /api/context/compartments
GET  /api/context/plans
GET  /api/context/embeddings
GET  /api/context/recall?group=...&q=...
GET  /api/context/memories/:id
GET  /api/context/integrity
POST /api/context/rebuild
POST /api/context/reindex
```

Prompt traces retain only budget decisions and source names, never a second
copy of the prompt body, and are capped at 200 per conversation. Rebuild is
staged and CAS-published; repeated clicks cannot enqueue two open replacements
for the same compartment. Reindex is a recoverable derived-data operation and
returns `409` while the embedding worker owns its maintenance lease.

### Platform release gate

The canonical platform migration and adapters are covered by the ordinary
pure/DB suites. The Mac-side bridge has its own Go gate:

```sh
cd bridge/imsg && go test ./...
```

For a release, recreate the test database before the DB suite so migration
`001` through the current tip is exercised instead of only testing an already
upgraded schema:

```sh
dropdb --if-exists -h 127.0.0.1 -p 5433 max_test
createdb -h 127.0.0.1 -p 5433 max_test
MAX_TEST_DB_URL=postgresql://127.0.0.1:5433/max_test \
  cabal test max-test-db --test-show-details=direct
```

With the admin server enabled, `GET /api/platforms/status` exposes cursor
revision/fingerprint, last inbound time, endpoint capabilities, pending depth,
and ambiguous/suppressed delivery counts. Deployment, Matrix room setup,
iMessage Full Disk Access/Automation, incident SQL, and rollback are documented
in [platforms.md](platforms.md).

## Config: finding out where a value came from

Settings are layered CLI > env > YAML > default, and the env layer is the one
that surprises people: a `MAX_*` variable in scope makes the matching YAML key
dead, with no warning. The dev shell exports `MAX_DB_URL`, `MAX_WS_HOST`,
`MAX_WS_PORT` and `MAX_WS_PATH` (`devenv.nix`), and their values equal the
built-in defaults — so an overridden key looks exactly like a key that fell
back to its default. The NixOS module exports six more on purpose
(`nix/module.nix`), which is why `db.url`, `images_dir`, `migrations_dir`,
`server.host`, `log_color` and `server.access_token` have no effect in a
module-managed deployment's yaml.

Two flags settle it, neither listed in `--help`:

```sh
max --run-settings-check --config-file max.yaml   # one line per setting, and where it came from
max --debug-optparse                              # the parser tree, when that isn't enough
```

`--run-settings-check` parses and exits — no database, no server, so it is safe
to point at a live deployment's config (as its user:
`sudo -u max-bot env $(systemctl show max -p Environment --value) … --run-settings-check`).
A key you wrote that doesn't show up as *"set based on config value"* was
either overridden by env or misspelled.

**Unknown keys are ignored silently.** opt-env-conf looks up only the paths the
parser declares; nothing enumerates the leftovers. A typo'd `owners` means
nobody is an owner and every owner-tier command refuses with no explanation.
Two things are loud now: an explicitly named `--config-file` that doesn't exist
is an error rather than a fall-through to `./max.yaml` (`resolveConfigFile`),
and startup logs `config_file=` so which file was read is never a guess.

## Versioning

`version:` in `max.cabal` is the single source of truth (surfaced by `!version`
via `Paths_max`).

**Bump only for a large feature or a refactor.** Fixes, small features and
ordinary follow-ups ride along at the current version — a long run of commits
sharing one is the normal case, not a lapse. The number is there to name work
worth naming and to fence old binaries off new schemas; a version per deploy or
per commit makes it noise, and the history it produces says nothing you couldn't
read from the log. Minor for the feature or refactor itself, patch only when
something already released needs correcting on its own.

Tags are lightweight `vX.Y.Z`, placed on the commit that bumps the version —
later commits at the same version stay behind the tag rather than moving it.

Startup refuses to run against a database that records migrations this binary
doesn't ship, so an old max can never touch a newer schema.

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

One log line per event, on stdout:

```
14:32:07 INFO  llm      llm dispatch  group_id=7777 message_id=7413 origin=OriginDirect
14:32:09 WARN  llm      agent: tool failed  error="timeout after 15s" name=web_search
```

Fixed-width time and level, then the domain (dim), the message, and the
structured data as `key=value`. Multi-line values collapse to one line with `⏎`,
so `grep -A` / `grep -B` count events rather than JSON braces.

Useful domain filters: `conn-N`, `image-worker`, `forward-worker`, `llm`, `cmd`,
`historian` (episode capture), `memory-dream` (memory maintenance), `intent`
(proactive-trigger classification), `shutdown` (graceful drain).

Historian dispatch logs include `timeout_seconds` and `transport_retries=0`.
Capture rows retain attempt, lease, `next_retry_at`, validation output, and the
exact source range; use the admin context console to distinguish a long call
from durable backoff. The worker claims fresh pending ranges before overdue
retries, so a repeatedly bad range should not stop newer first attempts.

`log-base` has three levels and they map straight across: `TRACE` / `INFO` /
`WARN`. There is no separate error tier — `logAttention` carries both recoverable
warnings and outright failures, and splitting them means auditing all ~78 call
sites, not guessing at format time.

- `--log-level trace|info|warn` (`MAX_LOG_LEVEL`, `log_level:`) — the floor.
- `--log-color auto|always|never` (`MAX_LOG_COLOR`, `log_color:`) — `auto` is
  "stdout is a tty and `NO_COLOR` is unset". Under systemd stdout is a pipe to
  journald, so a host whose logs are read through `journalctl` wants `always`.

**Reading a coloured log needs `-o cat`:**

```sh
journalctl -u max -f -o cat
```

journald stores the escapes fine, but every `short*` / `with-unit` / `verbose`
format strips control characters out of the message — terminal escapes in a log
line are an injection vector, and `cat` is the "raw, you asked for it" format.
It is also the only one that prints no timestamp prefix, which is why the log's
own clock is rendered in the host's timezone rather than UTC: on that path it is
the only clock there is. (Not `timezone_minutes` — that one is what the group
and the model see; this line is read next to `systemctl status`, so it follows
the machine.)

On NixOS, note that `services.max.settings` is discarded outright when
`services.max.configFile` is set (the module warns). To add one key on top of a
hand-managed max.yaml, use the environment instead:

```nix
systemd.services.max.environment.MAX_LOG_COLOR = "always";
```

`!debug on` mirrors tool calls *and their results* into the chat itself.

Media that never arrived: a pending fetch is a row now, so ask the database
rather than grepping logs.

```sql
SELECT kind, dedupe_key, attempts, parked_at, last_error FROM fetch_jobs;
```

Rows still present are in flight, waiting, or — with `parked_at` set — gave up
after `Max.DB.FetchQueue.maxAttempts` tries. Nothing there means the download
succeeded and the row was dropped.
