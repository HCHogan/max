# A guest's calls come straight to max

Nothing stands between a guest and max: each VM's port for the host is a
link to the one socket max listens at, max tells whose VM a call is from by
the process that made its connection, and it answers the models' calls and
the keyed APIs' itself. What runs is in
[A guest's calls reach max](../design/vm.md#a-guests-calls-reach-max).

## Context

Each VM had a forwarder, a process of its own beside the VM's unit, which
outlived max as the VM does ([what leaves the host](what-leaves-the-host.md)).
It answered `/llm` and `/api` itself, so that a deploy cut no model call an
agent was in the middle of, and passed everything else on to max with a
header that named its VM's conversation.

Then max's socket became systemd's
([max's socket is systemd's](max-socket-is-systemds.md)), and what a guest
asks while max restarts waits there. That left the forwarder one thing to
protect: a call in flight at the moment max restarts.

- max restarted about three times a day. The agents' model calls, while
  they were still timed, were in flight for 0.6% to 3.4% of a day, 1.9% on
  average. At that rate a restart cuts a call about once in two weeks, more
  often in so far as deploys and agents share the daytime, and pi tries a
  failed call again by itself.
- The forwarder cost more than that. It was as old as its VM's boot, so
  three generations of code spoke to each other, the guest's, the
  forwarder's and max's, and the configuration could only grow in ways an
  older forwarder could read. The contract's number was raised three times
  in three days for the forwarder and what it said to max, and each booted
  every VM again.
- It was a reverse proxy written again, with a link to the configuration
  that it looked at every two seconds.

## Decision

- `notify.vsock_7777` in a VM's directory, where cloud-hypervisor connects
  when the guest connects to the host's port, is a link to `max.sock`,
  which max makes when it boots the VM. systemd's socket, and max's taking
  of it, are as they were.
- The conversation a call belongs to is the one whose VM made the
  connection: max reads the pid at the other end and asks systemd which
  unit it is of (`systemctl whoami`). The header is gone.
- `/llm` and `/api` are routes of max's service again. An API's `per_hour`
  is all the chats' together, in max's memory.
- The forwarder, its unit, `max forward`, the link to the configuration
  and the part of the configuration read through it are gone. The contract
  went up once more, and the VMs booted again.

## Alternatives

- **A socket unit for each VM**, in the VM's directory. systemd refuses to
  start a socket whose service already runs, and a VM boots while max
  runs.
- **A socket for each slot**, all listed in one unit, 36 by default. To
  be given more than one socket takes `LISTEN_FDS`, and with it `unsafe`
  or a dependency, and max would have to know which conversation holds a
  slot before it took the first connection.
- **Reading `/proc/<pid>/cgroup`** for the unit. max and a VM's unit each
  have a user namespace of their own, and under `ProtectProc=invisible`
  neither sees the other's processes. Asking systemd costs a process and a
  few milliseconds for each connection.
- **A hard link** to the socket in place of the symlink, should Landlock
  ever keep cloud-hypervisor from a socket outside its VM's directory. It
  would go stale when systemd made the socket again.

## Cost

- A model's or a keyed API's call in flight when max restarts is cut off.
  pi tries again; a `git push` through `/api` fails, and is run again by
  whoever ran it.
- max asks systemd once for every connection it takes, one after another:
  a few milliseconds each.
- A guest's kept-alive connection now ends at max. One that max closes as
  a request is written on it fails a call max never read.
- A call cut off by a max that died, with no time to answer `closed`, is
  to its guest a connection that closed, the same as when nothing listens:
  the guest's client says it may have acted either way.
- A turn's loop in the guest, the second step of
  [what leaves the host](what-leaves-the-host.md), would need a forwarder
  again.
