# ADR 011 — Native systemd runtime for Max

Status: Accepted; implemented and validated in NixOS VMs and on h610.

Max's durable runtime ownership belongs in its database and Haskell registries.
Docker supplied process/container lifecycle, package storage and resource limits,
but required the application user to hold general host-root authority through
its socket. Its separate Nix store duplicated the host's cache, and browser
bridge networking depended on host proxy interception rules.

The runtime is now declared through the existing NixOS configuration and grouped
under one `max-stack.target`: `max.service`, `max-napcat.service`,
`max-browser@.service`, `max-sandbox@.service`, and a socket-activated Haskell
broker. Client and broker share typed requests and protocol framing in the Max
Cabal project. They remain separate processes because the main application does
not need host-root privileges.

NixOS builds a minimal guest system once. The broker dynamically instantiates
nspawn units with fixed network, mount, uid and resource policy. Sandboxes appear
in `machinectl`, while browsers remain ordinary native services. The host Nix
store is shared read-only; package preparation and per-sandbox GC roots remain
host-owned. Work directories survive instance replacement and application
restarts. Browser workspace ownership, leases and recovery follow ADR 009.

Persistent state is grouped under `/var/lib/max`, with separate ownership for
`app`, `runtime`, `napcat` and dynamic browser instances. The main service and
peer PostgreSQL role/database use `max`. h610 declares configuration as Nix
attributes and renders JSON through SOPS; manual YAML and environment files
are retired. Sockets and credentials remain ephemeral under `/run`.

The broker exposes no arbitrary host command, unit property or file-path API.
File transfers use pipes; the unprivileged client opens and reads/writes host files.
The broker rejects socket, device and regular-file descriptors. Guest command
units run as uid 1000 with bounded lifetime; disconnect cancels the corresponding
unit. Per-instance locks permit unrelated conversations to proceed concurrently.

NapCat uses the pinned napcat.nix integration with the pinned host QQ package,
bubblewrap isolation and retained account directories. A dedicated group allows
read-only access to short-lived upload files without granting access to Max's
other state.

This replaces the Docker runtime and image builders, not the durable ownership
model. Database identifiers remain stable. Migration copies and verifies work
before publishing native directories and retains legacy volumes for rollback.
An existing unmigrated volume is an error, never proof of absence. Network,
process, storage, cancellation and browser acceptance are covered by the native
NixOS VM check; deployment acceptance remains a separate step.

See [the runtime runbook](../runbooks/native-runtime.md) for declarations,
lifecycle commands, migration and rollback.
