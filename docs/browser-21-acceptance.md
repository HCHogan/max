# Browser surface (issue #21)

The browser runner is `browser`; `view_zhihu` and `view_bilibili` remain site readers.
The web skill, catalog and Browser task grants use the same names. Old task and
published workflow grants are not silently widened to the new tool fingerprint.

## Policy decisions

- Native session start fixes `exclude_addons: ["UBO"]`, `enable_cache: true`, and
  a 1280×800 viewport. Fingerprint rotation, stealth and workspace storage isolation
  remain in place. Cache configuration alone is not evidence of a cache hit rate;
  Playwright request routing still mediates traffic.
- The service enables `CAMOUFOX_MCP_ALLOW_UNSAFE_OPTIONS=1`. The model cannot call
  session start or supply launch arguments or Firefox preferences. This is a
  deliberate host-owned option, required by upstream to exclude UBO.
- `CAMOUFOX_MCP_ALLOW_EVALUATE=1` is additionally fenced by an active task workspace
  lease in the fork and by task scope in Haskell. A foreground call cannot enable
  it by supplying an expression or a forged lease field.
- Failed DNS aborts that request and records a bounded host-only note. Private,
  reserved and unsupported targets abort and fail the operation. Notes drain into
  results; request counts and fatal errors reset at the next operation. HTTP and
  WebSocket requests use the same address policy.
- Transport loss clears the page, handshakes once, and rebinds task authority. It
  does not replay the operation. Cold task recovery reuses that new connection.
  The caller must open again and check uncertain external effects before acting.
- Dialogs are recorded and dismissed automatically. `dialog` can choose the next
  answer only. Images are viewport JPEGs at CSS pixel scale, capped at 2 MB. The
  per-turn media queue admits at most one browser image, within the shared quota.
  Automatic image candidates are URL changes and short/empty content.

## Measurement before extending the session tools

Steps 1–4 were built as a native Linux package and exercised against a controlled
HTTP fixture using real Camoufox, before adding read/find/screenshot/dialog/collect.
On the identical 800-paragraph page:

| Result | Raw MCP text characters | Haskell projection characters | Declared budget |
| --- | ---: | ---: | ---: |
| Snapshot, former inherited limits (30000/100) | 76571 | 29998 | 30000 |
| Snapshot, explicit limits (6000/40) | 18384 | 5998 | 6000 |
| Click, explicit limits (1500/20) | 6423 | 1498 | 1500 |
| Navigation with incomplete readiness | 505 | 389 | 6000 |

These are controlled payload measurements, not a new production traffic sample or
evidence of improved task success with the deployed 27B model. Subsequent projection
cleanup uses the last two available characters too; the total budget remains hard.

## Reproducible checks

```sh
cabal build all
cabal test max-test
MAX_TEST_DB_URL=postgresql://127.0.0.1:55421/max_test cabal test max-test-db
cabal check
cabal run max-prompt-flow
cabal run max-prompt-flow -- --check
nix build 'path:.#max-browser' --no-link --print-out-paths  # Linux
bash scripts/test-browser-surface.sh /nix/store/...-max-browser /tmp/browser-measure.json
cabal exec -- runghc -package=max scripts/test-browser-view.hs /tmp/browser-measure.json
bash scripts/test-browser-workspaces.sh /nix/store/...-max-browser
```

The surface fixture covers unresolved third-party DNS and next-call usability,
private request rejection and recovery, partial navigation, iframe targeting,
the action surface, extraction, dialog answers, viewport image dimensions, and
collection from dynamically appended content. The Haskell transport test drops
the response to a click, checks that the session clears, checks the next handshake
has no dead ID, and checks that no click is replayed. The PostgreSQL browser test
also checks that task recovery creates no second handshake and that old owners
remain fenced. Browser result tests bound noisy Unicode content and metadata;
media tests preserve the screenshot quota across drains and adapters.

## Verified on 2026-09-12

- `cabal build all`, `cabal check`, and prompt-flow generation/check passed.
- 1,114 unit tests and 411 tests against a disposable PostgreSQL database passed.
  The browser DB regression also covers transport loss during checkpointing.
- Architecture boundary checks passed. The actual native model-message adapter
  preserves the text projection without JSON quoting; error framing and the
  uncertainty suffix fit within the same declared budget.
- Nix built the Darwin Max package and the native Linux browser package. The
  final Linux surface fixture passed, including rejecting a forged foreground
  evaluate lease. All 25 captured text results passed model-message budget checks.
- The existing nine real-browser workspace scenarios passed, including storage
  isolation, lease fencing, cold restore, termination during launch, absence of
  authentication state in logs, and child-process cleanup.

All browser runs used isolated fixture state on a test process. Production service
activation and a new production model/traffic measurement are separate from these
implementation and acceptance results.
