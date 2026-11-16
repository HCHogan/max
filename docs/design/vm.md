# VMs

Each conversation has a NixOS VM on cloud-hypervisor, where Max's programs,
background agents and resident units run, with `/work` as Max's home. A VM
is a unit of the host's systemd, `maxx-vm@<conversation>.service`, which max
starts and stops and which outlives max. Nothing at run time needs root;
why and how that was verified is in
[decisions/vms-without-a-broker.md](../decisions/vms-without-a-broker.md).
The VM service is `crates/max/src/vm.rs`, a VM's machine `vm/machine.rs`, the
host's side `nix/module.nix` and the guest `nix/guest.nix`.

## The host

Only declarative configuration applied at boot needs root, all in NixOS:

- `maxx` is in the `kvm` group.
- A oneshot, `maxx-taps`, pre-creates a set of taps with `ip tuntap` (32 by
  default, `vm.slots`), owned by `maxx`, multi-queue with vnet headers.
  The module doesn't bring in systemd-networkd for this, choosing no
  network stack for the host. The taps stay when the unit stops, so
  restarting it doesn't cut running VMs off.
- Each tap is its own /30 (out of `10.235.0.0/24` by default): the host is
  `.1`, the guest `.2`, every VM the same MAC. No DHCP: when max starts a
  VM it puts `max.ip`, `max.gateway`, `max.dns`, the boot's SSH public key
  `max.key` (and `max.domain` on the operations network) on the guest's
  kernel command line, and a oneshot in the guest applies them before the
  network comes up.
- The taps aren't bridged; routing and nft keep VMs apart. A VM may use
  only its own tap's `.2` as source and reach only public addresses, with
  no IPv6; connections from a VM to the host are always refused, the host
  answers only established connections, and outgoing traffic is
  masqueraded.
- A polkit rule lets max's user start and stop the `maxx-vm@` units and no
  others.

## Starting a VM

- max picks a free slot (with none free, it stops the VM unused longest
  that is neither in use, busy nor kept on), prepares `work` and
  `nix.img` under `<vm.dir>/<conversation id>/`, and writes three files:
  `boot.env`, which the unit reads (the tap,
  the sizes, the kernel, the initrd and the command line); `boot.json`,
  which the next max reads (the slot, the guest's contract, the image,
  whether with Max's units); and `ssh.key`, the key made for this boot. Then
  it has systemd start the unit, whose launcher starts two virtiofsd (a
  read-only one for the store, a read-write one for `/work`) and
  cloud-hypervisor, its main process. max tries SSH every 100 ms; the VM is
  started once one connects, within 60 seconds (`BOOT`).
- At least 2 vCPUs: the tap is multi-queue, and cloud-hypervisor opens it
  so only with two or more queue pairs, at most one per vCPU.
- The command lines are Max's own, in the launcher; only the guest's
  kernel, initrd and kernel command line come from the guest's build, which
  emits them as a JSON file named in the configuration. What differs from
  boot to boot comes from `boot.env`.
- On x86_64 cloud-hypervisor boots the ELF `vmlinux` with the console on
  `ttyS0`; on aarch64, `Image` with a PL011 on `ttyAMA0`. The aarch64 guest
  has booted and run tools, but only under two layers of virtualisation on
  a Mac, where the browser timed out.
- **Channels**: the hybrid vsock socket is in the VM's directory. max
  connects to port 22 over it (sending `CONNECT 22\n` first) and runs russh,
  one connection per VM and one channel per command. Calls from the guest
  arrive at `notify.vsock_7777`, where the VM's forwarder listens (see
  [A VM's forwarder](#a-vms-forwarder) and
  [The guest's calls](tools.md#the-guests-calls)).
- **A guest that resets ends its VM.** The guest's command line has
  `reboot=t panic=-1`, so a reboot and a kernel panic both reset the
  machine, and cloud-hypervisor boots a guest that resets again in the same
  process. That can't work here: each virtiofsd serves the one connection it
  was given and ends with it. So the launcher kills cloud-hypervisor when a
  virtiofsd ends, and the unit ends at once, as failed. To max it is a VM
  that stopped by itself (see [A VM outlives max](#a-vm-outlives-max)): a
  call that needs it boots it again, and a kept one comes back at a sweep.
  What ran in the guest is gone; `/work` and the store's image stay. Why
  not a reboot in place is in
  [decisions/a-guest-reset-ends-its-vm.md](../decisions/a-guest-reset-ends-its-vm.md).
- A VM that failed to boot, or stopped by itself, twice within 30 minutes
  (`FAILING`) boots once without Max's units, since one of them may be what
  stops it. A reboot Max runs itself counts as any other.

## A VM outlives max

The VM's unit isn't part of `maxx.service`: stopping or crashing max leaves
it, and `restartIfChanged = false` keeps a deploy from restarting it. Why
is in [decisions/lifetimes-to-systemd.md](../decisions/lifetimes-to-systemd.md).

- **Attaching**: when max starts, it lists the active `maxx-vm@` units and
  attaches to each (`Service::attach`): it reads `boot.json`, takes the
  VM's slot and logs in with the saved key within 10 seconds (`ATTACH`). Its idle time counts from then. A VM max can't use is stopped,
  and boots again when next needed (at once, if kept on): one without a
  record, one whose slot isn't free for it, one whose guest keeps another
  contract.
- **The contract** is a number (`nix/contract.nix`) for what max says to a
  guest it didn't boot and what the guest keeps between images; the guest's
  JSON carries it. When to raise it is in AGENTS.md.
- **Switching a running guest**: a VM booted from an image a deploy has
  replaced, with the same contract, runs on, and its guest is switched to
  the new system where it runs. The guest's store is the host's, so the new
  system is already there: max runs that image's `max-switch` in the guest
  (`machine::switch`), which loads the system's paths into the guest's Nix
  database, as `register-nix-paths` does at boot, and then runs NixOS's
  `switch-to-configuration test` in a unit of its own. Commands, agents and
  resident programs run through it: Max's own units and the transient ones
  aren't in `/etc/systemd/system`, which is all a switch looks at, and what
  mustn't restart under running work is marked `restartIfChanged = false`
  (`max-guest`, `max-host@`, `max-notify@`, `max-browser`); the runner's link
  has a unit of its own, `max-runner`, which a switch runs again.
- **Stale VMs**: one that boots another kernel or initrd than the image's,
  or whose switch failed, is stopped once nothing of Max's runs in it and
  nobody has used it for 10 minutes (`QUIET`), to boot the new image whole;
  a kept one boots again in the same sweep.
- If max's connection to a VM drops while its unit runs (a switch
  restarting sshd, say), max attaches again (`Service::reattach`) before
  giving the VM up. If the unit no longer runs, the VM ended by itself:
  `machine::attach` asks systemd before trying the socket, the end counts as
  a failure, and the call that found it has the VM boot again.
- **GC roots**: max links what each VM booted (whose kernel modules it goes
  on loading) and each image it was switched to (whose processes may run
  on), as `7` and `7.<image>`, under `/nix/var/nix/gcroots/per-user/maxx/`,
  since the host's weekly collection would otherwise take a replaced image
  from under a running guest. The links go when max stops the VM, and those
  of VMs that ended without max (a host restart) when max next starts.
- **While max restarts**, what a guest asks of it waits. The socket the
  forwarders reach max at is systemd's (`maxx.socket`), which listens
  whether max runs or not: a request made meanwhile waits there, and the max
  that comes answers it. Nothing in a guest asks twice. As max begins to
  stop it takes no more from the socket (`Vms::stop_listening`), so nothing
  new comes to a max that won't begin it. A call that was running when max
  stopped fails as `closed`: it may have acted.
- **A call whose caller left while it waited isn't begun.** A turn cut off
  by the restart takes its program with it, and the request that program
  had waiting is still at the socket, whole. The forwarder closed that
  connection when its caller went, and max asks of each connection it
  takes, before reading anything, whether its other end has hung up
  (`service::Waited`): one that has is dropped.
- **Stopped for good**, max is stopped with its socket: `systemctl stop
  maxx.socket maxx.service`, or the target. Then nothing listens, and a
  forwarder answers a guest 503 with a failed call, `unreachable`. With
  max's unit alone stopped the socket still listens, and the next thing a
  guest asks starts max again.
- **Stopping**: only max asking systemd stops a VM (idle, evicted, dead, on
  an older image and quiet, unusable at attach), or `systemctl stop
  maxx.target`, or vm-check, which stops its own (`Vms::shut`). A stop is
  `systemctl stop --no-block`, and booting the same VM waits until systemd
  has that request (`Service::stopping`), so a start can't reach systemd
  first and be the one stopped.

## Getting into a VM

- **`maxx-ssh 7`** on the host is a root shell in conversation 7's VM, and
  `maxx-ssh 7 systemctl status` runs a command there. It goes in as max
  does, with the boot's `ssh.key` to the guest's sshd on the vsock socket,
  through `systemd-ssh-proxy vsock-mux/…`; it is for root, who can read
  max's files. max doesn't know of the session: a VM not kept on is still
  stopped after its idle time.
- **A running VM is a machine of the host's**: the unit's `ExecStartPost`,
  as root, registers it with systemd-machined (`RegisterMachine` on the bus) as
  `maxx-7`, class `vm`, service `maxx`, leader cloud-hypervisor (dropping a stale registration of
  the name first). `machinectl list`, `status maxx-7` and `terminate maxx-7`
  work; machined forgets it when cloud-hypervisor ends; a failed
  registration is only logged.
- `machinectl login` and `shell` can't take a VM in systemd 260
  (`machine_openpt` answers "not supported" for one), nor can
  `ssh machine/maxx-7`, which wants an `AF_VSOCK` CID the host's kernel
  reaches, where cloud-hypervisor's vsock is a multiplexer on a UNIX socket.
  So the way in is `maxx-ssh`.

## Resources

- **Volumes** are owned by `maxx` and removed only on explicit deletion.
- **Packages**: `maxx` builds through the nix daemon and places GC roots in
  `/var/lib/maxx/gcroots/<conversation id>/`; the guest sees them through the
  read-only store share. No root needed.
- **Limits**: memory and vCPUs are capped by the hypervisor's parameters
  (8 vCPUs, 16 GiB and a 64 GiB disk per VM on tank). VMs have no cgroups of
  their own and no limit together: a limit on `maxx.slice` would constrain
  max too and kill processes when reached. Memory is allocated on use, and
  pages the guest frees go back to the host by the balloon's free page
  reporting; the page cache doesn't count as free.
- **Idle guests drop their caches**: every 10 minutes, if nothing of Max's
  runs and nothing has begun or ended in the last 10 (`maxx units idle
  600`, reading the times in `/run/max/jobs`), the guest runs `sync`,
  `drop_caches=3` and `compact_memory` (`max-trim.timer` in `nix/jobs.nix`).
  The page cache, dentries and inodes go (virtiofsd closes the matching
  descriptors), and the free blocks compaction makes go back to the host:
  for shared memory (`shared=on`, memfd) cloud-hypervisor punches holes with
  `fallocate` and then `MADV_DONTNEED`. Kept VMs are trimmed too. No balloon
  resizing or memory and vCPU hot-plug: idle vCPUs cost nothing, memory is
  allocated on use, and shrinking a limit only forces the guest to drop its
  cache, which dropping it directly does without an API socket. Why these
  sizes stay is in
  [decisions/idle-guests-drop-caches.md](../decisions/idle-guests-drop-caches.md).
- **The store share's descriptors**: the store's virtiofsd keeps an
  `O_PATH` descriptor open for every store file the guest has looked up,
  until the guest's kernel forgets it, which with enough memory it never
  does. One `find /nix/store` in a VM once exhausted the service's 524,288
  descriptors, and every new store lookup in that VM failed until it
  restarted. So:
  - `LimitNOFILE` is 8,388,608, and virtiofsd raises its soft limit to
    match, enough for a scan of the whole store; the cost is about 1.4 KB of
    host kernel memory per open file (a bcachefs inode and its dentry and
    file), about 9 GiB for the whole store, returned when the guest forgets
    or the VM stops.
  - Max's and the agents' prompts say to find a package's files with
    `nix build --no-link --print-out-paths nixpkgs#<package>`, not with
    `find`, `ls` or wildcards under `/nix/store`.
  - virtiofsd's `--inode-file-handles` isn't used: `open_by_handle_at`
    needs `CAP_DAC_READ_SEARCH` in the initial user namespace, which would
    let it open any file on the host's file systems.

## Security

A VM escape yields `maxx`, which can read the database and the secrets.
cloud-hypervisor runs with seccomp and Landlock and no capabilities, under
`NoNewPrivs`; Landlock allows `/sys/devices/virtual/net` read-only (the
tap's flags) and the VM's directory read-write (the vsock socket).
virtiofsd, as an ordinary user, enters new user, mount, pid and net
namespaces, changes its root to the share and holds no capabilities. The
guest's root is mapped to `maxx` and every other uid squashed to it, so
`chown` succeeds without effect and `mknod` fails; the `/work` mapping is
also what lets the guest's sshd accept `authorized_keys`.

`maxx.service`'s hardening is relaxed in four places for this, and nothing
else:

- No `ProtectKernelTunables`, `ProtectKernelLogs` or `ProtectHostname`:
  their read-only mounts over `/proc` stop virtiofsd mounting a proc in its
  own user namespace.
- `RestrictNamespaces` allows user, mnt, pid and net, for virtiofsd's
  sandbox.
- `SystemCallFilter` adds `@mount`.
- `PrivateDevices` stays; `/dev/kvm` and `/dev/net/tun` come in with
  `BindPaths` and `DeviceAllow`.

`RestrictSUIDSGID` also keeps the guest from setting setuid bits in
`/work`.

## The operations network

The VMs of groups listed in `vm.operations.conversations` (conversation
ids, so no group numbers in the public repository) can reach the owner's
fleet over the tailnet. Anyone in such a group can have Max act on the
fleet, which amounts to root, so it is only for trusted groups. It copies
the Haskell version's `nix/operations.nix`, on cloud-hypervisor taps.

- **The network**: on the host, a network namespace `maxx-ops` runs its own
  tailscaled, the tailnet node `maxops` (Headscale user `max@imdomestic.com`).
  The operations VMs use taps of their own (`maxx-ops0…`, 10.236.0.0/24, 4
  by default), and the host routes everything from them into the namespace
  by source (`ip rule from 10.236.0.0/24 lookup 236`). Inside, traffic to
  the tailnet and the subnets it advertises goes through `tailscale0`, the
  rest back out through the uplink to the internet, both masqueraded as the
  namespace's address.
- **networkd must keep that rule**: when systemd-networkd configures an
  interface it manages, it deletes any ip rule not in that interface's
  `.network` file (`ManageForeignRoutingPolicyRules`, on by default, which
  the owner keeps). Once, after a host restart, it deleted the rule five
  seconds after `maxx-ops-network` added it, and the operations VMs' traffic
  fell through to the main table and was refused, unnoticed for a day. So a
  host using networkd must write the rule into a managed interface's
  `.network` (on tank, nix-config's `hosts/tank/maxx.nix`, on `30-br-lan`),
  or the module's assertion refuses to build; `maxx-ops-network` deletes
  every identical rule and adds it back with `proto static`, the same rule
  networkd adds, since networkd compares rules with their protocol.
- **Logging in without keys**: the fleet runs Tailscale SSH, and
  Headscale's policy admits `group:imdomestic` (which includes `max@`) by
  tailnet identity. Each machine has a `max` user with passwordless sudo
  (nix-config's `system/modules/max-operator.nix`). The VM holds no key and
  can't reach tailscaled's socket or state.
- **The guest**: the command line adds `max.domain=<tailnet domain>`, and
  `100.100.100.100` comes first among the resolvers (MagicDNS answers only
  tailnet names and SERVFAILs the rest, so glibc asks the next).
  `max-guest` writes `/run/max/ssh_config` from them: short names completed
  with the domain, `User max`, `BatchMode`,
  `StrictHostKeyChecking accept-new`, known_hosts in `/work/.ssh` (root's
  home is `/work`). The guest's ssh_config always `Include`s it; other VMs
  don't have the file, which ssh ignores. `programs.ssh.systemd-ssh-proxy`
  is off in the guest: its Include is a store file, which on virtiofs isn't
  owned by root, so ssh would reject its whole configuration.
- **What the host enforces**: traffic from the operations taps can only
  enter the namespace (anything with `oifname != maxx-uplink` is refused),
  so with the namespace down it never falls through to the host's own
  tailnet node; traffic leaving the namespace reaches only the internet,
  not the LAN, other VMs, the host's tailnet or its services; the namespace
  accepts no new connections from the VMs. The host itself can't be reached
  over ssh: its tailnet address is local, so a VM's packets are delivered
  to its input chain and refused. The machine running max and every VM
  mustn't let a group get root.
- **Slots**: operations groups use only the operations taps, others only
  the ordinary ones, each class evicting its own by idle time. A changed
  list takes effect at a VM's next boot.
- **The prompt** of these groups ends with an "operations network" section:
  how to ssh, passwordless sudo, saying what it will change before changing
  it, and long tasks in a remote `systemd-run` or tmux.
- **State**: the node's state is in `/var/lib/maxx-ops-tailscale`, the
  Haskell version's `maxops` identity carried over;
  `vm.operations.authKeyFile` logs in from scratch.
- Code: `config::Operations`, `Free` in `vm.rs`, the command line in
  `vm/machine.rs`, `max-guest` in `nix/guest.nix`, `vm.operations` in
  `nix/module.nix`.

## A VM's forwarder

The models' calls and the keyed APIs are answered by a process that
outlives max, so a deploy doesn't cut an agent's model call or a `git
push` in the middle. Why this and not more is in
[decisions/what-leaves-the-host.md](../decisions/what-leaves-the-host.md).

- **A unit for each VM**, `<name>-forward@<conversation>`, running `max
  forward --dir <the VM's directory>`, bound to the VM's unit, which wants
  it: systemd starts and stops it with the VM, and max does neither. A
  deploy that changes it leaves those that run (`restartIfChanged =
  false`); a VM gets the new one at its next boot.
- **The front door**: the forwarder listens where cloud-hypervisor connects
  when the guest connects to the host's port, `notify.vsock_7777` in the
  VM's directory. It answers `/llm` and `/api` itself (`service/forward.rs`,
  `forward/api.rs`) and passes everything else to max: the tools,
  `/events`, `/units`. So nothing in a group's `/work` that names
  `127.0.0.1:7777`, a git remote among them, had to change.
- **max listens for every forwarder at one socket**, `<vm.dir>/max.sock`,
  beside the VMs' directories. A forwarder is one VM's, and names its
  conversation to max in a header, `max-conversation`, in place of whatever
  the guest wrote under that name (`service::Calling`). Only max's user
  reaches the socket, so nothing in a VM speaks for another's. The socket
  is a unit of systemd's, which gives it to max as max's standard input
  (`StandardInput=socket`; `vm::given`); under vm-check and in a terminal
  max binds it itself. A deploy restarts max in one step
  (`stopIfChanged = false`) and leaves the socket; why it is so is in
  [decisions/max-socket-is-systemds.md](../decisions/max-socket-is-systemds.md).
- **A forwarder waits with its guest**: while max restarts its request sits
  at the socket, for as long as the guest's caller waits. A request max had
  and didn't answer is a failed call, `closed`, which may have acted. A
  request the guest drops is dropped at max, which cancels the call. Each
  request is a connection of its own to max, since one kept from before a
  restart would fail a call max never saw.
- **Its configuration is a link**, `forward.config` in the VM's directory,
  to the file max was started with. max makes it at boot and again each
  time it attaches, and the forwarder looks every two seconds: a link made
  again is read again, with the keys its file names, even if it names the
  same file. So a deploy's new models and keys reach running forwarders when
  the new max is back, with no restart. A new configuration is served by a
  new server on the same socket, and the old one ends when its calls do.
  The forwarder reads only `[llm]`, `[api]` and `[log]`
  (`config::Forwarded`), so what a newer max has elsewhere doesn't stop an
  older forwarder; a file whose `[llm]` or `[api]` it can't read is left,
  and it goes on with the last. Nothing secret is written into the VM's
  directory, which cloud-hypervisor may read: the file names the secrets'
  files, and the forwarder reads them.
- **An API's hourly limit is each chat's**: a forwarder counts its own
  VM's calls of the last hour, in memory, and shares nothing with another
  VM's. The count starts over with the VM's boot, and when the forwarder
  reads a configuration anew, as when max is back from a deploy.
- **max keeps no API key**, only their lines in the system prompt. It reads
  the secrets and the models' keys once at startup and lets them go, so that
  a missing one stops max at a deploy, not a forwarder when a VM boots.
- **A forwarder records nothing**: it has no connection to the database,
  a model call's usage isn't read on its way back, and what it counts of
  an API is gone with the process; see
  [decisions/forwarder-keeps-no-count.md](../decisions/forwarder-keeps-no-count.md).
- **vm-check** gives its VM's forwarder a configuration of its own, with a
  provider for the agents that counts what it is asked.
- A forwarder's code is as old as its VM's boot; only what it reads follows
  a deploy.

## Testing

- `max vm-check` starts a VM as max would and runs checks in it (a
  command, a program calling the tools, the browser, units, background
  commands and agents); `--operations` uses the operations network's last
  tap, `--command` runs a command of your own.
- The flake's `nestedChecks.<system>.vm` runs the module, the taps, nft and
  the hardened service in a NixOS test machine, and `maxx-vm-check` inside
  it, which needs nested KVM: CI's runners can't give it, so it isn't in
  `checks` and is run on tank. It also covers the forwarder across a stop of
  max, a switch to a second image, `maxx-ssh` and the machined
  registration, and the operations network against a fake tailnet (a veth
  in `maxx-ops` to 100.64.0.2 in another namespace: the operations VM
  reaches it, an ordinary VM can't and has no ssh_config), with networkd
  checked to keep the rule. On a Mac it runs too slowly to pass; see
  [research/nested-test-on-mac.md](../research/nested-test-on-mac.md).
- The guest's jobs have a NixOS test of their own, `.#checks.<system>.jobs`;
  when to run which is in AGENTS.md.
