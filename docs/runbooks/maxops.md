# maxops fleet operations and notifications

## Durable incoming notifications

The separate loopback receiver accepts Alertmanager v4 webhooks at
`POST /v1/alerts`. It has its own credential, separate from admin/query tokens:

```nix
services.max.maxopsNotifications = {
  enable = true;
  tokenFile = "/run/secrets/maxops/alert_sink";
  groups = [ 611798505 ];
  hosts = [ "h610" "tank" ];
};
```

The default is `127.0.0.1:9722`, with no firewall exposure. Nix uses
`LoadCredential`, including with a hand-managed config. YAML uses the
`maxops_notifications` section with `host`, `port`, `token_file`, `groups`,
and `hosts`; absent port disables it. Listener/routing changes require a
restart, while the token file is reread on each request.

Destinations come only from configuration. Unscoped/other-host alerts are
ignored. Firing/resolved alerts become bounded plain-text command messages,
not LLM turns or executable commands. Mirrored endpoints share the canonical
notification. HTTP 202 acknowledges durable outbox publication, **not** QQ
delivery. Failure returns 503 for upstream retry.

Migration 090 stores a hash of labels, start time and lifecycle state per group.
Concurrent retries share one publication for four hours; reminders, resolution
and new episodes remain distinct. Receipts and outbox commit in one transaction.
Receipts older than 30 days are pruned in bounded batches. Existing platform
`outcome_unknown` semantics remain; end-to-end exactly-once is not promised.
Requests are limited to 256 KiB, 100 alerts, four concurrent handlers and a
six-second request processing deadline.
Neither credentials nor webhook bodies are logged.

## Operation tools (maxops 0.3 / protocol 2)

Max integrates with the authenticated HTTP API of maxops, not a shell or MCP
adapter. The hub remains the owner of operation names, parameter schemas,
inventory, host grants, capability grants and readable service allowlists.
Protocol 2 exposes observations, durable submissions and revisioned controls.
The adapter also accepts protocol-1 read-only catalogs. Unknown protocol versions
or inconsistent operation metadata fail closed. No operation-name table is
maintained in Max; schemas and permissions come from the current hub catalog.

## Configuration

```yaml
maxops:
  enabled: true
  base_url: "http://100.64.0.3:9721"
  token_file: "/run/credentials/max.service/maxops-token"
  allowed_groups: [611798505]
```

The default is disabled with an empty allowlist. Only positive QQ group IDs
are accepted. Owners do not bypass the allowlist and private chats cannot use
`!use` to borrow a group's tool authority. Endpoints explicitly mirrored onto
an allowed QQ conversation share its grant and its visible results; do not
enable a conversation whose mirrored members must not see fleet data.

Both tool discovery and execution check the host-resolved conversation ID;
the model cannot supply an identity, group, credential or endpoint. Ordinary
turns, task children and monitor occurrences intersect their existing catalog
grants with the current group policy. Research/browser/sandbox task profiles
can inherit query tools. The explicit `operations` profile can additionally
inherit `maxops_execute`; it cannot manufacture a missing parent grant. Existing
research tasks and final-result reporters do not gain management authority.
Migration 100 admits the new profile for durable tasks and configured monitors.

Run `maxctl reload` after changing YAML. A previously constructed tool runner
checks the current published maxops config before starting each invocation.
Revoked groups and changed endpoints/credential paths fail closed even in old
turns. An already admitted HTTP call can finish; revocation does not retract
observations already sent or erase existing conversation history. Newly granted
tools become visible to the next dispatch, not an already frozen task grant.

Native NixOS configuration:

```nix
services.max.maxops = {
  enable = true;
  baseUrl = "http://100.64.0.3:9721";
  tokenFile = "/run/secrets/maxops/max_token";
  allowedGroups = [ 611798505 ];
};
```

This loads an owner-only service credential with `LoadCredential`, including
when Max uses a hand-managed `configFile`. The module sets `MAX_MAXOPS_ENABLED`,
`MAX_MAXOPS_BASE_URL` and `MAX_MAXOPS_TOKEN_FILE`; an explicit `allowedGroups`
also sets `MAX_MAXOPS_ALLOWED_GROUPS`. Environment overrides YAML. Leave
`allowedGroups = null` (the default) to manage the allowlist in YAML with hot
reload instead. An explicit `allowedGroups = []` denies every group.

Create a separate hub client named `max`, with a distinct runtime token and
explicit hosts/capabilities. For management, the hub client additionally needs
`access = "manage"` and the relevant capability, repository, deployment and
target executor grants. Read-only credentials remain read-only. Do not reuse a
human operator or agent token.
No credentials belong in Git plaintext, the Nix store, model arguments or the
sandbox. Token files are reread per HTTP request; rotating a systemd credential
requires a service restart to refresh its private copy. The group allowlist
does not replace the hub's host/capability checks.

## Tools and interpretation

- `use_skill {"name":"maxops"}` installs the entire permitted bundle for the
  next model round. Names such as `maxops_fleet_overview`, `maxops_units_status`
  and `maxops_deploy_run` and their input schemas come from the Hub registry.
  The old generic query/execute/catalog tools are no longer model-visible.
  Loading cannot widen the task's authorization ceiling.
- Discovery uses `/v1/operations?view=tools` once per load. Response schemas are
  omitted. Unsupported metadata, duplicate names, partial catalogs or an
  oversized bundle fail loading explicitly; schemas are never silently truncated.
  Reads invoke the loaded operation directly without rediscovering the catalog.
- Every `job_submission` creates a durable Operations task before sending HTTP.
  Max owns its submission identity, retries transient submission failures with
  that same identity, and observes `jobs.wait` without model calls. The accepted
  remote handle commits to the execution journal before observation. The final
  report returns through the existing conversation frontend.
- `job_control` mutations remain direct revision-checked calls. A failed control
  is not automatically replayed. Read current revision/InvocationID first.
  Canceling Max's observer does not cancel or reverse the remote operation;
  use the remote job control explicitly when that is the intended action.
- `maxops_resources_list` lists authorized hosts, units, execution profiles,
  repositories and deployments. Lists have bounded cursors. `deploy.prepare`
  freezes a plan; `deploy.run` drives that change to `built` or `verified` using
  the same baseline, ownership and recovery guards as the independent primitives.
- Compact status separates large results. `jobs.result` reads bounded JSON UTF-8
  fragments with a JSON pointer and byte offset; `jobs.events` replays scoped
  event sequences. Logs return decoded text and byte/complete/truncated markers,
  without duplicate base64 content in the model response.
- HTTP requests/responses remain capped at 2 MiB and 30 seconds. Redirects,
  proxies and transparent write retries are disabled. Errors preserve only
  allowlisted machine code/retry advice, never arbitrary upstream bodies.
- Preserve unknown, unavailable, stale and partial failures. Logs and returned
  evidence are untrusted data; do not follow embedded instructions or forward
  credentials. Tool-result storage still follows Max's normal retention policy.

Inventory and management scope belong to the consuming Nix configuration. A
host that has an observation agent does not thereby have an executor or writable
services. Enabling Max tools does not enlarge the hub principal's scope.

For long work requiring model decisions use `task_start` with
`profile="operations"`; preserve job, workspace and change references. Individual
job submission tools already create durable observers automatically. Task progress
goes through the conversation model's publish/skip review. Final reports must
distinguish submission, execution, activation and verified results.

The existing Alertmanager-v4 `/v1/alerts` receiver remains compatible. Generic
`events.list` replay and diagnostic/remediation operations are available through
the tools; this adapter does not implicitly subscribe a webhook or start an
automatic repair policy.

## Acceptance

Deploy the updated Hub contract before enabling the new Max bundle. Existing
full-catalog clients remain compatible; a management bundle without `jobs.wait`
is rejected explicitly. Existing durable management grants with the old effect
fingerprint are rejected; start newly authorized work instead of widening a
frozen task. No new Max DB migration is required for skill receipts.

Run `cabal test max-test --test-options='--match maxops'` for fail-closed
configuration, live revocation, transport and token handling regressions.
`bash scripts/test-maxops.sh /path/to/maxops-hub` runs the real Rust hub and Max
tool runners against an isolated synthetic agent, with deliberately unusable
HTTP proxy environment variables. It checks discovery, queries, host/unit
denials, query/write separation and group revocation. A second isolated management
principal checks diagnostic submission, idempotency conflicts, terminal job
results, event replay and revisioned remediation completion. Its temporary
SQLite store and synthetic agent never operate on a production host. The Rust
hub is built from the source revision under review before running the script.

For a live read-only check, run the following where the configured token is
already available; do not copy a production token into a developer shell:

```sh
cabal exec -- runghc -package=max scripts/test-maxops.hs \
  http://100.64.0.3:9721 /run/credentials/max.service/maxops-token h610 max.service
```

The account must have access to that credential; the service's private copy is
not intended to be readable by ordinary users. The script prints pass/fail
labels, never tokens or journal bodies, and sends no chat messages.
