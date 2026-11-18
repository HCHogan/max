# max's socket is systemd's

The socket the VMs' forwarders reach max at belongs to systemd, which
listens there whether max runs or not. What a guest asks while max restarts
waits at the socket and is answered by the max that comes; nothing in a
guest retries. What runs is under
[A VM outlives max](../design/vm.md#a-vm-outlives-max) and
[A guest's calls reach max](../design/vm.md#a-guests-calls-reach-max).

The forwarders are gone since
([A guest's calls come straight to max](guests-reach-max-directly.md)):
each VM's port for the host is a link to this socket, cloud-hypervisor is
what closes a connection whose caller went, and a guest that finds nothing
listening has its connection closed, where a forwarder answered
`unreachable`. The rest stands.

## Context

A VM outlives max, and so does what runs in it: a resident program, a
background command or an agent may call one of Max's tools at any moment,
including the tens of seconds in which max restarts at a deploy.

Until now that gap was bridged by a protocol of max's own, in five places.
A forwarder that found nothing listening answered its guest 503 with a
`max-away` header; max answered the same for a call that came once it had
begun to stop; the guest's own port forwarder said it too when no forwarder
listened; and the guest's client read the header and made the call again,
with growing waits, for up to three minutes. The distinction it carried,
"nothing of your request was read, ask again", is one a listening socket
makes for free: a connection that waits to be taken has been read by nobody.

max listened at a socket in each VM's directory, bound when it attached.
systemd can hold a socket only at a path its unit names, so first the
forwarders were given one socket to reach max at, each naming its VM's
conversation in a header.

## Decision

- `maxx.socket` listens at `<vm.dir>/max.sock`, and max's unit takes it as
  its standard input (`StandardInput=socket`), which takes no `unsafe` to
  turn into a listener. systemd sets no `LISTEN_FDS` for a socket it gives
  so: max knows it by what it is, a Unix socket bound at that path. Without
  a socket given, as under vm-check or in a terminal, max binds one itself.
- A deploy restarts max in one step (`stopIfChanged = false`), which leaves
  the socket. NixOS otherwise stops a changed unit that has a socket
  together with its socket, and leaves the unit for the socket to start.
- As max begins to stop, it takes no more from the socket. What it has
  taken goes on until its conversation stops.
- Of each connection it takes, max asks before reading anything whether its
  other end has hung up, and drops one that has.
- `max-away` is gone from the forwarder, max, the guest's port forwarder and
  the guest's client. A forwarder that can reach nothing answers a failed
  call, `unreachable`: max is stopped, not restarting.

## Why the check for a caller that left

A request that waits at the socket outlives the program that made it. A
turn that the restart cuts off takes its program with it, while the request
that program had waiting, a `say` perhaps, is still there to read when max
is back, and would be carried out for nobody. Retrying never had this: only
a caller that is still there asks again.

The kernel knows which those are. The forwarder closes its connection to
max when its guest's caller goes, and a connection whose other end has
closed says so (`POLLHUP`) while its request is still unread. A connection
that hangs up after max has taken it is dropped as any call is whose caller
closes.

Clearing the socket whenever max stops (`FlushPending=`) was the other way.
It would drop the requests of the callers that still wait as well, which
are what the socket holds them for.

## Cost

- With max's unit alone stopped, the socket still listens, and the next
  thing a guest asks starts max again. To keep max down, its socket is
  stopped with it, or the target.
- A call made while max is down for long waits for as long as its caller
  does, where the client used to give up after three minutes.
- A call max took in the moment before it began to stop, and that no actor
  had begun, is answered `closed` like one cut off in the middle, though
  nothing came of it.
- The forwarders that run when this is deployed still say `max-away`, which
  the guest's client no longer reads, and look for max where it no longer
  listens: the contract's number went up, and their VMs boot again.
