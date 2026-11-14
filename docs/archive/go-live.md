# Go-live

## Test environment

Decided 2026-10-27:

- QQ (changed 2026-10-28): the old account was banned, and the Haskell version has stopped running on QQ. The Rust version uses the official bot maxx, added to a test group in which the owner is an administrator and the two switches are turned on; see [The official QQ bot](../design/qq.md#the-official-qq-bot-1). NapCat is not touched.
- **Fully separate from the Haskell version** (decided 2026-10-27): on tank the Rust version is a parallel set of services, all named `maxx` to distinguish them from the Haskell version's `max`:
  - systemd: `maxx.target` manages the whole set of services, and all units sit under `maxx.slice`, so that their resource limits are accounted separately. VMs are child processes of `maxx.service` and have no units of their own; see [VM processes](../design/vm.md#vm-processes).
  - Storage: the system user `maxx`, the state directory `/var/lib/maxx`, the runtime directory `/run/maxx`, the `maxx/` prefix in sops, and a separate `maxx` database and role in Postgres.
  - VMs: a separate tap pool and set of subnets, with the subnets avoiding 10.231 and 10.233, which the Haskell version uses. The Haskell version's broker and its `max-sb-` namespace are not touched: when the Haskell version starts, it reconciles and deletes any instances and volumes under this prefix that are not in its own database.
  - This name is a parameter of the NixOS module; examples elsewhere in this document still use `max`.

## Go-live: conditions for a drop-in replacement

- Everything in the [Feature parity checklist](haskell-parity.md#feature-parity-checklist) is complete.
- A data import program is written that imports the Haskell version's database into the new schema in one go; the mapping is described in [Import](../design/ledger.md#import) (under [Schema](../design/ledger.md#schema)). It must be able to run repeatedly, and it is rehearsed before go-live.
- The NixOS module's interface is not kept compatible, and tank's nix-config changes along with it; see [Configuration](../design/config.md#configuration-1).
- During testing, the new version is called `maxx` on tank and runs in parallel with the Haskell version (see [Test environment](#test-environment)). At go-live, the Haskell version's `max` set of services is stopped and replaced by the new version; the name is a parameter of the module, so changing it back to `max` touches only one place.
- The `/work` directory of each of the Haskell version's group VMs is migrated to the new version; see [Import](../design/ledger.md#import).
- The switch (done 2026-10-31): main was merged into the `maxx` branch, keeping the Haskell history from main's lifetime while taking all content from the Rust version; main was then fast-forwarded to `maxx`, without a force push. The last Haskell commit on main is tagged `haskell-final` (`f33261b`, an unfinished feature: requests queued behind a waiting request are merged into it). In nix-config, gaoji on h610 and on tank still uses the Haskell version's NapCat module, with the `max` input pinned to `haskell-base`.
- Rollback: the Haskell version is kept until the Rust version is stable; how to handle new data produced after the Rust version goes live is **TBD**.
