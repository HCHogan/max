# Max enters a linked conversation's VM by ssh, through max

A link from A to B lets Max in A into B's VM as root: `ssh c9.max`, with
`scp` and `sftp`. The way goes through max, which checks the link for every
connection, and the guest's sshd asks for no password or key. The design is in
[Entering another conversation's VM](../design/vm.md#entering-another-conversations-vm).

Entering is all a link gives since
[A link lets Max into a VM, and nothing asks across it](links-enter-only.md):
what is said below of asking was so when this was decided.

## Context

Along a link, two Maxes could only trade a question and an answer of at most
2,000 characters (see
[One conversation's Max can ask another's](asking-another-conversation.md)).
Carrying a file, running something in the other conversation, or using its
tools meant asking the other Max to do it, a turn of its model each time,
and saying in words what a file would have said.

A link already exposes all of the asked conversation: its Max answers with
every tool it has, and A's members can try to talk it into anything it can
do. Two facts limit the ways in. VMs don't reach each other: nft rejects
private destinations and drops new connections into the taps. And a guest's
sshd listens only at the VM's vsock port 22, which only the host reaches,
through a socket in the VM's directory.

## Decision

- **The link is the permission.** A→B lets A's Max ask B's and enter B's VM
  as root, in its `/work`, where `maxx` is B's. There is no edge of another
  kind, and `/link`'s answers say both.
- **The way goes through max.** `ssh c9.max` runs `maxx connect`, which asks
  max for an HTTP upgrade on the socket the guest's calls already reach;
  max checks the link, boots B's VM if it isn't running, and copies the
  bytes between the connection and B's sshd.
- **The guest's sshd asks for nothing**: root's password is empty, and sshd
  takes it (OpenSSH's "none" authentication). The way is the gate. No host
  key is checked either.
- **`/unlink` refuses the next connection** and leaves open ones to end by
  themselves.
- **The prompt lists both directions**: whom Max may ask and enter, and who
  may ask and enter it.

## Why

- **One rule.** A link already exposes all of B, so entering its VM gives
  A's members nothing a persuaded B's Max couldn't, and spares the
  roundabout: a file is copied, B's tools are run where they are, and two
  Maxes work in one `/work`.
- **The way through max** checks the link where the links are known, for
  every connection; B needn't be running; nothing in the host's network or
  nft changes; and max knows whose VM asks as it does for every call, by
  the process that made the connection, so no VM speaks for another.
- **Nothing asked**, because only max and what max lets through reach a
  guest's sshd, and on the host only root and max's user can open a VM's
  vsock socket. A check of keys per link would keep no one out, and its
  keys would have to be handed round and kept in step with the links. Nor
  does max keep a key the guest is told of: it logs in as A's ssh does.
- **An upgrade on max's socket**, not a socket of its own: it has how a
  caller is known, and systemd holding connections while max restarts, and
  a refusal can say why.

## Cost

- **An edge is root in B's VM.** A can read B's memory file, its browser's
  logins and its tailnet nodes, and change anything in `/work`, B's units
  among them. A link was already to be made only where exposing B is
  acceptable; now it exposes B's files directly.
- **A guest's sshd is open to whatever reaches its port.** Should a second
  way ever reach it, sshd's TCP listener or taps that reach each other, it
  is open to that too; the design says so where it describes the guest.
- **An open connection outlives `/unlink`** until it closes, and keeps B's
  VM from being stopped as idle: a session left open in a unit of A's keeps
  B running.
- **A restart of max ends every connection**, since they are max's tasks;
  ssh doesn't connect again by itself.

## Alternatives

- **VMs reach each other's sshd over the taps**: no code in max, but B
  must be running, A must know its address, which changes with its slot,
  and either nft lets taps reach each other's port 22 with keys the only
  gate, or max keeps nft rules per link.
- **A tailnet the two Maxes join**: nothing on the host, but the tailnet
  decides who reaches whom, not the link, and both VMs must be running.
- **A key per VM, checked per link**: each guest gives max its key with a
  connection, and B's sshd asks max whose keys to take
  (`AuthorizedKeysCommand`). A route, keys in max's memory and a script,
  for a check the way already makes.
- **max writes B's `authorized_keys`** at each link, unlink, boot and
  attach: many moments to keep in step, and a miss locks A out or lets it
  in.
- **One key every guest has and every sshd takes**: as open as no key,
  with a private key to deliver to every guest.
- **sshd taking any key**, by an `AuthorizedKeysCommand` that hands back
  the key it is offered: as open as no password, with keys made only to be
  offered, a key for each guest at its boot, and a script for sshd, which
  runs a command only from a path root owns.
- **Ending open connections at `/unlink`**: a registry of them per link.
  Links are seldom removed, and an open session could already have done
  what it would do next.
- **`ask` with files**: a narrower way, with its own transfer and limits,
  where the link already allows everything.
- **HTTP CONNECT and `nc -X connect`** in place of the upgrade and `maxx
  connect`: no client of max's own, but axum would take CONNECT outside its
  router, and nc shows a refusal only by its status.
