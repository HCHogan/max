# Native Max runtime

Max's NixOS module provisions `max-stack.target`. `max.service` runs as
`max`, and `max-runtime.socket` activates the separate root
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
account data in `/var/lib/max/napcat/{QQ,config}` and exposes only the outbox
through a read-only bind. Short-lived upload files are group-readable by the
separate `max-outbox` group. The default OneBot listener is `127.0.0.1:18080`;
NapCat's web UI binds `127.0.0.1:6099`.

## Configuration and directory ownership

h610 declares all application settings in `nixos/hosts/h610/max.nix` in the
fleet's nix-config repository. SOPS substitutes encrypted secret values into
`/run/secrets/rendered/max-config.json`; `/etc/max/config.json` is the stable
application entry point. No manually maintained `max.yaml` or environment file
is loaded. Generic module users may still supply `settings` or `configFile`.

Persistent Max state is under root-owned `/var/lib/max`:

- `app`: main service home, images, files, outbox and browser checkpoint key;
  owned by `max`, mode 0700.
- `runtime`: root-owned sandbox work, disposable guest roots and broker metadata.
- `napcat`: QQ account/configuration, owned by `max-napcat`.
- `browser/<id>` and `browser-cache/<id>`: per-instance DynamicUser directories.
  `max-storage.service` binds `private` onto `/var/lib/private/max`, preserving
  systemd's private-state protection while keeping the physical data in this tree.
- `backups`: root-only migration backups and retired manual configuration.

Sockets and decrypted credentials remain ephemeral under `/run`. The shared
host Nix store and shared PostgreSQL cluster retain their system locations;
Max's peer-authenticated database and role are both named `max`.

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

Durable work is `/var/lib/max/runtime/volumes/<legacy-name>-data/work`.
Expendable guest roots are under `/var/lib/max/runtime/roots`, and root-owned
instance metadata is under `instances`. Stopping an instance preserves work and
package roots. Explicit destruction removes both. The database retains its
existing container/volume columns and stable identifiers; the image column now
records `nixos-sandbox-v1`.

The guest mounts host `/nix/store` read-only, without the host Nix daemon socket
or database. Requested packages are built by the host from its fixed nixpkgs
source, rooted under `/var/lib/max/runtime/gcroots/<instance>/`, and placed
on PATH for the requested command. Python package attributes are combined into
one `python3.withPackages` environment. Native manifests observe `/work`; the
legacy Docker layer-diff fields are empty because no Docker filesystem layer
exists.

The native bridge `max-sb-native` uses `10.231.0.0/16`. Isolated bridge ports and
nftables allow public IPv4 egress while blocking host, private, link-local,
Tailscale and sibling addresses. Where unrelated Docker services remain, narrow
DOCKER-USER forwarding rules coexist with this earlier filter. Max does not
enable Docker or grant its user membership in the Docker group.
The network unit prepares a shared `/run/netns` mount. Daemons that bind their
own namespaces, such as DAE, should start after `max-sandbox-network.service` so
later sandbox creation cannot hide an earlier namespace mount. The nspawn
template preserves the broker's DNS configuration instead of copying a host
loopback resolver into the private network.

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
nix build .#checks.x86_64-linux.state-migration
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

## Historical Docker-to-native migration

This is an offline maintenance operation. Build and validate the new system
first. Retain its store path and the current `/run/current-system`, and verify a
custom-format PostgreSQL backup with `pg_restore --list`. Keep the old Docker
images, work volumes and `max-nix` until the native system has been accepted.

Inspect the proposed copy with the new `max-runtime` on PATH:

```sh
scripts/migrate-native-runtime.sh --check
```

`migrate-native-runtime.sh` is the first-stage copier used by the original
Docker cutover. Its default staging tree is `/var/lib/max-runtime`, and its
NapCat source is `/var/lib/max-bot/napcat`. It deliberately preserves Docker
volumes and verifies content/hardlinks before publishing each work directory.
For a fresh Docker migration, stop the old workloads, provide the new
`max-runtime` binary on PATH and prepare the `max-napcat` system user/group
before running `--copy`. Then run the state-layout migration below **before**
activating the current module. Do not activate the new `max` user while the
old `max-bot` account/database still need renaming.

For both migrations, gate `max.service`, `max-runtime.service`,
`max-runtime.socket` and `max-napcat.service` with runtime drop-ins at
`/run/systemd/system/<unit>.d/90-max-native-cutover.conf` containing `[Unit]`
and `ConditionPathExists=/run/max-native-cutover-ready` on separate lines.
Ensure the marker is absent and reload systemd. Runtime masks alone are
insufficient: NixOS unit definitions under `/etc` take precedence over `/run`.
Retain those gates throughout activation; remove only the four migration
files after validation and reload systemd before starting the target.

## Migrating the original native state layout

Validate `checks.x86_64-linux.state-migration` and the new system first. Run
`scripts/migrate-max-state.sh --check` on the host. Gate the four units listed
above, stop `max-stack.target`, and wait for every browser/sandbox unit to stop.
Run `scripts/migrate-max-state.sh --migrate` before activating the new module.
The script verifies PostgreSQL/QQ backups, atomically moves the old state trees,
archives manual configuration and disposable runtime metadata, preserves the
service UID/GID while renaming it to `max`, and renames the database/role without
recreating either. Known absolute media paths are updated transactionally;
relative paths and browser encryption keys remain intact. Indirect Nix GC roots
are registered again at their new paths.

Activate the validated system with the startup gates still present. Verify peer
DB access, rendered JSON and ownership, then remove the gates and start
`max-stack.target`. Check real QQ login, OneBot connectivity, existing sandbox
work and browser navigation. Old Docker volume backups remain Docker-owned
rollback archives; this migration does not delete them.

If a step fails, keep the startup gates and use the phase/output plus
`/var/lib/max/backups/latest-state-migration` to inspect retained evidence. The
script refuses to overwrite an existing destination; do not blindly rerun it.
A rollback requires stopping the new stack, restoring directory locations and
UID/GID names, renaming the database/role back (or restoring its verified dump),
and selecting the retained old system. Do not start the old generation against
new paths or the new database name.
