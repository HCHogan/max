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
  that is neither in use, busy nor kept on), prepares `work`, `nix.img`
  and the link the guest's calls come by
  (see [A guest's calls reach max](#a-guests-calls-reach-max)) under
  `<vm.dir>/<conversation id>/`, and writes three files:
  `boot.env`, which the unit reads (the tap,
  the sizes, the kernel, the initrd and the command line); `boot.json`,
  which the next max reads (the slot, the image, whether with Max's
  units); and `ssh.key`, the key made for this boot. Then
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
  arrive at `notify.vsock_7777`, a link to max's own socket (see
  [A guest's calls reach max](#a-guests-calls-reach-max) and
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
  record, one whose slot isn't free for it, one that booted another image
  than max boots.
- **A new image restarts its VMs.** A guest is the image it booted until
  it stops, and what it and max say to each other (what max runs with
  `maxx`, the line a call prints, the runner's input, the routes a guest
  calls) is only kept in step within one image. So max attaches to a VM
  only if `boot.json` names the image max boots itself, by its path: a
  deploy that brings another stops every VM that runs, with the background
  commands and agents in it, as max starts, and each boots the new image
  when it is next needed. A deploy of max alone, as most are, leaves the
  VMs as they run. Why a guest isn't switched where it runs is in
  [decisions/a-new-image-restarts-its-vms.md](../decisions/a-new-image-restarts-its-vms.md).
- **What the host gave a VM at its boot stays as it was**: the link its
  calls come by, the unit's launcher, the command line. A change to those
  reaches a VM at its next boot; a deploy that can't wait for that stops
  the VMs, `systemctl stop 'maxx-vm@*'`.
- If max's connection to a VM drops while its unit runs (its sshd
  restarting, say), max attaches again (`Service::reattach`) before
  giving the VM up. If the unit no longer runs, the VM ended by itself:
  `machine::attach` asks systemd before trying the socket, the end counts as
  a failure, and the call that found it has the VM boot again.
- **GC roots**: max links the image each VM booted, as `7`, under
  `/nix/var/nix/gcroots/per-user/maxx/`, since the host's weekly collection
  would otherwise take an image from under a guest that still runs it. The
  link goes when max stops the VM, and those of VMs that ended without max
  (a host restart) when max next starts.
- **While max restarts**, what a guest asks of it waits. The socket the
  guests reach max at is systemd's (`maxx.socket`), which listens
  whether max runs or not: a request made meanwhile waits there, and the max
  that comes answers it. Nothing in a guest asks twice. As max begins to
  stop it takes no more from the socket (`Vms::stop_listening`), so nothing
  new comes to a max that won't begin it. A call that was running when max
  stopped fails as `closed`: it may have acted. A model's or a keyed API's
  call that max was passing on is cut off with max; whoever tries it again
  waits at the socket.
- **A call whose caller left while it waited isn't begun.** A turn cut off
  by the restart takes its program with it, and the request that program
  had waiting is still at the socket, whole. Its connection closed when its
  caller went, and max asks of each connection it takes, before reading
  anything, whether its other end has hung up (`service::Waited`): one that
  has is dropped.
- **Stopped for good**, max is stopped with its socket: `systemctl stop
  maxx.socket maxx.service`, or the target. Then nothing listens, a guest's
  connection only closes, and its client reports a failed call,
  `unreachable`. With max's unit alone stopped the socket still listens,
  and the next thing a guest asks starts max again.
- **Stopping**: only max asking systemd stops a VM (idle, evicted, dead,
  unusable at attach, as on another image), or `systemctl stop
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
tap's flags) and the VM's directory read-write (the vsock socket). max's
socket, which the guest's calls go to by a link in that directory, is
beside it: Landlock as cloud-hypervisor sets it up governs opening files,
and not connecting to a Unix socket by its path (kernel 6.18), which the
nested test would show if it changed.
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
- **The namespace's resolvers**: its tailscaled can't reach the host's
  resolver, so it is given `vm.dns` as its /etc/resolv.conf. systemd
  binds a file at the end of /etc/resolv.conf's links, which on a host
  with resolved is resolved's stub, and resolved renames a new stub over
  the old one whenever the host's DNS changes; the mount goes with the old
  file, and the client is left with the host's 127.0.0.53. It keeps the
  connection to Headscale it has, and fails only when it must look the
  server up again. So on such a host a directory with both of resolved's
  files is bound over `/run/systemd/resolve`, which resolved keeps.
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
  accepts no new connections from the VMs. An ordinary group mustn't get
  root on the machine running max or on any VM.
- **The host, as any other machine**: its own tailnet address is local, so
  the host would take a VM's packets for it and refuse them at its input
  chain. With `vm.operations.hostAddress` set, the host sends them to the
  namespace's end of the uplink instead, which hands them on to that
  address over the tailnet, and the host's Tailscale SSH lets them in as
  max, as every other machine does. An operations group then has root on
  the machine running max as well: its keys, its database, every group's
  VM.
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

## A guest's calls reach max

Everything a guest asks of the host comes to max itself, at one socket,
with no process between them. Why is in
[decisions/guests-reach-max-directly.md](../decisions/guests-reach-max-directly.md).

- **One socket for every VM**, `<vm.dir>/max.sock`, beside the VMs'
  directories. cloud-hypervisor connects to `notify.vsock_7777` in the VM's
  directory when the guest connects to the host's port 7777, and that is a
  link to `../max.sock`, which max makes when it boots the VM
  (`machine::calls`). Nothing in a group's `/work` that names
  `127.0.0.1:7777`, a git remote among them, knows of it.
- **The socket is systemd's**, a unit (`maxx.socket`) that gives it to max
  as max's standard input (`StandardInput=socket`; `vm::given`); under
  vm-check and in a terminal max binds it itself. A deploy restarts max in
  one step (`stopIfChanged = false`) and leaves the socket; why it is so is
  in [decisions/max-socket-is-systemds.md](../decisions/max-socket-is-systemds.md).
- **Whose VM a call is from is the process's that made its connection.** A
  guest's connection to the host is made for it by its VM's
  cloud-hypervisor, the main process of the VM's unit. Of each connection
  it takes, max reads the pid at the other end (`SO_PEERCRED`) and asks
  systemd which unit that process belongs to (`systemctl whoami`;
  `machine::whose`), once a connection, a few milliseconds:
  `maxx-vm@7.service` is conversation 7's (`service::Caller`,
  `service::Calling`). Nothing in a guest chooses that process, so no VM
  speaks for another's, and only max's user reaches the socket. A call on a
  connection that no VM's process made is refused, 400. `/proc` doesn't
  say: each unit has a user namespace of its own, and with
  `ProtectProc=invisible` sees none of another's processes.
- **max answers everything there**: the tools, `/events` and `/units`, and
  the models' calls and the keyed APIs', `/llm` and `/api`
  (`service/forward.rs`, `forward/api.rs`), with the keys it read at
  startup.
- **A call waits with its guest** while max restarts: it sits at the socket
  for as long as the guest's caller waits. A connection the guest drops is
  dropped at max, which cancels the call.
- **An API's hourly limit is all the chats' together**, counted in max's
  memory: the count starts over with max.
- **A model call from a VM isn't recorded**: its usage isn't read on its
  way back; see
  [decisions/forwarder-keeps-no-count.md](../decisions/forwarder-keeps-no-count.md).
- **vm-check** has a provider of its own for the agents, which counts what
  it is asked.

## Testing

- `max vm-check` starts a VM as max would and runs checks in it (a
  command, a program calling the tools, the browser, units, background
  commands and agents); `--operations` uses the operations network's last
  tap, `--command` runs a command of your own.
- The flake's `nestedChecks.<system>.vm` runs the module, the taps, nft and
  the hardened service in a NixOS test machine, and `maxx-vm-check` inside
  it, which needs nested KVM: CI's runners can't give it, so it isn't in
  `checks` and is run on tank. It also covers a guest's calls across a
  restart and a stop of max, a model's answer streamed through max, a
  deploy that brings a second image and restarts the VM on it, `maxx-ssh`
  and the machined registration,
  and the operations network against a fake tailnet (a veth in
  `maxx-ops` to 100.64.0.2 in another namespace: the operations VM
  reaches it and the machine's own tailnet address, an ordinary VM
  can't and has no ssh_config), with networkd checked to keep the rule
  and the namespace's client its resolvers when resolved rewrites its
  stub. On a Mac it runs too slowly to pass; see
  [research/nested-test-on-mac.md](../research/nested-test-on-mac.md).
- The guest's jobs have a NixOS test of their own, `.#checks.<system>.jobs`;
  when to run which is in AGENTS.md.
