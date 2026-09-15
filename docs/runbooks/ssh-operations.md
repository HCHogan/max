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
not members of the initiating host's `max-stack.target`.

## Service-account cutover

The daemon now uses Linux account/group `max-service`. The database/role remain
`max`, with an explicit PostgreSQL peer map and `user=max` connection URL. This
avoids database renames and preserves ownership of existing tables.

Before the first activation on an existing installation:

1. Build the new system and retain its store path plus the current generation.
2. Stop `max-stack.target` and confirm the service UID has no remaining processes.
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
