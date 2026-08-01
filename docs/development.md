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

- `Max.BilibiliSpec` — BV / b23.tv / URL extraction from cards and plain text
- `Max.Command.ParserSpec` — every `!cmd` verb + edge cases
- `Max.Command.PermissionSpec` — tier resolution and capability gating
- `Max.Effects.AgentSpec` — narration → segments (placeholder handling, mentions)
- `Max.Effects.LLMSpec` — `ChatMessage` JSON round-trip, `parseToolCall`
  tolerance, and the streamed assistant message rebuilt from deltas
- `Max.LLM.StreamSpec` — SSE framing and the OpenAI/Anthropic delta reducers,
  replayed from recorded wire bytes
- `Max.LogSpec` — compact log line formatting
- `Max.HandlerSpec` — `[silence]` parsing, marker stripping, `isCommandMessage`
- `Max.IntentSpec` — proactive verdict parsing and the heuristic gate
- `Max.MCP.ClientSpec` — Streamable-HTTP body decoding (JSON + SSE)
- `Max.MemoryExtractSpec` — extractor op-JSON parsing (fences, prose, bad actions)
- `Max.PlatformSpec` — platform-id mapping
- `Max.PromptSpec` — `renderContext`: the flat transcript and the
  `history_as_turns` shape (including that neither can produce two consecutive
  same-role messages), section ordering, roster/名片 identity, 私聊 scene,
  memory block placement, quoted-forward expansion, in-flight hiding
- `Max.PromptFlowSpec` — generated `docs/prompt-flow.md` matches the live
  Prompt → Agent → LLM rendering path (regenerate with
  `cabal run max-prompt-flow`)
- `Max.RenderSpec` — markdown table → typst
- `Max.ReplySpec` — reply paragraph splitting (fences, `[split]`, chunk ceiling)
- `Max.ReplySendSpec` — that splitting a reply at a `readyPrefix` boundary sends
  the same messages as never splitting it, plus the per-reply chunk ceiling
- `Max.Sandbox.DockerSpec` — package wrapping and exec argv
- `Max.SessionSpec` — pure session mutators (`addPin`, `clearAll`, …)
- `Max.ShutdownSpec` — drain flag / in-flight counter transitions
- `Max.SkillsSpec` — builtin skills parsed from `skills/` (and the
  `{{commands}}` splice really happened)
- `Max.TasksSpec` — the task registry: feeding a running turn, aiming a
  `!feedback` by trigger, in-flight bookkeeping, `attachTask` adoption,
  unserved-note return at `endDispatch` (killed turns keep nothing)
- `Max.WreqSpec` — HTTP wrapper behaviour
- `OneBot.EventSpec` — group + private event parsing
- `OneBot.SegmentSpec` — segment codec, mention conversion, card parsing

### `max-test-db` (real Postgres)

```sh
createdb -h 127.0.0.1 -p 5433 max_test
export MAX_TEST_DB_URL=postgresql://127.0.0.1:5433/max_test
cabal test max-test-db
```

Without `MAX_TEST_DB_URL` the suite exits 0 (CI without a database stays green).
Every case runs after `TRUNCATE … RESTART IDENTITY CASCADE`.

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
`memx` (memory extraction), `intent` (proactive-trigger classification),
`shutdown` (graceful drain).

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
