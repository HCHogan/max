# Command sandbox networking

Command sandboxes use the fixed Docker network `max-sandbox`, provisioned by
`nix/sandbox-network.nix` before Max starts. Its bridge is `max-sb-egress`.
Commands can use public DNS/HTTP/HTTPS/Git and package registries. Host access,
private/link-local/CGNAT destinations, unsolicited inbound traffic and peer
sandboxes are blocked. IPv6 is disabled. The existing non-root user, dropped
capabilities, resource limits, read-only root and private work volumes remain.

The filtering lives in an independent `inet max-sandbox` nftables table, with
input and forward hooks preceding Docker's filter rules but following destination
NAT. Filtering the resolved destination also blocks a hostname that resolves to
an internal address. Docker owns its own rules and NAT. NixOS reloads the table
atomically. See [Docker's firewall guidance](https://docs.docker.com/engine/network/firewall-nftables/).

The NixOS module provisions this by default. Disabling
`services.max.sandboxNetwork.enable` is only for an externally managed equivalent
network; Max will not fall back to the default bridge if the network is absent.
The provisioning unit refuses to adopt a same-named network with different
driver, IPv6, bridge, peer-isolation or ownership settings.

Migration 098 permits the new network name while retaining historical modes in
the database. Container policy version 5 causes old shells to be recreated around
their original `/work` volumes. The registry also checks the actual network and
rejects a container attached to additional networks. Package preparation remains
a separate fixed-command Nix helper; agent commands never execute there.

Public egress is intentional authority for network-capable tasks. It does not
grant permission to publish arbitrary external writes, and the command journal
does not record every HTTP transaction. Ambiguous commands remain unsafe to
replay. Browser containers and host web tools have separate network policies.

Validation:

```sh
nix build .#checks.x86_64-linux.sandbox-network
```

The VM test uses reachable public/private fixture endpoints in a separate
network namespace. It checks public access, private/CGNAT/link-local denial,
DNS rebinding, host/peer/DNAT denial, and repeated provisioning/firewall reload.
Deployment acceptance additionally checks real DNS/HTTPS/Git, migrated network
metadata, and unchanged contents of existing work volumes.
