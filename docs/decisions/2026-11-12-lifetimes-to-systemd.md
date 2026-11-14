# Lifetimes move to systemd

The guest's commands this section names, `max-jobs`, `max-agent`, `max-units` and `max-wake`, are `maxx units` and `maxx agent` since 2026-11-14; see "One command" under [Pure codemode](../design/tools.md#pure-codemode). The steps below are as they were planned and landed.

Decided 2026-11-12 with the owner, who proposed letting the VMs outlive max and switching a running guest to a new image. All five steps landed on 2026-11-12, and what runs now is in [VMs](../design/vm.md) and [Jobs](../design/jobs.md); this is the decision as it was made, what was checked before it, and each step as it was planned, with where it landed otherwise.

**Why.** By 2026-11-11 a conversation's actor kept a turn, background agents, background commands, commands moving from the foreground to the background, questions waiting in both directions and the calls of resident programs. Each new kind of thing that lives on its own needed its creation, number, permission, state, cancellation, end, limit and tests, and then had to be fitted to every other kind and to `/kill`, `/stop`, restarts and failures: what becomes of an agent's question when the agent is cancelled, of a command's token when it moves, of an answer whose turn has ended. Of the twenty files changed most from 2026-11-06 to 2026-11-12, seventeen were this code. The actor was supervising processes in a VM that has a supervisor of its own. Resident programs had gone the other way ("this directory is the registry: there is no table and no tool") and cost the host the least.

**The rule.** max keeps no state about what runs in a VM. Whatever runs there is a systemd unit in the guest: systemd starts it, names it, limits it, stops it and notices its end. When max starts, it attaches to the VMs that run and asks. The host keeps primitives only, few enough that its actor and its lifetimes can be taken in at a glance (the owner, 2026-11-12); a feature may add a primitive, and may not add a lifetime to the actor. Behaviour needn't stay as it is where the difference buys a simpler host: what changes is listed at the end.

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

## Decided

The owner, 2026-11-12:

- **`/llm` takes any call from a VM's socket.** The socket says which conversation pays. Anything in the VM can spend on the job model, as a program can already start agents and search without limit (2026-11-05). Later that day it became any configured model, when Max was let choose an agent's: see **Max chooses an agent's model** under [Background agents](../design/jobs.md#background-agents).
- **A call or a command is what it is from its start.** A call is waited for until it ends or its limit ends it; a background command is not waited for, and Max is told when it ends. Nothing moves from one to the other: the move of 2026-11-08, for a command someone waits on, goes.
- **One caller.** What a turn's tools say and send is marked in the record as a program's is, and nothing tells the two apart afterwards.
- **An agent is a program.** It calls Max's tools with `maxx`, every one of them, and only its prompt keeps it from speaking in the chat. The tools marked `job` were never a wall.
- **A running VM moves to a new image without stopping, where it can.** The contract is a number the guest's build writes (see step 2). When max attaches to a VM booted with another number, it restarts that VM at once. One with the same number but an older image is switched where it runs, with `switch-to-configuration` in the guest, and its jobs and resident programs run on. Only if the kernel or the initrd changed too is it then restarted, once it has no job and nobody has used it for a while, so that a VM kept on for its units gets them as well.
- **A client retries over the gap.** While max restarts, a call from a guest is refused for some tens of seconds; `client.js` tries again. No file descriptor store.
- **A link stays one way.** A→B lets A's Max ask B's. B answers through the record of a question it was asked, once (see step 5), not through an edge back.

## Checked first

Tried 2026-11-12, before any step. 1, 2, 3, 5, 7 and 8 ran in a NixOS test on the pinned nixpkgs, in a machine set up as the guest is (nixos-init, an overlaid `/etc`, userborn, the guest's `DefaultEnvironment`; systemd 260.5, which is also the guest's on tank) and with a service hardened as `maxx.service` is. 6 ran the pinned pi 1.5.0 against a fake `/llm`. The test's pieces go into step 1's test.

1. **Holds.** A transient unit takes `ExecStopPost=`, and it sees how the unit ended: `success exited 0`, `exit-code exited 3`, `timeout killed TERM` at `RuntimeMaxSec=`, `success killed TERM` after `systemctl stop`.
2. **Holds.** A oneshot with `Restart=on-failure`, `RestartSteps=` and `RestartMaxDelaySec=` is tried again until it succeeds, and stays `activating` meanwhile.
3. **Holds.** From a service hardened as `maxx.service` is (`PrivateUsers=true` and the rest), max's user starts a `maxx-vm@`-like instance once a polkit rule allows it those units, and is refused another unit.
4. **Holds** (tried with step 2, in the nested test on tank). A guest's connections reach an MCP listener bound again at `notify.vsock_7777` by the max that attaches, and SSH connects again with the key the boot saved: a unit in the guest that asked the VM service every second got 200, then 503 from the guest's forwarder while max was away, then 200 again, in the same boot of the same VM.
5. **Holds.** With `restartIfChanged = false` on the template, `switch-to-configuration` says "NOT restarting the following changed units" and the instance keeps its process; the next instance is the new template's.
6. **Half.** On SIGTERM pi exits at once, with status 143, before `agent_settled`: no report. On SIGUSR2 (and SIGINT) the plugin's handler aborts the run, `agent_settled` runs, the report is written, and pi exits within 30 ms. So the agent's unit has `KillSignal=SIGUSR2`. pi's own retries of a model call, 3 by default at 2, 4 and 8 seconds, don't outlast 20 seconds without the host; with `retry.maxRetries` 8 in `settings.json` they do. A steer read from a directory at `turn_end` goes into the next model call.
7. **Holds**, in the test machine and then in a guest (with step 2, in the nested test on tank). `switch-to-configuration test` remounts `/etc`, restarts an unmarked unit that changed, and leaves a job that runs through it. The guest's system deployed on tank has `bin/switch-to-configuration`, and its only switch inhibitor is the dbus implementation. In the nested test a deploy brought a second image, and a real guest, with its store overlay and its registration, was switched to it in the same boot, a unit of Max's running through.
8. **Holds.** A link max's user makes under `/nix/var/nix/gcroots/per-user/<user>/` is a root. On tank that directory is root's and empty, so the module makes max's; and tank collects weekly (`nix-gc.timer`), so the root is needed.

## Step 1: a call is a unit, and so is a background command

Done 2026-11-12; [Background commands](../design/jobs.md#background-commands) has it as it is. Until then `tools::unit_line` ran `systemd-run --pipe --wait`: the command's output was the SSH channel, max enforced the limit and stopped the unit (`wait_until`, `Command::stop`), and `tools::Output` wrote a long output's file from the host's side of `/work`. A background command was a task in the actor's job table that held the channel (`tools::background`), and one that moved handed its channel over (`Request::Adopt`, `tools::Moved`). What follows is the step as it was planned, and it landed so but for `/kill`'s answer, which says nothing of the guest's jobs. Since 2026-11-13 a call ends with its caller and the stopper is gone; see "A call ends with its caller" there.

- **The guest runs it** with `max-jobs` (`nix/max-jobs.sh`, packaged as `max-units` is), so that the flags are the guest image's and the host says only what it wants. Every unit is in `max-jobs.slice` (`nix/guest.nix`, as `max-units.slice` is), named `max-job-<start>-<n>`, with a directory `/run/max/jobs/<unit>/`, its output in `/work/.max/out/`, `RuntimeMaxSec=`, the command's first line as its description, and `ExecStopPost=max-jobs ended <unit>`, which writes how it ended from what systemd says.
  - `max-jobs run` is a call: it starts the unit, waits for its end, and prints one line, with how it ended and the head and tail of its output. An output that fits in what is shown doesn't keep its file. `run_code` is the same with the runner as the command: the program and its arguments come on stdin and wait in the unit's directory, and the result and the console are two files.
  - `max-jobs start` is a background command: it starts the unit and returns. When the unit ends, unless it was stopped on request (`success`, `killed`, `TERM`), `ended` starts `max-notify@<unit>.service`.
  - `max-notify@.service` (`nix/guest.nix`) is a oneshot that runs `max-jobs notify`, with `Restart=on-failure`: `maxx wake` with `[<unit> 完成]`, `到点了` or `失败`, the command, its exit status and run time, the end of its output and the file's path. A notice not yet taken is a unit systemd is still trying, and `systemctl list-units 'max-notify@*'` lists them.
  - `max-jobs list`, and `max-jobs stop-all`.
- **The host waits** (`tools.rs`, `tools/shell.rs`, `tools/run_code.rs`). A call is `max-jobs run` on a channel, and its line is the result. The limit is the unit's, 120 seconds or the call's `timeout_ms`, at most 600; max waits a little longer than that for the line, and a guest that doesn't answer leaves the unit to the stopper, as now. `background: true` is `max-jobs start`, with 6 hours or the call's `timeout_ms`, at most 24. A turn killed while it waits sends the unit to the stopper, as dropping a `Command` does now. If max goes away while a call runs, the unit ends by itself within its limit, and nobody is told.
- **A VM with jobs isn't idle.** Every `SWEEP`, a task of each running VM asks `max-jobs list` how many run; the service counts the VM as used, and `evict` passes it over. The `Vm` a background task held did this until now.
- **`/kill`** ends the core, whose calls go to the stopper, and a task in `side` runs `max-jobs stop-all`; its answer doesn't list them. **`/status`** has no line for jobs: Max runs `max-jobs list` when asked.
- **Goes:** `tools/background.rs` and `tools/output.rs`, whole; `Request::Shell` and `Request::Adopt`; `Moved`, `Movable`, `wait_or_move`, `due` and `moved_away`; `tools::Waiting`, `Active::waiting`, `Run::waited_on` and `MOVE_AFTER`; `unit_line`, `start_in`, `wait_until`, `ended`, `Ran` and `stopping` in `tools.rs`, and `Command::stop`; `run_code`'s `Split`; `Kind::Command`, `start_command`, `adopt`, `command_job` and `room_for_command` in `actor/jobs.rs`; `Handle::Shell`; `COMMANDS_AT_ONCE` and the setting `commands_at_once`, since the slice's weights and memory limit are what bound commands; `moving` in `main.rs`.
- **Tests.** The guest's part has no Rust to test, so a NixOS test boots the guest's own configuration as the test machine, not nested, with a fake `/mcp` that records the wakes: a call prints its result and wakes nobody; one at its limit says so; a background command that ends wakes Max once; a stopped one doesn't; with the fake host down, the notice arrives once it is back. What the host makes of a call's line is tested in Rust against a fake VM. `vm-check` keeps the command that greps its own output file.

## Step 2: the VMs outlive max

Done 2026-11-12. [VM processes](../design/vm.md) has it as it is. What follows is the step as it was planned; it landed so, with two things the plan didn't have: while max is away the guest's forwarder says so (503 with `max-away`), which is what a client's retry goes by, and max attaches again to a VM whose connection it lost.

Until then the two virtiofsd and cloud-hypervisor were max's children (`machine::spawn`, `kill_on_drop`), `maxx.service` stops with `KillMode=mixed`, the SSH key is made at each boot and kept in memory (`PrivateKey::random`), the slots are in `vm::Free`, and `vm::run` ends with "Dropping the VMs kills them".

- **`maxx-vm@.service`** (`nix/module.nix`): the three processes with the command lines `machine::boot` builds now, as max's user, the instance naming the VM's directory under `vm.dir`. What differs from boot to boot (the tap, the kernel command line's additions) comes from `EnvironmentFile=`, a `boot.env` max writes there. The unit takes the four things `maxx.service` was relaxed for (`RestrictNamespaces`, `@mount`, the three `Protect*` over `/proc`, the two devices) and `LimitNOFILE`, and `maxx.service` gets them back. A polkit rule lets max's user start and stop these units. Restarting `maxx.service` leaves them; stopping `maxx.target` stops them. The template has `restartIfChanged = false`: NixOS would otherwise restart every running VM whenever a deploy changes it. The VM has a cgroup and a journal of its own from then on.
- **Booting** (`machine::boot`) still makes the directory and the disk and binds the MCP socket, then writes `boot.env`, the key (`ssh.key`, mode 0600) and `boot.json` (the slot, the contract, the image), starts the unit and tries SSH as now. `Machine` is the unit's name. A VM is dead when its connection has closed and its unit isn't active.
- **Attaching.** Before `vm::run` boots the conversations with units, it lists the active `maxx-vm@` units and reads each one's `boot.json`. One whose contract isn't the configured guest's is stopped; if it is kept, the sweep boots it again. For the others it takes the slot in `Free`, connects with the saved key, within 10 seconds in all (`machine::let_in`: a guest that takes the connection and never greets has no longer than one that refuses; until 2026-11-13 that wait had no end, and such a VM, outliving max, would have kept the next max waiting too), binds the MCP socket again (that socket alone: on 2026-11-03 a second start replaced a running VM's sockets), and starts the stopper and the MCP service. The idle time counts from then. Nothing in the guest is stopped: a call the old max was waiting for ends by itself.
- **Stopping.** max closes its connections. The VMs stay.
- **The contract** is a number in the guest's JSON beside `kernel`, `initrd` and `cmdline` (`machine::Guest`), for everything a host says to a guest and the guest keeps between images: `max-jobs`' and `max-agent`'s arguments, the line a call prints, the runner's input, the job directory's layout, the routes. `AGENTS.md` says to raise it with any change to those.
- **An older image is switched where it runs.** The guest's JSON gains the system's path and its registration, and `boot.json` keeps them, so max, attaching, can tell a VM whose image isn't the configured one. The guest's store is the host's, so the new system is already there: max has the guest load the registration into its Nix database and run `<system>/bin/switch-to-configuration test`, in a transient unit so that it outlives the channel. microvm.nix does the same for guests whose store is shared. `register-nix-paths` can't do the first, since it reads `regInfo=` from the kernel command line, which doesn't change. `max-guest` runs again and links `/run/max/runner.js` to the new runner; `/run/max` is preserved. What must not restart under running work has `restartIfChanged = false`: `max-agent@`, `max-notify@`, `max-mcp@` and `max-browser`. Max's own units and the transient ones aren't in `/etc/systemd/system`, and the switch leaves them.
- **A new kernel waits for a quiet moment.** A switch leaves the booted kernel and initrd. A VM whose kernel or initrd isn't the configured one, or whose switch failed, is stopped by `Service::sweep` once it isn't lent, has no job and has gone unused for 10 minutes; a kept one is booted again by the same sweep. Ten minutes unused stands in for "no turn": the VM service doesn't know of cores, and a core idle that long loses no more than it does to the idle shutdown or an eviction now. systemd does the restart, and max decides when: only max knows that a call is using the VM, and a guest that reboots by itself comes back on the same kernel, the one cloud-hypervisor was started with.
- **The store.** Nothing on the host roots a guest's system today, and nothing had to: a VM never ran an image older than max's. What a group installs is in its own store disk (`nix.img`), but the guest's system is read from the host's store, where a collection after a deploy could delete it under a running VM. max links each image a VM runs under `/nix/var/nix/gcroots/per-user/<user>/`, a directory the module makes for it: the one it booted, whose kernel modules it goes on loading, and each it was switched to, whose processes may still run. The links go when the VM stops.
- **The caches.** A timer in the guest drops them when no job runs, every 10 minutes, as `Running::trim` has max ask for now. (Since 2026-11-13 it also asks that none has run for 10 minutes, as `Running::trim` did; see "Idle VMs drop their caches".)
- **The gap.** `client.js`'s `post` tries again when the connection is refused, with the waits `events` uses (`RETRY`, `MOST_RETRY`), for a few minutes. The jobs' ends have `max-notify@`.
- **Goes:** the children in `Machine`; `Running::trim`, `ssh::trim` and `TRIM`; "programs are restarted on every deployment".
- **Tests.** The nested test on tank restarts `maxx.service` under a running background command: the VM's unit stays active, a resident unit keeps its process, and the command's end wakes Max afterwards. With the contract changed, the VM is restarted; with only the system changed, the guest is switched and a command running through it ends as it would have; with the kernel changed too, it is restarted once the command has ended and it has gone unused. What attaching does with a set of `boot.json` records is a pure function with its own tests, and so is `Free` taking a named slot. `nix/tests/module.nix` checks the unit and the polkit rule.

## Step 3: an agent is a unit of its own

Done 2026-11-12. [Background agents](../design/jobs.md#background-agents) has it as it is. What follows is the step as it was planned; what landed differs in five things:

- There is no template unit. An agent is a transient unit `max-agent-<n>`, started through `max-jobs start --agent`: one path for a background command and an agent, one `ExecStopPost=`, one notice unit, and one list.
- `max-agent start` asks `GET /llm`, not `max-pi`: with no model configured, the call that would start the agent says so to Max, and no unit starts.
- An agent asks its Max with `max-agent ask`, which wakes Max and leaves the marker the plugin's hold goes by; a bare `maxx wake` would hold nothing.
- `Handle::Agent` stays, to read the wakes the ledger kept. `Command::wait_or`, `Sink`, `Stream` and `Waited` stay too: a call's line comes over them. `Command::open`, `Command::wait` and `Vm::open` went.
- `max_llm::Meter` no longer reads the tools a model called, which only an agent's progress showed. And `max vm-check` starts an agent in its VM against a provider of its own, so the nested test covers pi in the real guest.

The contract is 2 with it.

Until then `job::run` opens a session (`Caller::Job` with a `job::Link`), starts `max-pi` with the job's line on stdin and keeps the channel; `job::drive` holds the steers, the deadline, the wrap-up and the hold; the harness calls `/job/turn`, `/job/stop` and `/job/report` (`mcp/harness.rs`); `forward::call` forwards only a job's session's calls and tells the job how each went; pi lists Max's tools through MCP, those marked `job`.

- **`max-agent@.service`** (`nix/guest.nix`): `max-pi` in `max-jobs.slice`, with `RuntimeDirectory=` for the task, the system text and the inbox, `RuntimeMaxSec=` of 6 hours, `KillSignal=SIGUSR2` and `KillMode=mixed` with a `TimeoutStopSec=` that is the report's grace (pi exits at once on SIGTERM), and the same `ExecStopPost=` as a background command, so an agent's end is told as a command's is.
- **`max-agent`** (`nix/max-agent.sh`), which Max runs with `shell`: `start --title … --workdir …`, the task on stdin, names the agent, refuses a fourth, writes the task and starts the unit, and prints the name; `steer <name>`, the text on stdin, writes a file and renames it into the inbox, and refuses an agent that has ended. Both ends of a steer are in the guest, so the inbox is a directory and nothing more: what is left in it when the agent ends was not taken in, and the notice says how many.
- **`max-pi`** reads the task from its runtime directory, not a line from the host, and asks the host's new `GET /llm` for the model's protocol, window, output limit and effort. It builds the system text from `nix/agent-system.md`, which is `job::run`'s `SYSTEM`, and the notes, cut as `JOB_NOTES_BYTES` cuts them now. It sets `retry.maxRetries` to 8 in `settings.json`, so that pi's retries of a model call outlast max's restart. It writes no `mcp.json`: the system text names the commands the agent has, `maxx history`, `maxx web-search`, `maxx wake` to ask its Max, and `maxx ask` for another conversation's.
- **`max-agent.ts`**, as `max-job.ts` is renamed to go with the command and the unit, takes the inbox's files at `turn_end`; waits on the inbox at `agent_before_settle`, for 10 minutes at most, if the agent has asked something and nothing came; queues the wrap-up 5 minutes before the unit's limit; aborts on SIGUSR2; and at `agent_settled` writes `/work/.max/jobs/<name>.md`.
- **The host.** `/llm` forwards any call on the VM's socket to `llm.job`'s upstream and records the usage itself. An agent's `maxx` has no token, so its calls are a program's, which they could always be. Max answers an agent's question with `max-agent steer`.
- **Goes:** `job.rs`, `job/run.rs`, `mcp/harness.rs` and `mcp/agent.rs`, whole; `job()` in `client.js`; `Caller::Job`; `Request::Agent` and `Request::Steer`; `Kind::Agent`, `AgentWaits`, `start_job`, `steer_job` and `agent_over`; `From::Agent` and `agent_asks` in `actor/asking.rs`; `Poster::for_agent`; `ask` without `to`; `Notice::Ended`; `Handle::Agent`; `JOBS_AT_ONCE`, `JOB_TIME`, `QUESTION_WAIT` and `JOB_NOTES_BYTES`, which are the guest's from then on; what streamed a command's output over SSH (`Command::wait`, `wait_or`, `relay`, `Sink`, `Stream`, `Waited`), which the agent's channel used last; in `mcp/service.rs`, `initialize`, the protocol versions before the runner's and the answers to GET and DELETE, which only pi's MCP client needed.
- **Prompt.** `tools.agent` becomes `max-agent start` in `shell`, in the tools section and the memory's line about `workdir`.
- **Tests.** `scripts/check-pi-job` checks the plugin against the inbox, SIGUSR2 and the report's file, with a fake `/llm` and no `/job/…`. The NixOS test of step 1 gains an agent: started, steered, ended, told. The forwarder's tests lose the session and keep the metering.

## Step 4: one caller

Done 2026-11-12. [The guest's calls](../design/tools.md#the-guests-calls) and [Multimodal results](../design/tools.md#multimodal-results) have it as it is. What follows is the step as it was planned; it landed so, with these things the plan left open:

- `max.image` and `maxx show` check that the path is a file before they leave it, so a wrong path still fails where the program can see it; and `max.video` returns the length the guest measured.
- What a call leaves as bytes goes to `/work/.max/shown/<unit>/`, which the host reads from and never deletes in: `max-jobs run` clears away what is over an hour old.
- `maxx` lists `show` and `video` everywhere, and they say that nobody is there to see when there is no call.
- The prompt tells Max that what its own tools send is marked `程序发的` too.
- `vm-check` runs the calls from its VM itself, with no `Poster`, and prints what the host read of what a call left to show, which the nested test reads.

The contract is 3 with it.

Until then a call from a VM is run in one of two ways (`Handler::call` in `mcp/service.rs`): with a run's token, in its `Session`, by `Caller::route`; without one, by the conversation's actor in `side` (`Signal::Call`, `Conversation::program_call`). The session counts the run's calls, keeps the pictures it showed, and makes what it says the turn's (`Post::origin`). After step 3 the only sessions left are the turns' runs'.

- **Every call is the VM's.** `tools/call` goes to the conversation's actor, which runs it in `side` within the conversation's call time; the 64 at once are the VM's. `tools/list` lists every tool. No token is made, sent or read.
- **What a tool says is not a turn's.** A `Post` and a `Request` name no turn. The rows they commit are marked as a program's rows are, and `Conversation::refuses` knows `/stop` and shutting down and nothing else. A turn killed while its program runs may see one more thing said, in the moment before the guest stops the program's unit.
- **A picture is a path in the call's directory.** `maxx show` and the runner's `max.image` and `max.video` write the path to a list in `$MAX_CALL`, the unit's directory, and ask the host nothing. The call's line carries the list, and the host reads each file as `mcp/show.rs` does now, with the same limits, as it puts the result together. One that can't be shown is said so in the result, where until now the program was told. Outside a call there is no `$MAX_CALL`, and `maxx show` says nobody is there to see it. `max.file` becomes an ordinary tool, `file`.
- **Goes:** `Sessions`, `Session` and `Grant`; `Caller`, `Route` and `Call`, for a `Context` that has a `Poster` or none (vm-check's); `Poster::new`'s turn, `Post::origin`, the origin of `Event::Request` and `Refusal::Ended`; `Tool::JOB`, and what `Tool::TURN` routes (it still says whether the prompt declares a tool); the token in the runner's input, `MAXX_TOKEN` and `--setenv`; the line "Max tools called" (`called`, `tally`).
- **Tests.** `mcp/runner_tests.rs` runs the runner and `maxx` against the service without tokens: a call reaches the actor, a picture's path comes back on the call's line, and what is said carries the program's mark.

## Step 5: a question keeps no wait

Done 2026-11-12. [Asking another conversation](../design/jobs.md#asking-another-conversation) has it as it is. What follows is the step as it was planned; it landed so, with these things the plan left open:

- The one event is `Event::Heard`, with `Heard::Vm`, `Heard::Asked` and `Heard::Answered`, and the one signal `Signal::Heard`; the table tells an asker that Max serves no chat of the conversation it asked by sending the answer back through itself.
- A question is the core's that read it. B keeps it until it is answered or that core ends, and when the core ends B answers for it as `/stop` does, so the asker knows and may ask again. The step as first landed kept the latest 32 across cores and listed two hours' worth under `[等你回答的问题]`; the owner found the list unnecessary the same day, and a question that runs out is handled as `/stop` is, with no logic of its own. So "if B's Max doesn't answer, A's hears nothing", below, holds only across a restart of max.
- `Reason::Job` is `Reason::Answered`, which also reads `job` with its handle beside it: `turns::running_since` parses the triggers of the turns that have no outcome, and after a crash those may be older than this change.
- `ask` returns `{ asked: "c#9 <title>" }`.

With it the plan is done.

Until then a question Max asks is a job: `question_job`'s task holds a oneshot for `ASK_WAIT`, `Asked` keeps the other end, and `cancel` withdraws one or declines one. After step 3 these questions are all the job table holds.

- **Asking.** `Conversation::ask` checks the link and sends `Signal::Ask` with the question and who asks, and no channel for the answer. `ask` returns whom it asked.
- **Being asked.** B's actor numbers the question, wakes Max with `[ask#5 问]` as now, and keeps the number, the asker and the text in `Asked`, the latest few dozen. That entry is all that lets B's Max reach A: one answer, to that question.
- **Answering.** `answer` takes the entry out and sends A's actor a new `Signal::Answer` through the table, which starts the actor if it isn't running; A's Max is woken with the question and the answer. What B's actor can tell at once (it is stopped, it is restarting, Max serves no chat of B) goes back the same way, as the reason there is no answer.
- **No timer.** If B's Max doesn't answer, A's hears nothing: it asked, and may ask again or go on.
- **One event for a wake from outside.** What the VM service has to say, a question and an answer each wake Max with some words, and reach the actor as one event with its notice, in place of `Event::VmNotice`, `Event::Asked` and `Event::Answered`.
- **Goes:** `actor/jobs.rs` and `mcp/jobs.rs`, whole, with `cancel` and `status`; `Handle`; `Event::JobDone`; `Request::Cancel` and `Request::Status`; `question_job`, `question_answered` and `decline`; `ASK_WAIT`; `Reason::Job`, once it is settled that nothing reads the old rows of `turns.trigger` that hold one (`turns::running_since` is the one query that parses a trigger).
- **Tests.** The test of two actors asks and answers, and answers a question that was pushed out; none of them advances a clock.

## Afterwards

- **The actor** keeps where it is in the ledger, its settings, the core, `intent`, `side`, `asked`, `woken` and the subscribers. Its events are a message, a bind, a post, a segment, a model call's end, a call's end, a verdict, a request, a wake from outside, a caller's call, a subscription and the stop: 12 for 15. A request is one of 5 for 11: configure, ask, answer, wake, and whether a mute may go ahead. (As it is since 2026-11-12, counted in `conversation.rs`.)
- **A guest says to the host:** `/mcp` (`tools/list`, `tools/call`), `/llm` (and `GET /llm`), `/api`, `/events`, `/units`.
- **The host says to a guest**, over SSH: `max-jobs run`, `start`, `list` and `stop-all`; the end of a call's input, which stops the call (until 2026-11-13, `systemctl stop` of its unit); the switch to a new image.
- **A restart** loses the running turn, as now, with the call it was waiting for (2026-11-13), and nothing else: background commands, agents and resident programs run on, and their notices wait for max. An actor that fails (`give_up`) stops no job.
- **By size** (counted 2026-11-12; the files that go whole are counted, the rest estimated from what the steps name, roughly). Eight files go whole (`actor/jobs.rs`, `job.rs`, `job/run.rs`, `mcp/harness.rs`, `mcp/agent.rs`, `mcp/jobs.rs`, `tools/background.rs`, `tools/output.rs`), 2,136 lines, with three files of their tests, 809. In all the host loses about 3,700 lines outside tests and gains about 600 (attaching, the older image, a call's line, an answer's way back): some 3,100 fewer of 30,567, a tenth. Step 2 adds to the host, since outliving max is something new. The guest gains two commands, three units, a timer and a slice: about 450 lines of shell, TypeScript and Nix, and a NixOS test. Max has 13 tools for 16.

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
- A restart of max stops no background command, agent or program. A call a turn was waiting for ends with the turn (2026-11-13).
