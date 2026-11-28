# A link lets Max into another conversation's VM, and that is all

A link from A to B lets Max in A enter B's VM as root: `ssh c9.max`, with
`scp` and `sftp`. The way goes through max, which checks the link for
every connection. Nothing else passes between two conversations: no tool
asks B's Max anything, and B has no way to A. The design is in
[Entering another conversation's VM](../design/vm.md#entering-another-conversations-vm).

## Context

Two conversations are isolated: each has its own history, VM and `/work`.
Sometimes Max in one needs another: to carry a file, to run something
where another conversation's tools and logins are, or to read what was
said there.

Three facts shape what a link can be:

- Below a conversation nothing can be enforced: its members share one VM
  as root and one context (see
  [The conversation is the finest grain of permission](permission-by-conversation.md)).
- VMs don't reach each other: nft rejects private destinations and drops
  new connections into the taps.
- A guest's sshd listens only at the VM's vsock port 22, which only the
  host reaches, through a socket in the VM's directory.

## Decision

- **Permission is an edge between conversations**, not a person's, and it
  has a direction: A→B lets Max in A into B's VM, in its `/work`, where
  `maxx` is B's.
- **The entered side redeems the code.** `/link` in A gives a code, and
  `/link <code>` in B makes A→B.
- **A group's owner and the other party of a private chat may link**, as
  well as Max's owners. A group's administrators may not.
- **No derived edges.** Every edge is made by hand.
- **The way goes through max.** `ssh c9.max` runs `maxx connect`, which
  asks max for an HTTP upgrade on the socket the guest's calls already
  reach. max checks the link, boots B's VM if it isn't running, and
  copies the bytes between the connection and B's sshd.
- **The guest's sshd asks for nothing**: root's password is empty, and
  sshd takes it (OpenSSH's "none" authentication). The way is the gate.
  No host key is checked either.
- **`/unlink` refuses the next connection** and leaves open ones to end
  by themselves.
- **Nothing asks across a link.** What Max in A wants to know of B it
  reads there, with `maxx history`; what it wants B's Max to do it says
  with `maxx wake`. The prompt says that `maxx` in a linked
  conversation's VM is that conversation's, and that Max there has no way
  back.
- **A group learns its title from QQ's `info` once, as its actor starts**,
  so that a link can be shown by name.

## Why

- **One rule.** A link is entry to a VM, and what Max can do across it is
  what it can do in that VM. There is no second thing between
  conversations, with rules of its own, to keep in step with it.
- **The exposed side decides.** What an edge exposes is B, all of it.
  A's members see the code, so with B redeeming it, a member can expose
  only a conversation where they may run `/link` themselves.
- **Owners, not administrators.** The people a conversation belongs to
  may open it to another. Administrators keep order in the chat, and a
  link exposes the whole conversation.
- **The way through max** checks the link where the links are known, for
  every connection; B needn't be running; nothing in the host's network
  or nft changes; and max knows whose VM asks as it does for every call,
  by the process that made the connection, so no VM speaks for another.
- **Nothing asked by sshd**, because only max and what max lets through
  reach a guest's sshd, and on the host only root and max's user can open
  a VM's vsock socket. A check of keys per link would keep no one out,
  and its keys would have to be handed round and kept in step with the
  links. Nor does max keep a key the guest is told of: it logs in as A's
  ssh does.
- **An upgrade on max's socket**, not a socket of its own: it has how a
  caller is known, and systemd holding connections while max restarts,
  and a refusal can say why.
- **The host keeps nothing.** No row waits, nothing is counted or timed,
  and neither actor knows of the other: what one conversation tells
  another's Max is a wake like any program's.
- **Reading needs no model.** Most of what one Max wants of another is
  what the other chat said, and `maxx history` there answers that without
  a turn of the other Max.

## Cost

- **An edge is root in B's VM.** A can read B's memory file, its
  browser's logins and its tailnet nodes, and change anything in `/work`,
  B's units among them. A link is made only where exposing all of B is
  acceptable.
- **A guest's sshd is open to whatever reaches its port.** Should a
  second way ever reach it, sshd's TCP listener or taps that reach each
  other, it is open to that too; the design says so where it describes
  the guest.
- **An open connection outlives `/unlink`** until it closes, and keeps
  B's VM from being stopped as idle: a session left open in a unit of A's
  keeps B running.
- **A restart of max ends every connection**, since they are max's
  tasks; ssh doesn't connect again by itself.
- **No answer comes by itself.** Max in A can't have B's Max ask its
  people and hear what they said when they say it, hours or days later:
  it has to look again, in B's history or a file B's Max was asked to
  write, or keep a watcher of its own.
- **A wake in B doesn't say whose it is.** B's Max sees a row tagged
  `max-wake` and the words, as from a program of its own; who asked and
  what for is in the words or nowhere, and the host can't vouch for it.
- **Waking B's Max costs B's VM a boot** if it wasn't running.

## Alternatives

What a link gives:

- **A tool to ask B's Max, and one to answer**: a question of some
  thousand characters put before B's Max, and its answer carried back.
  With entry, asking gives nothing more: `maxx history` and `maxx wake`
  in B's VM do it. What only the tools do is carry an answer back, and
  since what an answer most often waits for is a person, that takes a
  table of questions that wait, two lists in every core's context, a
  number for each question, a cap, an age at which one is dropped and a
  way to tell the asker when `/stop` took what waited. All of it stands
  in for a way from B to A.
- **Asking with files**: a narrower way, with its own transfer and
  limits, where the link already allows everything.
- **Max's owners alone may link**, since what crosses a link can wake the
  entered conversation's Max, a turn they pay for. So does every message
  that wakes Max in a group, and anyone may send one.
- **Derived edges**, such as a person's private chat entering every group
  the person is in. They can't be derived on QQ, where a person's openid
  differs per group and in private chat.

A way back from B to A. None is built; each would let B's Max put words
before A's:

- **A reply right read from the record**: B may wake A while a wake from
  A is less than some days old. Wakes are rows of the ledger (see
  [What wakes Max from outside the chat is a row](wakes-are-rows.md)); it
  needs them to say where they came from, and a `wake` that names another
  conversation.
- **A token A leaves in B**, which wakes A when `maxx wake` is given it:
  A hands the right over, and anything in B's VM that reads it holds it
  until it runs out.
- **Messages both ways along any link.** The simplest rule, and it lets
  anyone in B have B's Max wake A's at will, with words A's model reads,
  where the link A→B exposed only B.
- **A watcher of A's own**: a unit in A's VM that holds an ssh connection
  into B and wakes Max when a file appears there. It needs nothing of the
  host and can be built today; a connection ends whenever max restarts,
  keeps B's VM from stopping when idle, and is A's Max's to set up and
  keep alive.

The way in:

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
  the key it is offered: as open as no password, with keys made only to
  be offered, a key for each guest at its boot, and a script for sshd,
  which runs a command only from a path root owns.
- **Ending open connections at `/unlink`**: a registry of them per link.
  Links are seldom removed, and an open session could already have done
  what it would do next.
- **HTTP CONNECT and `nc -X connect`** in place of the upgrade and `maxx
  connect`: no client of max's own, but axum would take CONNECT outside
  its router, and nc shows a refusal only by its status.
