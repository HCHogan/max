# Command sandbox networking

The native broker selects networking from the sandbox's canonical conversation.
Tool arguments cannot select a network, and loading a skill does not change it.
Both modes use the same prebuilt NixOS guest with systemd-nspawn, a non-root
command user, dropped capabilities, resource limits, a read-only root and a
persistent `/work` volume. Max does not require Docker.

| Mode | Selection | Connectivity |
| --- | --- | --- |
| `max-sandbox` | Ordinary conversations | Public IPv4 DNS/HTTP/HTTPS/Git; no host, private, link-local, Tailscale or peer access |
| `maxops` | `services.max.operations.allowedGroups` when operations is enabled | Dedicated Tailscale identity, fleet and approved subnet routes, plus public egress |

## Ordinary conversations

`nix/sandbox-network.nix` provisions the `max-sb-native` bridge on
`10.231.0.0/16`. Isolated bridge ports and the independent `inet max-sandbox`
nftables table reject host/private/CGNAT/link-local and peer destinations,
including hostnames resolving to those addresses. IPv6 is disabled. NixOS owns
forwarding/NAT for this bridge. Where unrelated Docker services exist, narrow
forwarding compatibility rules coexist with the earlier nftables filter.

The module enables `services.max.sandboxNetwork.enable` by default. Disabling
it requires an equivalent externally managed network; the runtime does not
fall back to an unrestricted bridge. The network service prepares the shared
`/run/netns` mount before the broker and nspawn instances use it.

## Operations conversations

The `operations` skill loads sandbox tools after checking the broker's group
policy. Sandboxes in enabled groups share `/run/netns/maxops`, using the
separate `max-ops-tailscaled.service` identity. Ordinary `ssh hostname` selects
`max` on the fleet target. `maxops` is the client/node name, not an SSH server.
The guest receives neither the daemon socket nor the preauthkey or node state.

All operations sandboxes share localhost and ports. Use dynamic ports for
local services; filesystem/work-volume separation does not imply network
separation in this mode. A task's profile cannot make shell access read-only
or change its conversation's network. Lifecycle, routing, DNS and revocation
are specified in [SSH operations](ssh-operations.md).

## Adoption and durable work

The broker compares policy metadata and the actual running namespace identity.
Outdated or stopped instances are rebuilt around their retained `/work`; deleting
one operations sandbox releases only its reference to the shared namespace.
Migration 113 permits `maxops` in the database network-mode constraint, while
historical modes remain readable. Upgrading the runtime does not fetch Git or
rewrite files inside retained workspaces.

Requested packages are built and rooted by the host broker from pinned nixpkgs;
commands run in the guest with the resulting paths on PATH. The shared host
store is read-only and has no guest-accessible Nix daemon socket or database.
Network access does not authorize unrelated external writes. An SSH timeout or
sandbox cancellation does not establish the outcome of a remote effect; inspect
retained host/unit/job evidence before retrying. Browser services and host web
tools have their own network policies.

## Validation

```sh
nix build .#checks.x86_64-linux.sandbox-network
nix build .#checks.x86_64-linux.operations
```

The first check covers native runtime isolation and public/private networking.
The second uses real Headscale/Tailscale for SSH/sudo, group policy changes,
shared namespaces, retained work and stack restart. Deployment acceptance also
checks real DNS/HTTPS/Git, the selected network mode, existing work contents,
remote system/profile paths and business function. VM success alone does not
establish production health.
