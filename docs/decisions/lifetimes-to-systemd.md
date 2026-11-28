# What runs in a VM is systemd's to keep

max keeps no state about what runs in a conversation's VM: a call, a
background command, an agent and a resident program are each a unit of
the guest's systemd, and the VMs outlive max. Nearly everything else
stays in max's one process. What runs is in [VMs](../design/vm.md) and
[Jobs](../design/jobs.md).

## Context

Many things live on their own in a conversation: a turn's commands,
commands that run for hours, agents, programs that stay. Kept by the
conversation's actor, each kind needs its creation, number, permission,
state, cancellation, end, limit and tests, and then has to be fitted to
every other kind and to `/kill`, `/stop`, restarts and failures: what
becomes of an agent's question when the agent is cancelled, of a
command's token when it moves to the background, of an answer whose turn
has ended. An actor that keeps them supervises processes in a VM that has
a supervisor of its own.

## Decision

Whatever runs in a VM is a systemd unit in the guest: systemd starts it,
names it, limits it, stops it and notices its end. max keeps no state of
it; when max starts, it attaches to the VMs that run and asks. The host
keeps primitives only, few enough that its actor and its lifetimes can be
taken in at a glance. A feature may add a primitive, and may not add a
lifetime to the actor.

What the host knows:

- **A conversation:** its ledger, and at most one turn that runs.
- **A VM:** one for a conversation. The host knows whether it runs, on
  which slot, and whether it says it is busy.
- **A call:** one of the model's tool calls, which is a unit in the VM
  that the turn waits for. `shell` and `run_code` are the same thing with
  different commands.
- **A link:** an edge from one conversation to another.

Everything in a VM is one caller: a turn's program, a background command,
an agent and a resident program are not told apart, and none has a token.
It can ask the host for four things:

- **To read:** the history and its searches, the stickers, `/events`, a
  file of the chat's record.
- **To act:** say something, send a picture or a file, take a message
  back, mute someone. Each is committed to the ledger before it is sent,
  and `/stop` refuses them.
- **To wake Max:** put some words before the model, in the turn that runs
  or a new one.
- **To spend:** `/llm`, `/api` and `web_search`, where the host adds the
  key.

The host does three things to a VM: it starts a unit and waits for it, it
stops a unit or all of them, and it boots or stops the VM itself. A
person has `/kill`, `/stop` and `/start`.

These are all the lifetimes the host has: the process; a conversation's
actor, from its first event until max stops; a turn, whose `io` scope
holds its model calls and its calls; the tasks in `side`, each bounded
(the classifier, a caller's request, a lookup); and a VM, which is a unit
of the host's systemd that max attaches to.

Whose each task is:

| Task | Whose |
| --- | --- |
| A VM's processes: start, end, logs, cgroup | the host's `maxx-vm@.service` |
| Who calls a tool | the VM |
| Starting and naming a command | a unit, and its name |
| Time limits | `RuntimeMaxSec=` |
| Stopping one | `systemctl stop` |
| What runs | `systemctl`, and each unit's output file |
| Telling Max of an end | the unit's `ExecStopPost=` starts `max-notify@`, which tells max until it is taken |
| A command's output | written by the unit |
| A picture for the model | travels with the call's line |
| "Tell me if nothing came by then" | a timer unit that wakes Max, if Max sets one |
| Dropping an idle guest's caches | a timer in the guest |

Choices made with it:

- **`/llm` takes any call from a VM's socket.** Anything in the VM can
  spend on any configured model, as a program can start agents and search
  without limit.
- **A call or a command is what it is from its start.** A call is waited
  for until it ends or its limit ends it; a background command is not
  waited for, and Max is told when it ends. Nothing moves from one to the
  other.
- **One caller.** What a turn's tools say and send is marked in the
  record as a program's is, and nothing tells the two apart afterwards.
- **An agent is a program.** It calls Max's tools with `maxx`, every one
  of them, and only its prompt keeps it from speaking in the chat.

## Why

- **The guest has a supervisor already**, which does all of this for any
  unit, and which the model knows how to ask (`systemctl`).
- **A kind of thing that runs is a unit file, not a lifetime.** Nothing
  new has to be fitted to `/kill`, `/stop`, restarts and failures: those
  stop units.
- **A deploy of max ends nothing in a VM.** max restarts several times a
  day while it is worked on, and agents run for hours.
- **Resident programs cost the host the least** of all that runs, and
  work this way: a directory is the registry, with no table and no tool.

## What it rests on in systemd

- A transient unit takes `ExecStopPost=`, and it sees how the unit ended:
  `success exited 0`, `exit-code exited 3`, `timeout killed TERM` at
  `RuntimeMaxSec=`, `success killed TERM` after `systemctl stop`.
- A oneshot with `Restart=on-failure`, `RestartSteps=` and
  `RestartMaxDelaySec=` is tried again until it succeeds, and stays
  `activating` meanwhile.
- From a service hardened as `maxx.service` is (`PrivateUsers=true` and
  the rest), max's user starts a `maxx-vm@` instance once a polkit rule
  allows it those units, and is refused another unit.
- A link max's user makes under
  `/nix/var/nix/gcroots/per-user/<user>/` is a root of the garbage
  collector's.

## Cost

- A command someone waits on doesn't move to the background: a call runs
  to its end or its limit.
- What a turn's tools say and send is a program's row, and no turn's.
- `/status` lists no jobs, and `/kill` doesn't list what it stopped: the
  guest's systemd is where they are listed.
- Nothing limits how many commands run at once.
- Anything in a VM can call the agents' model.
- A call a turn was waiting for ends with the turn.
- Outliving max is something the host does for the VMs: attaching to
  those that run, and stopping the ones it can't use.

## What stays in max

With the long run in mind: which parts of max are worth a process of
their own, or could move into a conversation's VM. What a restart of max
loses for good is the turn that runs, after the grace it is given, and
the call it was making. What a guest asks while max is away waits at
max's socket; `/events` is opened again; the VMs and what runs in them
run on.

- **Stays in max:**
  - *The tools' service.* Every call goes through the conversation's
    actor, and most of the tools need it: to say something, to change a
    setting, to wake, and for a mute's permission. A process of its own
    would need a second channel that mirrors the first.
  - *History and search.* The database has the other conversations'
    rows.
  - *The VMs' lifecycle.* It holds the SSH connections the calls run on,
    and a guest isn't trusted to stop itself.
  - *The chat's adapter.* A restart costs it next to nothing: the gateway
    resumes, and the sender drains.
  - *Intent.* It is what triggers a turn and what caps the spending, and
    what lets a VM sleep.
  - *The commands.* `/kill` and `/stop` must work when the VM or the
    model doesn't.
  - *The models' calls and the keyed APIs'* from a VM. See
    [A guest's calls come straight to max](guests-reach-max-directly.md).
- **The workers** (download, caption) could be a process of their own,
  and what that would buy is isolation: the decoding of the chat's
  pictures away from the process that holds the keys. It buys no quieter
  deploy, since every process comes from one package and restarts with
  it.
- **`web_search`** could leave the host altogether, as one more keyed
  API.
- **A turn's loop in the guest**, assembling its own context, with the
  host keeping the chat's connection, the ledger, the keys and intent, is
  the one thing that would make a deploy cost a conversation nothing. It
  isn't designed. What it lacks: what a turn says with `say` is a
  program's row, of no turn; the records of a turn and its usage are the
  actor's to write; a wake has one taker, the actor's core; its model
  calls would have to outlive max; and every turn would need a VM that
  runs, where one that calls no tool boots none, 4.5 to 10 seconds on a
  cold reply. The timeline as data for a program
  ([Rows as data](../design/jobs.md#rows-as-data)) is the first thing it
  needs, and is there.

## Alternatives

- **The actor keeps what runs**: a table of jobs with numbers (`agent#3`,
  `shell#4`), a session and a token for each caller, timers for the
  limits, and tools to list and cancel. See Context.
- **VMs that end with max**, the VM's unit a part of max's: nothing to
  attach to, and every restart of max ends agents that run for hours.
