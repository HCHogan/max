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
  VM it puts `max.ip`, `max.gateway` and `max.dns` on the guest's kernel
  command line, and a oneshot in the guest applies them before the network
  comes up. The same command line names the VM, `systemd.hostname=maxvm9`
  for conversation 9's: the image has no hostname of its own.
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
  `<vm.dir>/<conversation id>/`, and writes two files:
  `boot.env`, which the unit reads (the tap,
  the sizes, the kernel, the initrd and the command line), and `boot.json`,
  which the next max reads (the slot, the image, whether with Max's
  units). Then
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
  VM's slot and logs in within 10 seconds (`ATTACH`). Its idle time counts from then. A VM max can't use is stopped,
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
  does: to the guest's sshd on the vsock socket, through
  `systemd-ssh-proxy vsock-mux/…`, offering nothing. It is for root, who
  can open the socket. The session starts in `/work`, and
  its `HOME` is `/var/empty`, as for max's own commands, so nothing in the
  group's home runs in it (see [Units follow /work](jobs.md#units-follow-work)).
  max doesn't know of the session: a VM not kept on is still stopped
  after its idle time.
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

## Entering another conversation's VM

Along a link from A to B, Max in A may enter B's VM: `ssh c9.max` in A's
VM is root in conversation 9's, in its `/work`, and `scp` and `sftp` go
the same way. That is all a link gives, and all there is between two
conversations: without one they are isolated (`history`, the VM and
`/work` are each one conversation's; only the sticker library is shared).
Why it is ssh, through max, and why Max there isn't asked by a tool of its
own, is in
[decisions/links-enter-only.md](../decisions/links-enter-only.md).

- **What runs there is B's.** Everything in a VM is one caller, so `maxx`
  in B's VM is B's whoever runs it: `maxx history` reads B's chat, `maxx
  say` says in it, and `maxx wake '…'` wakes B's Max with those words, as
  a program of B's own would. B's Max sees a row tagged `max-wake`; who
  woke it and what for is whatever the words say. Nothing comes back by itself:
  B has no way to A, so what Max in A wants of B it looks for there
  again, in B's history or a file in its `/work`.
- **Permission is an edge between conversations**, not a person's: below a
  conversation nothing could be enforced, since its members share one VM as
  root and one context. A person's own permission is their private chat's;
  see [decisions/permission-by-conversation.md](../decisions/permission-by-conversation.md).
- **An edge has a direction.** A→B lets Max in A into B's VM, not the other
  way, and what it exposes is B: anyone in A can have A's Max do in B's VM
  what B's Max can, the [tailnets](#tailnets) it is on and the logins in
  its browser included. An edge into B is a membership of B's VM, if not
  of its chat, made only where that is acceptable. B gets into A only by a
  link B→A.
- **`/link` makes one**, with a code, as `/bind` does: `/link` in A answers
  with a six-digit code, valid 10 minutes and held in memory; `/link <code>`
  in B makes A→B. The side to be entered redeems the code, since it is the
  one exposed. Both directions take two links. `/unlink c#N` removes the
  edges between this conversation and that one, both ways, from either
  side. All three are for the people a conversation belongs to: a group's
  owner, not its administrators; the other party of a private chat; and
  Max's owners (see [Who may run what](commands.md#who-may-run-what)). The
  answers say which way an edge runs:

  | Command | Answer |
  | --- | --- |
  | `/link` in A | `code issued: 123456 lets Max here enter another conversation's VM, and not the other way`, then `send /link 123456 there (in a group: @maxx /link 123456)` and `valid for 10 minutes, once` |
  | `/link 123456` in B | `linked: Max in c#7 <title> may enter this VM now, with all that Max here has, and not the other way`, then `@maxx /unlink c#7 removes it`; or `skipped: Max in c#7 <title> may enter this VM already` |
  | `/link 123456` in A itself | `error: that code was issued here; send it in the conversation whose VM Max here is to enter` (the code is looked at before it is used, `Codes::peek`, so the slip doesn't use it up) |
  | a wrong, used or expired code | `error: no such code, or it has run out` |
  | `/unlink c#7` | `unlinked: Max here and Max in c#7 <title> can't enter each other's VM any more`, or `skipped: no link with c#7` |
  | `/status` | `may enter c#9 · c#12` and `open to   c#7`, each only when there is someone |

  `/link` codes are kept apart from `/bind`'s (`code::Codes`). A isn't told
  when its code is used; its `/status` shows the edge.
- **Edges are stored** in `links`: `from_id`, `to_id`, `made_at`, keyed by
  the pair. Mutable, like `conversation_settings`; the commands that
  changed it are rows of the ledger. No rule derives edges: on QQ a
  person's openid differs per group and in private chat, so even "a
  person's private chat may enter the groups they're in" can't be derived.
- **Names**: a conversation's handle is `c#N`, shown with
  `conversations.title` when there is one (`links::Peer`). A group's actor asks
  QQ's `info` for the group's name once as it starts, in a `side` task, and
  stores it as the title (`Conversation::learn_title`); a failure is only
  logged, and a renamed group is known by its new name after max restarts. A
  private chat on QQ has no name (see [The official QQ bot](qq.md#inbound)), so
  it is told apart by its number; how to name one is open. A title is a name
  its people chose and goes into what Max is shown, so it is one line,
  control characters as spaces, cut at 40 characters.
- **What Max is told**: the conversations whose VMs it may enter are listed
  in the volatile block after the people, under `[能进的会话]`, a line each,
  and those that may enter its own under `[能进来的会话]`, read from `links`
  when a core starts (none, no block), so the system prompt stays the same
  for every conversation, and an edge made during a core shows from the
  next (max checks the edge at every connection). The system prompt's
  legend says how to enter, that `maxx` there is that conversation's, with
  `history`, `say` and `wake` as examples, that Max there has no way back,
  and that a `max-wake` row here may be a linked conversation's doing.
- **The way is max's.** The guest's ssh_config sends `Host *.max` through
  `maxx connect %h` (`nix/connect.js`), which asks max at
  `127.0.0.1:7777` for `/connect/9` as an HTTP upgrade (`Connection:
  upgrade`, `Upgrade: ssh`). max knows whose VM asks as for every call
  (see [A guest's calls reach max](#a-guests-calls-reach-max)), reads
  whether there is a link from it to B (`links::linked`), takes B's VM as
  a call does, booting it
  if it isn't running, and opens B's sshd at the VM's vsock port 22 as it
  does for its own login (`ssh::sshd`). Then it answers 101 and copies the
  bytes both ways (`vm/enter.rs`). A refusal is plain text, which `maxx
  connect` prints: 403 `no link from c#7 to c#9`, 503 for a VM that
  doesn't start.
- **The guest's sshd asks for nothing.** What reaches it at all is what
  reaches the VM's vsock port 22: max, and a connection max let through
  along a link; on the host, only root and max's user can open the vsock
  socket. So root's password is empty and sshd takes it, as OpenSSH's
  "none" authentication (`PermitRootLogin`, `PasswordAuthentication`,
  `PermitEmptyPasswords`, and PAM's `nullok` for sshd alone, so a console
  login and `su` still refuse it). max logs in so, as `maxx-ssh` does;
  A's ssh offers nothing and checks no host key, since each VM's is made
  at its boot. This holds only while vsock is the one way to a guest's
  sshd: its TCP listener doesn't start, and taps don't reach each other.
- **A connection holds B's VM**, as a call does: B isn't stopped as idle
  while one is open. It ends when either end closes, or as max stops,
  which ends every one. `/unlink` refuses the next; one that is open runs
  on until it ends.

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
  runs and nothing has begun or ended in the last 10 (`maxx jobs idle
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
`chown` succeeds without effect and `mknod` fails.

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

## Tailnets

The host puts no VM on a tailnet. A guest reaches the internet, which is
all Tailscale needs, so when someone wants Max on their machines, Max joins
their tailnet itself: tailscaled as one of its own units (see
[Resident programs](jobs.md#resident-programs)), its state under `/work`,
the node let in by whoever runs that tailnet. A tailscaled is on one
tailnet at a time; for several, Max runs one each in userspace networking,
which keeps their routes and their `100.64.0.0/10` addresses apart, and
reaches each by its own socket (`tailscale --socket=… nc`) or proxy.
Nothing in the image or the prompt is for this. The image has
`/dev/net/tun`, as any Linux machine does: its initrd loads `tun`, since
the guest loads modules and makes the device nodes ahead of them only in
the initrd, from the initrd's modules.

What Max joins is its conversation's, as everything in its VM is: anyone in
the conversation can have Max use it, and the tailnet's own ACLs say what
the node reaches. The host's tailnet is out of a guest's reach, as every
private address is (see [The host](#the-host)). Why the host keeps no
tailnet for the VMs is in
[decisions/max-joins-tailnets-itself.md](../decisions/max-joins-tailnets-itself.md).

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
  one step (`stopIfChanged = false`) and leaves the socket.
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
- **max answers everything there**: the tools and `/events`, and
  the models' calls and the keyed APIs', `/llm` and `/api`
  (`service/forward.rs`, `forward/api.rs`), with the keys it read at
  startup.
- **A call waits with its guest** while max restarts: it sits at the socket
  for as long as the guest's caller waits. A connection the guest drops is
  dropped at max, which cancels the call.
- **An API's hourly limit is all the chats' together**, counted in max's
  memory: the count starts over with max.
- **A model call from a VM isn't recorded**: its usage isn't read on its
  way back.
- **vm-check** has a provider of its own for the agents, which counts what
  it is asked.

## Testing

- `max vm-check` starts a VM as max would and runs checks in it (a
  command, a program calling the tools, the browser, units, background
  commands and agents); `--command` runs a command of your own.
- The flake's `nestedChecks.<system>.vm` runs the module, the taps, nft and
  the hardened service in a NixOS test machine, and `maxx-vm-check` inside
  it, which needs nested KVM: CI's runners can't give it, so it isn't in
  `checks` and is run on tank. It also covers a guest's calls across a
  restart and a stop of max, a model's answer streamed through max, a
  deploy that brings a second image and restarts the VM on it, `maxx-ssh`
  and the machined registration, a VM's ssh into another's along a link and
  its refusal the other way, and that a VM reaches neither a stand-in
  for the machine's tailnet (100.64.0.2, in another namespace, which the
  machine reaches) nor the machine's own address on it. On a Mac it runs too slowly to pass; see
  [research/nested-test-on-mac.md](../research/nested-test-on-mac.md).
- The guest's jobs have a NixOS test of their own, `.#checks.<system>.jobs`;
  when to run which is in AGENTS.md.
