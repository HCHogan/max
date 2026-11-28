# A guest's calls come straight to max, over plain HTTP

Programs in a VM call Max's tools over plain HTTP, and every caller in a
VM is the same caller. Nothing stands between a guest and max: each VM's
port for the host is a link to one socket, which systemd holds for max,
and max tells whose VM a call is from by the process that made its
connection. max answers the models' calls and the keyed APIs' there too,
and keeps no count of the models'. The design is in
[The guest's calls](../design/tools.md#the-guests-calls),
[A guest's calls reach max](../design/vm.md#a-guests-calls-reach-max) and
[A VM outlives max](../design/vm.md#a-vm-outlives-max).

## Context

- What calls the host from a VM is a turn's program, a background
  command, an agent or a resident program. Both ends are Max's and come
  from one build.
- Everything in a VM runs as root. A token given to one program can be
  read, or left out, by any other.
- A VM outlives max, and so does what runs in it: a call may come at any
  moment, including the tens of seconds in which max restarts at a
  deploy, about three times a day.
- An agent's model calls and a program's calls to a keyed API go through
  the host as well, which adds the key.

## Decision

- **Plain HTTP.** `GET /tools` lists the tools and `POST /tools/<name>`
  calls one. The answer is the call's outcome with status 200, and 400
  for arguments that aren't an object. A closed connection cancels the
  call.
- **One caller.** A call is the VM's, run by the conversation's actor.
  Nothing tells a turn's program from any other caller, and none has a
  session or a token.
- **One socket, linked from every VM.** `notify.vsock_7777` in a VM's
  directory, where cloud-hypervisor connects when the guest connects to
  the host's port, is a link to `max.sock`, which max makes when it boots
  the VM.
- **Whose VM a call is from is the process's that made the connection.**
  max reads the pid at the other end and asks systemd which unit it is of
  (`systemctl whoami`).
- **The socket is systemd's.** `maxx.socket` listens at
  `<vm.dir>/max.sock` whether max runs or not, and max's unit takes it as
  its standard input (`StandardInput=socket`). A deploy restarts max in
  one step (`stopIfChanged = false`), which leaves the socket. What a
  guest asks meanwhile waits there and is answered by the max that comes;
  nothing in a guest retries.
- **As max begins to stop, it takes no more from the socket.** What it
  has taken goes on until its conversation stops.
- **A caller that left isn't answered.** Of each connection it takes, max
  asks before reading anything whether its other end has hung up, and
  drops one that has.
- **`/llm` and `/api` are routes of max's service.** An API's `per_hour`
  is all the chats' together, counted in max's memory.
- **A model call from a VM isn't counted.** max gives it the provider's
  key, puts the model's id in its place and passes the answer back as it
  comes. `/status` shows what Max's own calls used.

## Why

Plain HTTP:

- A protocol such as MCP is for calling what somebody else wrote, and
  both ends here are Max's. The only client comes from the same build,
  and what a third party would need, the tools declared once with their
  schemas, isn't in the wire. A page speaking MCP can be put in front of
  the same table if another client ever wants one.

One caller:

- A token names a run and grants nothing: everything in the VM is root
  and could leave it out, so a call without one has to be taken anyway.
  Refusing an unknown token keeps nothing out, and refuses a command that
  outlived its turn.
- With one caller there is no table of who may call what to keep, and
  nothing of a run for max to hold between its calls.

No process between a guest and max:

- A process for each VM that passes calls on is as old as its VM's boot,
  so three ages of code speak to each other, the guest's, that process's
  and max's, and the configuration can only grow in ways the oldest can
  read.
- All it protects is a call in flight when max restarts. An agent's model
  calls are in flight for about 2% of a day, so a restart cuts one about
  once in two weeks, and the agents' harness tries a failed call again by
  itself.
- It is a reverse proxy written again.

The socket is systemd's:

- "Nothing of your request was read, ask again" is a distinction a
  listening socket makes for free: a connection that waits to be taken
  has been read by nobody. A protocol of max's own for it, a status and a
  header that the guest's client reads and retries on, has to be spoken
  in every place a call passes through.
- A request that waits at the socket outlives the program that made it. A
  turn that the restart cuts off takes its program with it, while the
  request that program had waiting, a `say` perhaps, is still there to
  read when max is back, and would be carried out for nobody. The kernel
  knows which those are: a connection whose other end has closed says so
  (`POLLHUP`) while its request is still unread. cloud-hypervisor closes
  a guest's connection when the guest's caller goes.

No count of the models' calls:

- The upstream counts them: the provider's records have every call, for
  all the groups together.
- Counting by conversation means reading every answer on its way back for
  what it used and writing a row for it, code that nothing else needs.
- `per_hour` isn't a statistic but a guard: a key the VM never sees can
  still be used by anyone who can have Max run a command. So it stays,
  and with one process there is nothing to share to count it.

## Cost

- A model's or a keyed API's call in flight when max restarts is cut off.
  The agents' harness tries again; a `git push` through `/api` fails, and
  is run again by whoever ran it.
- A call max took in the moment before it began to stop, and that no
  actor had begun, is answered `closed` like one cut off in the middle,
  though nothing came of it.
- A call cut off by a max that died, with no time to answer `closed`, is
  to its guest a connection that closed, the same as when nothing
  listens: the guest's client says it may have acted either way.
- A guest's kept-alive connection ends at max. One that max closes as a
  request is written on it fails a call max never read.
- A call made while max is down for long waits for as long as its caller
  does.
- With max's unit alone stopped, the socket still listens, and the next
  thing a guest asks starts max again. To keep max down, its socket is
  stopped with it, or the target.
- max asks systemd once for every connection it takes, one after another:
  a process and a few milliseconds each.
- `/status` doesn't include what a conversation's background agents
  used, which for a group that runs agents is likely most of what it
  spends.
- An API's count starts over with max: more than `per_hour` can be had in
  an hour that a restart falls in. And the hour is shared, so one busy
  chat can use it up for the others.
- A turn's loop in the guest, should one be built (see
  [What runs in a VM is systemd's to keep](lifetimes-to-systemd.md)),
  would need its model calls to outlive max, and so a process between
  them again.

## Alternatives

The protocol and the caller:

- **MCP**, stateless, with JSON replies. With a library for it (rmcp),
  only a small slice is used while its sessions have to be turned off,
  HTTP headers dug out of extensions and its logs suppressed; in-house,
  it is a page of code for an envelope, ids, `ping`, notifications,
  protocol headers and `structuredContent` beside a copy of itself as
  text, none of which carries anything here.
- **A session for each run**, with a token: it can count a program's
  calls, keep the pictures it showed and make what it says the turn's
  own. It needs a table of who may call what, and gives no wall, as
  above. Pictures travel with the call's line instead.

Between a guest and max:

- **A forwarder for each VM**, a process beside the VM's unit that
  outlives max and answers `/llm` and `/api` itself, so that a deploy
  cuts no model call. See Why.
- **The guest's client retrying over the gap**, on a 503 with a header of
  max's own, with growing waits. See Why. It gives up after a few
  minutes, where a socket holds a call for as long as its caller waits.
- **Clearing the socket whenever max stops** (`FlushPending=`), in place
  of the check for a caller that left. It would drop the requests of the
  callers that still wait as well, which are what the socket holds them
  for.
- **A socket unit for each VM**, in the VM's directory. systemd refuses
  to start a socket whose service already runs, and a VM boots while max
  runs.
- **A socket for each slot**, all listed in one unit. To be given more
  than one socket takes `LISTEN_FDS`, and with it `unsafe` or a
  dependency, and max would have to know which conversation holds a slot
  before it took the first connection.
- **A header that names the conversation**, set by whatever passes the
  call on: it needs something trusted between the guest and max to set
  it.
- **Reading `/proc/<pid>/cgroup`** for the unit. max and a VM's unit each
  have a user namespace of their own, and under `ProtectProc=invisible`
  neither sees the other's processes.
- **A hard link** to the socket in place of the symlink, should Landlock
  ever keep cloud-hypervisor from a socket outside its VM's directory. It
  would go stale when systemd made the socket again.

Counting:

- **A gateway in front of the providers that counts by group.**
  CLIProxyAPI, the gateway in front of some of tank's providers, keeps no
  totals by its documentation, and publishes a record for each request to
  a queue that something of Max's would have to drain and store, which is
  the same code in another place.
- **`per_hour` for each chat.** A key would then be good for `per_hour`
  calls from every chat: tank's Bungie key allows 1,000 an hour in all,
  which two busy chats at 1,000 each would overrun.
