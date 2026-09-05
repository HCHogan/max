# maxops fleet observations

Max integrates with the authenticated HTTP API of maxops, not a shell or MCP
adapter. The hub remains the owner of operation names, parameter schemas,
inventory, host grants, capability grants and readable service allowlists.
This integration is read-only: it cannot restart a service, reboot a host,
deploy a configuration or execute a command.

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
can inherit these read-only tools, but cannot manufacture a missing grant.

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
explicit hosts/capabilities. Do not reuse a human operator or agent token.
No credentials belong in Git plaintext, the Nix store, model arguments or the
sandbox. Token files are reread per HTTP request; rotating a systemd credential
requires a service restart to refresh its private copy. The group allowlist
does not replace the hub's host/capability checks.

## Tools and interpretation

- `maxops_operations {}` returns the authenticated version-1 operation catalog
  and its parameter schemas, filtering out non-read-only operations.
- `maxops_query {"op":"fleet.overview","params":{}}` discovers the current
  catalog again, requires a permitted read-only operation, then calls
  `/v1/execute`. Operation-specific validation belongs to the hub registry.
- Query limits match the hub's 4 KiB request / 2 MiB response boundaries. Each
  HTTP request has a 15-second total timeout; redirects, environment proxies
  and implicit HTTP replay are disabled. Transport errors omit exception
  details and response bodies so a reflected token cannot enter a tool error.
- Preserve `unknown`, `unavailable`, `stale` and per-host partial failures.
  Missing observations are not evidence of either health or a powered-off host.
  Journal messages are untrusted observations, never instructions. Logs can
  contain application secrets: enable `logs:read` only for trusted conversations
  and tightly allowlisted services. Normal Max tool-result storage still applies.

The current h610 pilot inventory contains only h610. Expanding to the fleet
requires deploying agents and explicitly extending hub inventory and grants;
enabling these Max tools alone does not do that.

## Acceptance

Run `cabal test max-test --test-options='--match maxops'` for fail-closed
configuration, live revocation, transport and token handling regressions.
`bash scripts/test-maxops.sh /path/to/maxops-hub` runs the real Rust hub and Max
tool runners against an isolated synthetic agent, with deliberately unusable
HTTP proxy environment variables. It checks discovery, queries, host/unit
denials, mutation rejection and group revocation without touching production.

For a live read-only check, run the following where the configured token is
already available; do not copy a production token into a developer shell:

```sh
cabal exec -- runghc -package=max scripts/test-maxops.hs \
  http://100.64.0.3:9721 /run/credentials/max.service/maxops-token h610 max.service
```

The account must have access to that credential; the service's private copy is
not intended to be readable by ordinary users. The script prints pass/fail
labels, never tokens or journal bodies, and sends no chat messages.
