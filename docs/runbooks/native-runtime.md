# Native Max runtime

Max's NixOS module provisions `max-stack.target`. `max.service` runs as
`max-bot`, and `max-runtime.socket` activates the separate root
`max-runtime.service` broker. Both broker and client are Haskell modules in
this repository, built as `max-runtime`. The fixed, versioned Unix protocol
accepts Max instance identifiers and operations; it cannot select host commands,
unit properties, mounts, arbitrary Nix expressions or privileged host file paths.
The client opens copied files with its own permissions and streams through pipes;
the broker rejects other descriptor types, including Unix sockets.

`max-sandbox@<conversation>-s<number>.service` launches the prebuilt NixOS system
from `nix/sandbox-guest.nix` with systemd-nspawn. A corresponding
`max-sandbox-<conversation>-s<number>` appears in `machinectl`. User namespaces
map the guest away from host root; commands run as sandbox uid 1000 in bounded
transient guest units. Disconnecting a client stops its guest command unit.

`max-browser@<conversation>.service` is an ordinary service with a dynamic user,
resource limits, a private temporary directory and per-instance state. Its Nix
package supplies Camoufox, MCP, fonts, extensions, GeoIP data, Xvfb and the HTTP
gateway. The gateway binds a kernel-assigned loopback port and publishes it only
after listening. Browser services do not appear in `machinectl`. The existing
conversation host / task workspace / lease / fencing / cold-recovery contract
remains in the Haskell registry and MCP patches.
The gateway catches asynchronous sends to disconnected requests, so a late child
response cannot crash sibling MCP sessions. A delayed-response fixture verifies
this behavior during package builds, independently of browser launch timing.

`max-napcat.service` uses the pinned community napcat.nix QQ integration and a
bubblewrap launcher. Its QQ version follows the fleet's pinned nixpkgs. It keeps
account data in `/var/lib/max-bot/napcat/{QQ,config}` and exposes only the outbox
through a read-only bind. Short-lived upload files are group-readable by the
separate `max-outbox` group. The default OneBot listener is `127.0.0.1:18080`;
NapCat's web UI binds `127.0.0.1:6099`.

## Lifecycle and storage

All services have `PartOf=max-stack.target`; restarting `max.service` does not
restart sibling services. Stopping the target stops existing instances. Dynamic
instances are recreated when requested; starting a target does not enumerate
and instantiate every template.
The target's stop job can finish before guest shutdown completes; maintenance
must also wait for the instance units to become inactive.

The host module builds one guest closure, independent of the number of live
instances. It supplies the launcher and templates; creating a sandbox requires
neither Nix evaluation nor a host rebuild. A template/package or broker policy
change is detected during reconciliation using metadata and the actual systemd
invocation. Unchanged instances can be adopted, while outdated ones are rebuilt
around their existing work directory.
Fingerprints are separate for each backend, so browser-only template changes
leave command sandboxes eligible for adoption.

Extend the guest with ordinary NixOS modules, including existing local modules:

```nix
services.max.sandbox.extraModules = [
  ./sandbox-tools.nix
  ({ pkgs, ... }: { environment.systemPackages = [ pkgs.sqlite pkgs.nodejs ]; })
];
```

Durable work is `/var/lib/max-runtime/volumes/<legacy-name>-data/work`.
Expendable guest roots are under `/var/lib/max-runtime/roots`, and root-owned
instance metadata is under `instances`. Stopping an instance preserves work and
package roots. Explicit destruction removes both. The database retains its
existing container/volume columns and stable identifiers; the image column now
records `nixos-sandbox-v1`.

The guest mounts host `/nix/store` read-only, without the host Nix daemon socket
or database. Requested packages are built by the host from its fixed nixpkgs
source, rooted under `/nix/var/nix/gcroots/max-sandboxes/<instance>/`, and placed
on PATH for the requested command. Python package attributes are combined into
one `python3.withPackages` environment. Native manifests observe `/work`; the
legacy Docker layer-diff fields are empty because no Docker filesystem layer
exists.

The native bridge `max-sb-native` uses `10.231.0.0/16`. Isolated bridge ports and
nftables allow public IPv4 egress while blocking host, private, link-local,
Tailscale and sibling addresses. Where unrelated Docker services remain, narrow
DOCKER-USER forwarding rules coexist with this earlier filter. Max does not
enable Docker or grant its user membership in the Docker group.

## Validation

```sh
cabal build all
cabal test max-test
MAX_TEST_DB_URL=postgresql:///max_test cabal test max-test-db
cabal check
cabal run max-prompt-flow
cabal run max-prompt-flow -- --check
nix build .#packages.x86_64-linux.max-browser
scripts/test-browser-workspaces.sh "$(readlink -f result)"
nix build .#checks.x86_64-linux.sandbox-network
nix build .#checks.x86_64-linux.nixos-reload
```

The native-runtime VM check exercises actual nspawn registration, caller uid,
store and namespace protection, client-disconnect cancellation, package roots,
public/private networking, durable work, legacy-volume refusal, target lifecycle,
and real browser workspace acceptance. It permits software emulation when KVM
is unavailable. Fresh-DB tests and VM checks do not establish production health.

Also exercise real public navigation on the destination host. During h610
validation, domestic DNS returned a reserved Google IPv6 address and incorrect
DuckDuckGo IPv4 addresses. The browser correctly rejected the former. Proxied
TCP DNS restored both sites without weakening address validation. h610's
`my.dae.foreignDnsOverTcp` setting selects that route while retaining domestic
DNS for domestic domains. After applying a DNS change, flush both resolved and
NSS caches (`resolvectl flush-caches`, `nscd -i hosts`) before retesting.

## Migrating an existing Docker deployment

This is an offline maintenance operation. Build and validate the new system
first. Retain its store path and the current `/run/current-system`, and verify a
custom-format PostgreSQL backup with `pg_restore --list`. Keep the old Docker
images, work volumes and `max-nix` until the native system has been accepted.

Inspect the proposed copy with the new `max-runtime` on PATH:

```sh
scripts/migrate-native-runtime.sh --check
```

During the authorized maintenance window:

1. Stop `max.service` gracefully and stop `docker-napcat.service`. Stop only
   Docker containers whose names belong to Max (`max-sb-*` and `max-br-*`).
2. Runtime-mask `max.service`, `max-runtime.service`, `max-runtime.socket` and
   `max-napcat.service` while activating the validated system. This creates the
   declarative native service users while preventing an early account login or
   database reconciliation against work that has not yet been copied.
3. Run `scripts/migrate-native-runtime.sh --copy` with root permissions and the
   new `max-runtime` on PATH. It copies `.max-work` (or older root-level work),
   verifies content and inventory, then atomically publishes each native volume.
   It backs up NapCat state before changing ownership. Existing completed copies
   are preserved; a partial staging directory is retained for inspection.
4. Unmask the four native units and restart `max-stack.target`. Verify Max's
   database reconciliation, existing work contents, browser navigation/workspace
   recovery, NapCat login and the OneBot connection. Do not send test QQ messages
   without authorization.

An unmigrated Docker work volume returns runtime-unavailable rather than missing,
so a skipped migration cannot falsely destroy its database row. Old work and
`max-nix` are never deleted by the copy script. Cached dependencies are rebuilt
from the host pin; existing scripts or virtualenvs containing absolute paths into
the old Docker store may require rebuilding those environments.

For rollback, stop and mask the native stack before activating the saved old
system, then unmask and start its original services. The old Docker volumes and
QQ backup are retained. If native work has changed since cutover, preserve and
reconcile those changes before returning to the older copies; rollback does not
silently overwrite either version of the work.
