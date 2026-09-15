# SSH fleet operations

`services.max.operations` adds a dedicated Tailscale client and shared network
namespace to the native Max runtime. Enabled conversations use ordinary sandbox
shell commands, including `ssh hostname`; load the `operations` skill for the
workflow. All members of an enabled QQ conversation may operate. Background
`operations` tasks inherit the parent's sandbox grants. The legacy Hub API tools,
job adapters and notification receiver have been removed.

## Configuration

```nix
services.max.operations = {
  enable = true;
  allowedGroups = [ 611798505 ];
  loginServer = "https://tailscale.example.com";
  authKeyFile = config.sops.secrets.max-ops-preauthkey.path;
  domain = "inner.example.com";
};
```

Create a Headscale user and preauthkey, store the key with sops-nix, and authorize
that user in the tailnet's network and Tailscale SSH policy. The production fleet
uses `max@imdomestic.com` in `group:imdomestic`, and local `max` accounts with
unrestricted passwordless sudo. The node is named `maxops`, accepts subnet routes,
and does not run an inbound Tailscale SSH server. No SSH private key is required.

The shared guest SSH configuration selects `max`, expands short names using the
configured domain, and uses `BatchMode`. SSH host keys use first-use acceptance
and persist in `/work/.ssh/known_hosts`; subsequent key changes are rejected.
The guest does not receive a tailscaled socket or node state. Network configuration
is selected by the broker from the conversation's canonical sandbox owner, not by
tool arguments. Changes take effect on broker restart; stale containers are rebuilt
around their existing `/work` when used or reconciled. Ordinary conversations
retain public-only networking.

Skill visibility is not network authorization. The broker selects `maxops` for
all sandboxes owned by an enabled conversation, even before `operations` is
loaded. Operations and sandbox task profiles inherit the same shell subset;
neither is a read-only SSH boundary. Shared namespaces also share localhost and
ports, so local services should bind dynamic ports. Work directories stay separate.

## Native lifecycle

`max-ops-network.service` owns `/run/netns/maxops`, a veth uplink on
`10.232.0.0/30`, and the associated forwarding/NAT policy. Each operations sandbox
has a bind-mounted reference under its existing `/run/netns/max-sb-…` name.
Destroying a sandbox releases only its reference. Adoption checks both policy
metadata and the running container's network namespace identity.

`max-ops-tailscaled.service` joins the shared network with
`NetworkNamespacePath`. Its state is `/var/lib/max/tailscale`, its socket is under
`/run/max-ops-tailscale`, and the preauthkey is delivered with `LoadCredential`.
The daemon gets a private resolver file for bootstrap; sandbox DNS uses
`100.100.100.100`. It does not change the host resolver. The namespace's uplink
provides public access and the daemon installs tailnet/subnet routes. The uplink
rejects bare tailnet destinations and forwarding through the host's Tailscale
interface, so a stopped dedicated client cannot borrow the host node's identity.

Both services are wanted by and part of `max-stack.target`, with resources in
`max.slice`. The sandbox template is ordered after the dedicated network/client,
so stack shutdown stops consumers before releasing the shared namespace. Network
shutdown also releases remaining sandbox references to that namespace. After
stopping the target, wait for the network service to become inactive before
assuming namespace cleanup has finished. Restarting
`max.service` leaves these services running. Restarting the Tailscale service
preserves the namespace and node state. Tailnet failure does not prevent ordinary
Max startup; operations report runtime/network errors.

Stopping local SSH does not guarantee remote work stopped. Use a named remote
systemd job for a long build or activation and retain its host, unit, logs and
result. Reconnect to inspect uncertain work before retrying it. Remote jobs are
not members of the initiating host's `max-stack.target`. Independent SSH commands
can execute concurrently in one sandbox, even across tasks. Coordinate shared
paths and deployments of the same host; no task owns the whole sandbox.

## Service-account cutover

The daemon now uses Linux account/group `max-service`. The database/role remain
`max`, with an explicit PostgreSQL peer map and `user=max` connection URL. This
avoids database renames and preserves ownership of existing tables.

Before the first activation on an existing installation:

1. Build the new system and retain its store path plus the current generation.
2. Run `systemctl stop max-stack.target max.service max-runtime.service max-runtime.socket`
   and confirm the service UID has no remaining processes. Stopping only the target
   can return while its members are still draining.
3. Run `<new-system>/sw/bin/max-migrate-service-account --check`, then `--migrate`.
4. Activate the new system. The fleet `max` login account is created separately.
5. Verify Max, broker access, database authentication, file ownership, and SSH/sudo.

The helper preserves the old UID/GID and moves the NixOS allocation-map entries.
It records account/map backups under `/var/lib/max/backups/service-account`.
The pre-switch check refuses to activate while the old service account still
occupies `max`. This helper changes no database data. If activation fails after
renaming the account, keep Max stopped and repair/complete the new activation;
starting the old generation requires restoring its old account identity first.

## Validation

Run the unit and real disposable PostgreSQL suites, and the NixOS checks
`sandbox-network`, `operations`, and `state-migration`. The operations check
uses real Headscale and two independent Tailscale clients, SSH/sudo, multiple
conversations, policy revocation, retained work and stack restart. Test database
or VM success is separate from deployment and live service acceptance.

## Retired integration

The legacy API client, dynamic tools, host job observers, notification receiver,
API skills and their dedicated tests have been removed. Migration 090 remains
as applied schema history so existing databases pass the downgrade guard;
migration 112 drops its obsolete notification table. Historical task and journal
records are retained. Before upgrading, finish or cancel any queued/running old
API observer tasks with the previous release and inspect uncertain remote jobs.
No old job is converted into a new SSH command.

## Existing tasks, monitors and workspaces

A binary upgrade changes embedded skills and source, but it does not rewrite
monitor objectives, task inputs, previous tool results or `/work` repositories.
DB-global or group skills can shadow builtins; successful skill loads are pinned
within an execution and recovery can retain their instructions. Inspect the
effective skill and task revision when behavior still follows an old workflow.

Use `self-knowledge` and `inspect_source` for the running build's implementation.
For an editable checkout, inspect its remote, HEAD and local changes, fetch the
current remote revision, and use a separate worktree. Do not reset a retained
workspace just to make its version match. Historical ADRs and receipts explain
old behavior; they do not restore retired tools or credentials.

If a recurring goal explicitly requests the old API, review its monitor revision
and already admitted tasks separately. Correct future objectives through monitor
controls and steer/replace/cancel existing work only within the user's intent.
Neither redeploying nor editing the monitor changes a frozen in-flight objective.
Inspect uncertain old remote work before retrying its intended operation via SSH.

## Diagnosing access and deployment

- Use an actual fleet target, such as `ssh h610`, then `id -un` and
  `sudo -n id -u`. `ssh maxops` targets the dedicated client, whose inbound SSH
  is disabled. Do not scan it for a retired Hub endpoint.
- If login as `max` is denied, check the target account, its effective sudo rule,
  Tailscale SSH settings and Headscale policy. Enabling the h610 client alone
  does not install operator accounts on other machines.
- For DNS/connectivity failures, inspect the dedicated service and namespace.
  A host `/etc/hosts` loopback alias points inside the namespace when inherited;
  h610 supplies the Headscale veth-gateway mapping through a service-specific
  systemd bind mount. Preserve the host client's identity and resolver.
- Before activation, record the running system, system profile and failed units.
  Fetch source on the chosen builder, obey repository/user builder assignments,
  and keep a durable remote job for long work. Avoid routing large closures
  through a distant workstation when builders and targets can transfer directly.
- After activation, compare both `/run/current-system` and the resolved
  `/nix/var/nix/profiles/system` with the built closure. Inspect the switch result,
  failed units and business behavior independently. A nonzero switch may leave
  the new system active; investigate before another switch or rollback. Starting
  targets during activation can retry an unrelated previously failed oneshot.

The 2026-09-15 fleet deployment used Max `cfcbba9` and nix-config `3071dc2`.
All ten registered NixOS targets passed sandbox SSH, full sudo, expected system
and host Tailscale identity checks. h310's switch returned 4 after its preexisting
Gaoji installer retried and timed out; its new running/profile paths and SSH
acceptance passed. Functional acceptance does not erase that failure or Max's
historical delivery debt. Fleet inventory, builder assignments and the complete
deployment record live in nix-config's `docs/max-ssh-operations.md`.
