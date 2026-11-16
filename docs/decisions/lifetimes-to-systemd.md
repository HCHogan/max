# What runs in a VM is systemd's to keep

max keeps no state about what runs in a group's VM: a call, a background
command, an agent and a resident program are each a unit of the guest's
systemd, and the VMs outlive max. What runs now is in [VMs](../design/vm.md)
and [Jobs](../design/jobs.md). The guest's commands named here, `max-jobs`,
`max-agent`, `max-units` and `max-wake`, have since become `maxx units` and
`maxx agent`; see "One command" under
[Pure codemode](../design/tools.md#pure-codemode). The five steps it was
built in are kept as history in
[archive/lifetimes-to-systemd-steps.md](../archive/lifetimes-to-systemd-steps.md).

## Context

A conversation's actor had come to keep a turn, background agents, background commands, commands moving from the foreground to the background, questions waiting in both directions and the calls of resident programs. Each new kind of thing that lives on its own needed its creation, number, permission, state, cancellation, end, limit and tests, and then had to be fitted to every other kind and to `/kill`, `/stop`, restarts and failures: what becomes of an agent's question when the agent is cancelled, of a command's token when it moves, of an answer whose turn has ended. Of the twenty files changed most in the week before, seventeen were this code. The actor was supervising processes in a VM that has a supervisor of its own. Resident programs had gone the other way ("this directory is the registry: there is no table and no tool") and cost the host the least.

## Decision

max keeps no state about what runs in a VM. Whatever runs there is a systemd unit in the guest: systemd starts it, names it, limits it, stops it and notices its end. When max starts, it attaches to the VMs that run and asks. The host keeps primitives only, few enough that its actor and its lifetimes can be taken in at a glance; a feature may add a primitive, and may not add a lifetime to the actor. Behaviour needn't stay as it is where the difference buys a simpler host: what changes is listed at the end.

## What the host knows

- **A conversation:** its ledger, and at most one turn that runs.
- **A VM:** one for a conversation. The host knows whether it runs, on which slot, and whether it says it is busy.
- **A call:** one of the model's tool calls, which is a unit in the VM that the turn waits for. `shell` and `run_code` are the same thing with different commands.
- **A link:** an edge from one conversation to another.

Everything in a VM is one caller: a turn's program, a background command, an agent and a resident program are not told apart, and none has a token. It can ask the host for four things:

- **To read:** the history and its searches, the stickers, `/events`, a file of the chat's record.
- **To act:** say something, send a picture or a file, take a message back, mute someone. Each is committed to the ledger before it is sent, and `/stop` refuses them.
- **To wake Max:** put some words before the model, in the turn that runs or a new one. Asking another conversation's Max, and answering one, are wakes over a link.
- **To spend:** `/llm`, `/api` and `web_search`, where the host adds the key and records the use.

The host does three things to a VM: it starts a unit and waits for it, it stops a unit or all of them, and it boots, stops or switches the VM itself. A person has `/kill`, `/stop` and `/start`.

These are all the lifetimes the host has: the process; a conversation's actor, from its first event until max stops; a turn, whose `io` scope holds its model calls and its calls; the tasks in `side`, each bounded (the classifier, a caller's request, a lookup); and a VM, which is a unit of the host's systemd that max attaches to.

| Task | Today | Then |
| --- | --- | --- |
| A VM's processes: start, end, logs, cgroup | max's children, `kill_on_drop` (`vm/machine.rs`) | the host's `maxx-vm@.service` |
| Who calls a tool | a session by token: a turn's, a job's, a program's, vm-check's (`mcp::Caller`) | the VM |
| Starting and naming a command or an agent | the actor's job table, `agent#N`, `shell#N` | a unit, and its name |
| Time limits | `RUN_TIME`, `JOB_TIME`, `BACKGROUND_TIME`, timers in max | `RuntimeMaxSec=` |
| Stopping one | `cancel`, dropping its scope, the stopper | `systemctl stop` |
| What runs | `status`, `job::Progress` | `systemctl`, the output file, pi's session log |
| Telling Max of an end | `Event::JobDone`, `Notice::Ended` | the unit's `ExecStopPost=` starts `max-notify@`, which calls `maxx wake` until it is taken |
| A command's output | read from the SSH channel; a long one written by the host (`tools::Output`) | written by the unit |
| A picture for the model | a request of the run's session (`max.image`) | a path the call leaves in its directory |
| Steers | the queue in `job::drive`, `/job/turn` | files in the agent's runtime directory, read at `turn_end` |
| The wrap-up before the deadline | a timer in `drive` | a timer in the plugin |
| The report and the notes | `/job/report`; the host reads the notes and saves the report | the plugin writes the report; `max-pi` reads the notes |
| An agent's question, and the hold for its answer | `ask`, `Asked`, `AgentWaits`, `job::Open`, a held `/job/turn` | the question is a wake, the answer a steer; the plugin waits on its inbox |
| "Tell me if nothing came by then" | `ASK_WAIT` in a job's task | a timer unit that wakes Max, if Max sets one |
| Dropping an idle guest's caches | `Running::trim`, over SSH | a timer in the guest |

## Choices made with it

- **`/llm` takes any call from a VM's socket.** The socket says which conversation pays. Anything in the VM can spend on the job model, as a program can already start agents and search without limit. It is any configured model, since Max chooses an agent's: see **Max chooses an agent's model** under [Background agents](../design/jobs.md#background-agents).
- **A call or a command is what it is from its start.** A call is waited for until it ends or its limit ends it; a background command is not waited for, and Max is told when it ends. Nothing moves from one to the other: a command someone waited on used to move to the background, and no longer does.
- **One caller.** What a turn's tools say and send is marked in the record as a program's is, and nothing tells the two apart afterwards.
- **An agent is a program.** It calls Max's tools with `maxx`, every one of them, and only its prompt keeps it from speaking in the chat. The tools marked `job` were never a wall.
- **A running VM moves to a new image without stopping, where it can.** The contract is a number the guest's build writes. When max attaches to a VM booted with another number, it restarts that VM at once. One with the same number but an older image is switched where it runs, with `switch-to-configuration` in the guest, and its jobs and resident programs run on. Only if the kernel or the initrd changed too is it then restarted, once it has no job and nobody has used it for a while, so that a VM kept on for its units gets them as well.
- **A client retries over the gap.** While max restarts, a call from a guest is refused for some tens of seconds; `client.js` tries again. No file descriptor store.
- **A link stays one way.** A→B lets A's Max ask B's. B answers through the record of a question it was asked, once, not through an edge back.

## What was verified first

Tried before anything was built. 1, 2, 3, 5, 7 and 8 ran in a NixOS test on the pinned nixpkgs, in a machine set up as the guest is (nixos-init, an overlaid `/etc`, userborn, the guest's `DefaultEnvironment`; systemd 260.5, which is also the guest's on tank) and with a service hardened as `maxx.service` is. 6 ran the pinned pi 1.5.0 against a fake `/llm`. The test's pieces went into the jobs test.

1. **Holds.** A transient unit takes `ExecStopPost=`, and it sees how the unit ended: `success exited 0`, `exit-code exited 3`, `timeout killed TERM` at `RuntimeMaxSec=`, `success killed TERM` after `systemctl stop`.
2. **Holds.** A oneshot with `Restart=on-failure`, `RestartSteps=` and `RestartMaxDelaySec=` is tried again until it succeeds, and stays `activating` meanwhile.
3. **Holds.** From a service hardened as `maxx.service` is (`PrivateUsers=true` and the rest), max's user starts a `maxx-vm@`-like instance once a polkit rule allows it those units, and is refused another unit.
4. **Holds** (tried with step 2, in the nested test on tank). A guest's connections reach an MCP listener bound again at `notify.vsock_7777` by the max that attaches, and SSH connects again with the key the boot saved: a unit in the guest that asked the VM service every second got 200, then 503 from the guest's forwarder while max was away, then 200 again, in the same boot of the same VM.
5. **Holds.** With `restartIfChanged = false` on the template, `switch-to-configuration` says "NOT restarting the following changed units" and the instance keeps its process; the next instance is the new template's.
6. **Half.** On SIGTERM pi exits at once, with status 143, before `agent_settled`: no report. On SIGUSR2 (and SIGINT) the plugin's handler aborts the run, `agent_settled` runs, the report is written, and pi exits within 30 ms. So the agent's unit has `KillSignal=SIGUSR2`. pi's own retries of a model call, 3 by default at 2, 4 and 8 seconds, don't outlast 20 seconds without the host; with `retry.maxRetries` 8 in `settings.json` they do. A steer read from a directory at `turn_end` goes into the next model call.
7. **Holds**, in the test machine and then in a guest (with step 2, in the nested test on tank). `switch-to-configuration test` remounts `/etc`, restarts an unmarked unit that changed, and leaves a job that runs through it. The guest's system deployed on tank has `bin/switch-to-configuration`, and its only switch inhibitor is the dbus implementation. In the nested test a deploy brought a second image, and a real guest, with its store overlay and its registration, was switched to it in the same boot, a unit of Max's running through.
8. **Holds.** A link max's user makes under `/nix/var/nix/gcroots/per-user/<user>/` is a root. On tank that directory is root's and empty, so the module makes max's; and tank collects weekly (`nix-gc.timer`), so the root is needed.

## What it bought

The files that went whole are counted, the rest estimated, roughly. Eight files go whole (`actor/jobs.rs`, `job.rs`, `job/run.rs`, `mcp/harness.rs`, `mcp/agent.rs`, `mcp/jobs.rs`, `tools/background.rs`, `tools/output.rs`), 2,136 lines, with three files of their tests, 809. In all the host loses about 3,700 lines outside tests and gains about 600 (attaching, the older image, a call's line, an answer's way back): some 3,100 fewer of 30,567, a tenth. Step 2 adds to the host, since outliving max is something new. The guest gains two commands, three units, a timer and a slice: about 450 lines of shell, TypeScript and Nix, and a NixOS test. Max has 13 tools for 16.

## What changes for the group and for Max

- A command someone waits on no longer moves to the background; a call runs to its end or its limit.
- `agent`, `agent_steer`, `cancel` and `status` are commands in the VM (`max-agent`, `max-jobs`, `systemctl`), and a job is known by its unit's name, not `agent#3` or `shell#4`.
- A job's notice is a wake, at most 4,000 characters (`mcp/program.rs`), with the end of the output and the file's path, where `Notice::Ended` showed 16 KiB.
- What a turn's tools say and send is marked `程序发的`, and its row is no turn's. A result no longer ends with the tools its program called.
- A picture that can't be shown is reported in the call's result, not to the program, unless its path is no file. `max.image` returns `{path}`, not the picture's size.
- `max.file(handle)` is `tools.file({handle})`.
- An agent can call every tool, and is told of them in its prompt, not through MCP.
- `/status` lists no jobs, and `/kill` doesn't list what it stopped.
- A question is answered in the turn that read it, or the asker hears that it wasn't; `[等你回答的问题]` is gone. Max can't decline one: it answers that it won't say. `cancel` and `status` are gone, and a question Max asked has no number on its side.
- `commands_at_once` and the limit of 8 commands go; three agents at once is `max-agent`'s to count.
- An agent's number goes on across restarts and boots (`max-agent-12`), and its question has none: Max answers it with `max-agent steer`.
- Anything in a VM can call the agents' model.
- A restart of max stops no background command, agent or program. A call a turn was waiting for ends with the turn.
