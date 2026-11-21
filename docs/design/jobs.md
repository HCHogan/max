# Jobs: agents, commands, programs and questions

What runs apart from a turn: background agents, background commands and
resident programs, all units of the guest's systemd that max keeps no
state about, and questions between conversations, which live only as long
as the turn that read them. Why lifetimes are the guest's is in
[decisions/lifetimes-to-systemd.md](../decisions/lifetimes-to-systemd.md).

## Background agents

Work of many steps runs apart from the turn, as an agent of Max's: pi, in
the group's VM, on a task Max wrote for it, for hours if need be, while Max
goes on in the chat. An agent is a unit of the guest's; max keeps nothing
of it.

- **A unit.** `maxx agent start` (`nix/max-agent.sh`), which Max runs with
  `shell`, starts a transient unit `max-agent-<n>` in `max-jobs.slice`
  through `maxx units agent`: the path of a background command, with
  `KillSignal=SIGUSR2`, `KillMode=mixed`, `TimeoutStopSec=30` and a
  `RuntimeDirectory`. The unit runs `max-pi <unit>` (`nix/max-pi.sh`), which
  execs `pi --print --no-approve` with the plugin `nix/max-agent.ts`. What
  an agent is, is in its directory, `/run/max/jobs/<unit>/`: `task`,
  `workdir`, `model.json`, `title`, `limit`, `started`, `resume` for one
  that goes on from another, the steers in `inbox/`, and the markers
  `asked`, `stopped` and `error`. The count of
  those that run and the next number are taken under one lock held until the
  unit has started. The number comes from `/work/.max/jobs/.count`, so it
  goes on across restarts of max and boots of the VM.
- **Limits** are the guest's, in `max-agent.sh`: 3 at once, counted from the
  units that run, and 6 hours each, as the unit's `RuntimeMaxSec`. The
  prompt names neither: `maxx agent start` says the time as it starts one,
  and why when it starts none.
- **Models.** `job = { model, effort }` in `[llm]` is the agents' default;
  without it there are no agents. pi holds no key: its calls go to
  `http://127.0.0.1:7777/llm/<endpoint>`, where max sends a
  call that names a configured model (`provider/model`, as `/model` names
  them) to that provider and any other to the agents' own, replaces `model`
  with the provider's id, adds the provider's key and headers, and passes
  the rest on as pi wrote it; the answer streams back unchanged. A provider
  quiet for `stream_idle_timeout_secs` is cut off, and pi retries. Only the
  endpoint of the model's protocol is accepted.
  - `GET /llm` says what a harness must know before it calls: `{api, model,
    window, max_output, effort}` for the agents' own, and under `models` the
    same for every configured model, without the effort; 404 when there are
    no agents. `maxx agent start` writes the chosen one into `model.json`.
  - `maxx agent start --model <name> --effort <level>` starts an agent on
    another model, and `maxx agent models` lists them with their windows.
    There is no list of models agents may use: whatever `/model` offers a
    turn, an agent can run on, priced ones too. The effort is a field of the
    request max passes on (`reasoning_effort`, or `reasoning.effort` over
    Responses): `--effort` is one of pi's levels, checked at start, since pi
    takes a word it doesn't know for `medium`; and `max-pi` has pi send
    `xhigh` and `max` as they are, which it would otherwise send as `high`
    to a model it has no list for.
  - **No sessions**: `/llm` takes any call on a VM's socket, and nothing
    knows which agent called. So anything in the VM can spend on any
    configured model, which is accepted, as the VM is the group's own and
    its programs could always start an agent.
- **Usage** isn't recorded: max (`service/forward.rs`) passes a
  call on and its answer back without reading what it used, and `/status`
  shows what Max's own calls used. What the agents spend is in the
  provider's records, for all the groups together; why is in
  [decisions/forwarder-keeps-no-count.md](../decisions/forwarder-keeps-no-count.md).
- **Tools**: an agent is a program, which calls every tool with `maxx` from
  its shell (`maxx history`, `maxx web-search`, `webread`), with no tools of
  its own on the host. It could speak in the chat too; its system text tells
  it not to, and nothing enforces that.
- **Steers**: `maxx agent steer max-agent-3 '…'`, or `--text -` from stdin,
  writes a file into the agent's `inbox/`, under a dotted name first and then
  renamed, so the plugin never reads half of one; its name is the time in
  nanoseconds, so they sort. The plugin takes them at each `turn_end`, before
  the next model call; it refuses if the unit isn't running. A steer the agent
  never took is counted in what Max hears of its end.
- **Questions**: an agent stuck on what only Max or the people know runs
  `maxx agent ask '问题'`, a wake: `[max-agent-3 问] 标题`, the question and how
  to answer, and the marker `asked`. Max answers with `maxx agent steer`. The
  agent goes on meanwhile; with nothing left to do pi would settle, so the
  plugin hooks `agent_before_settle`: with `asked` there and the inbox empty,
  it waits up to 10 minutes, and what comes is one more turn's input. An
  answer taken at a turn's end removes `asked` too. The question has no
  number and nothing to decline: unanswered, the agent goes on by its own
  judgement. To ask another conversation, the agent runs `maxx ask` as Max
  would; the answer wakes Max, who passes it on.
- **Results**: once pi has settled, the plugin writes the agent's last text to
  `/work/.max/jobs/<unit>.md`, and the last model call's error, if any, to
  `error`. The unit's `ExecStopPost` (`maxx units ended`) starts
  `max-notify@<unit>`, which wakes Max with `maxx wake`: `[max-agent-3 完成]
  标题`, `[max-agent-3 到点了，下面是做到一半的] 标题` when the unit ran out of time,
  or `[max-agent-3 失败] 标题：why`; then the report's first 2,000 characters,
  `（全文在 …）`, and how many steers it never took. The notice is retried for as
  long as max doesn't take it. A wake is `Reason::Program`: input to the
  running core or a new one, and what to say of it in the chat is Max's to
  decide.
- **Sessions**: pi keeps the agent's conversation beside its report, in
  `/work/.max/jobs/<time>_<unit>.jsonl`: `max-pi.sh` names the session after
  the unit (`--session-id`) and gives it the agent's title (`--name`, a
  `session_info` entry), so the session says whose it was and what it was for
  after `/run` is gone, and whether or not a report was written.
- **Going on from an ended agent**: `maxx agent start --resume max-agent-3`
  starts a new agent, with its own number, whose conversation is all of
  max-agent-3's and then its task: work to go on with, redo or ask about,
  without retelling what the earlier one read and did. `max-agent.sh` takes
  the newest `*_max-agent-3.jsonl`; it refuses an agent whose unit runs,
  which is steered instead, and one without such a session. The new agent
  keeps the session's directory (its `cwd`) and title unless it is given
  others. The session's path goes into `resume`, and `max-pi.sh` gives pi
  `--fork` with it, beside `--session-id`: pi copies it into the new
  agent's session, whose header names it (`parentSession`), and leaves it as
  it was, so one agent can be taken up twice. Otherwise the new one is an
  agent like any other: its limits, report and wake are its own, and so are
  its model and effort, the agents' default unless `--model` and `--effort`
  say otherwise, whatever the earlier ran on. Its system text is built anew,
  with the notes as they are now. Why a fork and a new number is in
  [decisions/resume-by-fork.md](../decisions/resume-by-fork.md).
- **Stopping**: `systemctl stop max-agent-3`, or `/kill` and `/stop`, which
  have the guest stop everything that was started (`maxx units stop-all`).
  pi exits at once on SIGTERM with nothing written, so the unit's
  `KillSignal` is SIGUSR2: the plugin leaves `stopped`, aborts the run, and
  the report is written as pi settles. One stopped on request wakes nobody;
  one stopped by its limit does. Five minutes before the limit the plugin
  steers the agent itself, to update its notes and report.
- **What max shows**: `/status` lists no agents; `maxx units list` shows them
  with the background commands. `agent#3`, as the host once named them, is
  still read from the wakes the ledger kept, as the reason `job`
  (`Reason::Answered`'s alias).
- **When to hand off**: the system prompt says work of many steps goes to an
  agent, not into the turn (reading a whole repository, reviewing or changing
  code, installing, building, testing, opening PRs, reading many pages or
  files); Max says in the chat that it has taken it on and about how long it
  will take, then starts the agent. What a few steps answer, it does itself.
  `agent_start`, `agent_steer` and `agent_models` are declared in the prompt
  with their guides; the prompt says to take up an ended agent's work with
  `--resume` rather than tell a new one all of it again.
- **Project directories**: `--workdir` is `/work` by default, or an absolute
  guest path or one under `/work`, made if missing. The VM, not the
  directory, is the boundary. pi reads the directory's `AGENTS.md` or
  `CLAUDE.md`, and its parents', even with `--no-approve`; a project's `.pi/`
  stays untrusted.
- **Notes**: agents keep notes for each directory they start in,
  `/work/.max/projects/<name>.md`, the name being the path with letters and
  digits kept and the rest `-` (`/work/max` is `work-max.md`). `max-pi.sh`
  appends it to the agent's system text under `[笔记]`, cut at a line at 16
  KiB; a link, or a file past 1 MiB, isn't read. The agent updates it before
  it reports. Max's memory keeps only a project's name, path and one line.
- **The system text** is `nix/agent-system.md`, after pi's own: it is Max's
  background agent and doesn't see the chat; `maxx history`, `maxx
  web-search` and `webread` for looking things up; not to speak in the chat;
  its last message is its report; `maxx agent ask` for what only Max or the
  people know; its directory and notes.

### What the plugin relies on in pi

Checked with pi 1.4.0 and 1.5.0:

- A steer doesn't interrupt a running tool. In its `turn_end` handler the
  plugin calls `pi.sendUserMessage(steer, { deliverAs: "steer" })`; pi takes
  the queue only after the handlers finish, so the steer goes into the next
  model call; with `"steeringMode": "all"` several go together. If the last
  `turn_end` picks one up, pi runs another turn.
- `ctx.abort()` kills the running tool at once and pi stops. pi exits on
  SIGTERM with status 143 and reports nothing, and leaves SIGUSR2 to the
  plugin.
- `agent_end` isn't the end: automatic retries and queued steers come before
  `agent_settled`, and pi exits only after its handlers finish, which is
  where the report is written.
- An `agent_before_settle` handler that returns `continue: true` with entries
  added has pi run again with them; it is skipped on abort.
- When the last message is a failure or an interruption, print mode prints
  nothing and exits 1, so the report is the plugin's to write.
- Print mode exits only once the event loop is empty, so the plugin's timer
  is unref'd.
- The task comes on stdin: as an argument, a leading `@` would be read as a
  file.
- `--append-system-prompt` goes after pi's own prompt; a `SYSTEM.md` in the
  agent directory would replace it, so the file is `agent-system.md`.
- pi retries a failed model call 3 times by default, about 14 seconds in all;
  `"retry": {"maxRetries": 8}` gives it longer. A call that a restart of
  max cuts off fails once: the next try waits at max's socket for the max
  that comes.
- `--session-id` names a new session, and with `--fork` names the copy, which
  is in the current directory whatever the earlier's was. The copy's model
  and thinking are the command line's, not those the session had. Its system
  prompt is built anew; pi sends the model the prompt as it is now, once, and
  records in the session what changed (checked with 1.5.0, whose sessions
  keep the prompt as system messages).

pi comes from numtide's llm-agents.nix, pinned in the flake. Its extension
API has no version, so `scripts/check-pi-job` runs after moving the pin or
changing `max-agent.ts`, `max-pi.sh` or `agent-system.md`: the pinned pi with
the real wrapper and plugin against a fake `/llm`, through seven agents
(steers, a steer in the last turn, a stop by SIGUSR2, an answer that comes
while it is held, a project with `AGENTS.md` and one with `CLAUDE.md`, and
one that goes on from another's session on another model). What
surrounds pi is in the NixOS test `checks.<system>.jobs`, and `max vm-check`
starts one agent in a real VM against a provider of its own.

### What a harness keeps

The host speaks no harness's protocol; what a harness keeps is the guest's,
in files and a signal:

- **Start**: `maxx agent start` runs the wrapper as a unit with the agent's
  directory, from which it reads `task`, `workdir` and `model.json`.
- **Model calls** go to `http://127.0.0.1:7777/llm/<endpoint>`, with any key
  or none, naming the model as `model.json` does. `/llm` speaks Chat
  Completions and Responses.
- **Steers** are the files of `inbox/`, oldest first by name, each removed
  once taken; a dotted name is still being written.
- **Stop** is SIGUSR2: leave `stopped`, stop what runs, and write the report
  within 30 seconds.
- **The report** is `/work/.max/jobs/<unit>.md`, a heading, an empty line and
  the text; `error` holds why the last model call failed.
- **Asking** is `maxx agent ask`, and holding for the answer is the harness's
  own; `asked` says a question is out.
- **Going on** is `resume`, the path of the earlier agent's session, which
  `maxx agent start` found by pi's naming. A harness with sessions of its own
  needs `maxx agent start` to find those; one without starts from the task
  alone.

A harness that keeps none of it still runs as an agent: Max hears how it
exited and that it left no report. Another harness needs a wrapper like
`max-pi.sh` and whatever of the above it can hook.

## Background commands

A command that runs for minutes (a build, a test run, a download) needs no
other model, but inside the turn it keeps the group waiting. So `shell` has
`background`: the tool returns at once, the command runs on, and Max is
woken when it ends.

- **Everything Max runs in the VM is a unit**, a transient one in the guest's
  `max-jobs.slice`, started by `maxx units` (`nix/max-jobs.sh`,
  `nix/jobs.nix`): systemd limits it (`RuntimeMaxSec=`), stops it and sees it
  end. A unit is a call or a background command from its start, and neither
  becomes the other. The host says what it wants as one JSON object
  (`maxx units run '{…}'`), and the flags are the guest image's. One is
  `--expand-environment=no`, since systemd would otherwise fill in every
  `${…}` of a command (and make `$$` a `$`) before bash saw it, heredoc quotes
  or not.
- **A call** (`maxx units run`) is `shell` without `background`, and
  `run_code`. The guest starts the unit, waits for its end, and prints one
  line of JSON: how systemd says it ended (`success`, `exit-code`,
  `timeout`…) and what it wrote, all of it, or 8 KiB of its head and as much
  of its tail with the file that has the whole. `tools::wait` reads that
  line, the last of what came, so whatever a `/work/.bashrc` prints first
  isn't taken for it. `run_code` is the same with the runner as the command,
  the program on stdin and its stderr apart. The unit writes its own output,
  under `/work/.max/out/`, kept only when the output didn't fit.
- **A call ends with its caller.** max gives `maxx units run` the command's
  input, as many bytes as `input` says, then holds the channel's input open,
  silent, for as long as it waits. When that input ends, the caller is gone:
  `maxx units run` stops the unit, removes what it wrote and prints nothing.
  So a turn killed during a call stops it by closing the channel (dropping
  `ssh::Command` hands it to the VM's `closer`, since russh closes nothing on
  drop), and a call whose max restarted, crashed or lost its connection is
  stopped by the guest alone. If `maxx units run` itself is killed, its unit
  ends at its limit and the unit's hook clears up.
- **A background command** (`maxx units start`): the tool returns the unit's
  name, `max-job-<start>-<n>`, its limit (6 hours, or `timeout_ms` up to 24)
  and where its output is written as it runs.
- **When it ends**, the unit's `ExecStopPost=` (`maxx units ended`) writes
  how, and starts `max-notify@<unit>.service`, a oneshot that calls `maxx
  wake` with `[<unit> 完成] $ make` (the command's first line, up to 200
  characters, as `maxx units list` titles it), the exit status and run
  time, the end of the output (a wake takes 4,000 characters) and the
  file's path; `到点了，下面是做到一半的` at its limit. With `Restart=on-failure` systemd retries it until
  max takes it, so a notice isn't lost while max is away, and `systemctl
  list-units 'max-notify@*'` lists those that wait. Max sees it as
  `[max-wake] [max-job-… 完成] …`. A unit stopped on request (`systemctl stop`,
  `/kill`) tells nobody, since whoever asked knows: the hook knows it by
  systemd's stop job for the unit, still there while the hook runs
  (`systemctl list-jobs`). One that ends by SIGTERM of its own is told, as
  `ended by SIGTERM`.
- **What Max does with them**: `maxx units list` shows what runs and
  `systemctl stop <unit>` stops one. `/kill` has the guest stop them all (in
  a task of the actor's `side`), a person's way to stop what runs without
  asking Max; `/status` doesn't list them.
- **The VM stays up** while one runs: every minute the VM service asks the
  guest `maxx units list` and counts those whose kind isn't `unit`; a VM with
  any is in use and isn't evicted.
- **A working directory is checked first**, since systemd applies it to the
  unit's hook too and a unit in a missing directory would end without saying
  how; `maxx units` refuses it. It needn't be there at the end: the unit has
  `WorkingDirectory=-…`, so a command that removes its own directory still
  has its hook run.
- No limit on how many run at once: the VM's room bounds them. A call not
  done at its limit is stopped, and Max runs it again with `background`.
- **The prompt** says a command that will run for minutes should use
  `background`: a unit whose name comes back at once; in the same output Max
  tells the group, then stops and waits for `[max-job-… 完成]`; `maxx units
  list` and `systemctl stop` look at them and stop one.
- **Tests**: `nix/tests/jobs.nix` boots the guest's jobs with a fake max and
  no VM: a call's line, its limit, a long output, its input and environment,
  a background command's notice, one stopped, the notice that waits while
  max is away, and a call whose caller is gone. `vm-check` starts a background
  command that greps its own output file and waits for its notice. What
  `tools` makes of a call's line has Rust tests.

## Resident programs

What Max needs to keep running (reminders, checking CI or a page every few
minutes, a listener that stays connected) isn't built kind by kind. Max
writes ordinary systemd units in its VM: a `.timer` is cron, a `.path`
watches files, `Restart=` handles crashes. Why this rather than a monitor
with kinds is in
[decisions/resident-programs.md](../decisions/resident-programs.md).

### Units follow /work

The VM's `/` and `/etc` are a tmpfs rebuilt from the NixOS configuration at
every boot, and a VM stops when idle, evicted or replaced. So unit files live
in `/work/.max/systemd/`, and that directory is the registry: no table, no
tool.

- **`maxx units apply`** (`nix/max-units.sh`) makes the units in the
  directory the ones that run: new and changed files are copied to
  `/run/systemd/system`, each service gets a drop-in putting it in
  `max-units.slice`; units with an `[Install]` section are enabled and
  started for this boot (`enable --runtime --now`); changed running units are
  restarted; units gone from the directory are stopped and removed. A unit
  named like a system unit isn't installed (the one in `/etc` would win), nor
  is a link (the host counts only files, since on the host a link could point
  anywhere). It answers with each unit's state, the last 10 log lines of any
  that failed, the files skipped and why, and what it removed, as one JSON
  object, and whether the VM will be kept on (below). It takes a lock, so the
  run at boot and Max's can't collide.
- At boot `max-units.service` runs it once, after `/work`, the network and
  nix-daemon are up, and after `max-host.socket`; when Max changes the
  directory, it runs `maxx units apply` itself. Starting never blocks
  (`--no-block`); it waits at most 5 seconds before reporting.
- **`max-units.slice`**: `CPUWeight=20` and `IOWeight=20`, yielding to
  commands; `MemoryMax=50%`.
- **The environment**: the manager's `DefaultEnvironment` sets the system
  PATH (systemd's default lacks `/run/current-system/sw/bin`) and
  `HOME=/work`, and root's home in passwd is `/work` too. A unit's
  `Environment=` still wins.
- **The home is `/work`**, the one directory the host reads and the one that
  survives, so `~/.profile`, `~/.gitconfig`, `gh auth` and caches persist and
  stay warm. `bash -lc` reads `~/.profile` every time, so a broken one stops
  `shell` and `run_code` until it is deleted on the host; the prompt says so,
  and that units don't read it (`Environment=` instead). Packages from `nix
  profile add` are in `/nix/var/nix/profiles/default`, persistent and on
  PATH.
- Only `/work` and the store survive: whatever a unit runs is in `/work`, a
  store path or `nix run`, and its state is written to files, since programs
  restart at every deploy's switch or boot.
- **The escape hatch**: with `max.units=off` on the kernel command line
  nothing is installed at boot, the only way out of a unit that stops sshd,
  shuts the machine down or eats the memory, which would come back every boot.
  The host adds it (below).

### Kept on, woken, failing

- **Kept on**: at most `vm.kept` groups' VMs (4 by default; 12 on tank) are
  kept running for their units: not stopped when idle, not evicted, and booted
  by the sweep if down. When max starts it reads each
  `<vm.dir>/<conversation>/work/.max/systemd/` and keeps, in order of
  conversation id, up to `kept` of those with unit files (the suffixes `maxx
  units apply` accepts; links don't count), booting them at once.
  Conversation 0 is `vm-check`'s, which uses its own directory,
  `<vm.dir>/check`. After that it follows `maxx units apply`, which POSTs the
  number of units to `http://127.0.0.1:7777/units` each time it runs: with
  any, the VM is kept on unless the slots are full; with none, it isn't. The
  answer comes back as `said`, so Max sees whether its VM will stay up. The
  prompt doesn't name the number of slots. A kept but idle VM still drops its
  caches (see [Resources](vm.md#resources)).
- **Waking**: `maxx wake '…'` is `Request::Wake`, through the conversation
  table to the actor (started if not running) as `Event::Heard`. The reason
  is `Reason::Program`, and the model sees `[max-wake] …`, cut to one item's
  cap; it is input to the running core or starts one. The program is told
  Max was woken. There is no limit on how often, but from the second wake in
  an hour the line ends with `（这一小时第 N 次）`, so a turn that didn't see the
  earlier wakes (they are no rows) still knows, and Max can find which program
  it is; `/status` shows `woken`.
- **Failing to boot**: each time a group's VM fails to start or stops by
  itself, it is counted, kept or not. Twice within 30 minutes and the next
  boot adds `max.units=off`, the group is no longer kept, and Max is told
  (`Heard::Vm`, `[VM] …`). Once Max has fixed it and run `maxx units apply`,
  the VM is kept again. If it fails even without units, they aren't the
  cause: it isn't kept, and boots when a tool needs it rather than every
  minute. The boot-time `maxx units apply` doesn't reset the count.
- **The prompt**: an idle VM stops, except in groups with resident programs;
  anything that must keep running, run on a schedule or watch something is a
  unit in `/work/.max/systemd/` followed by `maxx units apply`; `.timer`,
  `.path` and `Restart=on-failure`; absolute paths in `ExecStart`; state in
  `/work`; `systemctl status` and `journalctl -u` to check; `maxx wake` only
  when there is genuinely something new.
- **Tests**: `vm-check` puts a unit that records the boot id in
  `/work/.max/systemd` and runs `maxx units apply`; the nested test runs it
  twice, checking the unit is active before the second boot's apply and both
  boots are recorded, that `maxx units apply` says the VM stays up, and that
  `maxx wake` reached `vm-check`.

### Programs call tools

Programs use the same tools as Max (see [maxx](tools.md#maxx-one-command-for-everything-in-the-vm)):
a call is the VM's, whatever made it. Why programs have every tool, and no
caps, is in
[decisions/no-limits-for-programs.md](../decisions/no-limits-for-programs.md).

- **Every tool**, plus `say` and `wake`, which the prompt doesn't declare
  (`service/program.rs`). Only `show` and `video` fail outside a call, as
  nobody is there to see.
- **`say`** takes text written as Max writes replies, through the same
  segmenter: `[reply#id]`, `[mention#id]`, `[sticker#id.n]`, `[image#id.n]`,
  `[split]`, blank lines between messages. A `[mention#id]` must be someone
  the group knows (`platform::roster`). All its messages are handed to the
  actor before any receipt is awaited, so a `say` goes out whole even if the
  program stops waiting. It returns `{messages: [id, …]}` once every receipt
  is in; if some fail, the reason says which went and how many didn't.
- **Unfilled ids are refused**: a marker outside code whose id is missing or
  not a number (`[reply#]`, `[mention#undefined]`, `[reply#${id}]`) sends
  nothing, with "编号是空的或者不是数字：程序里的变量没填进去？". The segmenter notes them
  (`Segment::unfilled`) where it turns a `[` that starts no placeholder back
  into text, so the check agrees with what is sent: in a code fence or inline
  code such a marker is an example and goes out; explanatory text like
  `[reply#id]` goes only in code. Only programs' `say` is checked, not the
  model's own replies. (Shells swallowing JS's `${…}` used to send these into
  groups as text.)
- **Marked in the record**: rows a tool sent have `raw` `{"said_by":
  "program"}`, and render with `程序发的` (`Mark::Program`): `[12:00 maxx #45
  程序发的]: …`, in `history` and the tail alike, so Max can tell what it said
  from what a program said. That includes what a turn's own tools send
  (`send_image`, `send_file`, `send_voice`, a command's `say`), since the host can't tell who
  called; the prompt says so. A running core doesn't see these rows; the next
  core's tail has them. A script can be tried once through `shell`, and what
  it sends is marked the same.
- **The prompt**: what needs no judgement from Max, a program says itself
  with `maxx say`, written as replies are, marked `程序发的`; pictures, files
  and voice messages go with `maxx send-image`, `send-file` and `send-voice`.
- **Tests**: the actor's test has `say` send two messages and return the
  ids only after the receipts, with `raw` marked and the next core seeing
  `程序发的`; vm-check's background command runs `maxx wake`, and
  `maxx units apply` reports through `/units`.

### Following the chat: maxx events

- **Published by the actor**: after each row is entered (where the workers
  are notified), it goes into a `broadcast` of 256 if anyone subscribes. A
  subscription is `Signal::Subscribe` through the table to the actor (started
  if not running), which answers with a `Subscription`: the place, the `head`
  at that moment and a receiver. The actor handles one event at a time, so
  everything up to `head` is in the database and everything after will
  arrive: no duplicates, no gaps. When the actor stops, the stream ends.
- **The route**: `GET /events` (`vm/events.rs`) answers
  `application/x-ndjson`, with `max-head` carrying the head. `?after=<id>`
  first backfills from the database the rows after it up to `head`, the latest
  1,000 at most, 100 at a time, then goes on with new rows. After 30 seconds
  without a row an empty line is sent as a heartbeat. If the subscriber falls
  256 rows behind, or the actor or the VM's service stops, the stream ends,
  and the program asks again from its last row.
- **A line**: `{id, at, sender, person, by, reply_to, text}`. `at` is local
  RFC 3339; `person` is the sender's person number, which `[mention#person]`
  takes; `by` is `max` or `program`, absent for members; `text` is what
  follows the colon in a `history` line (`Render::body`), never cut. Commands,
  edits (`[edit#…]`) and retractions (`[unsend#…]`) are included, as in
  `history`. With `--full` (`tools.events({full: true})`, `?full=1`) each line
  also has `row` and `people`, as `rows` gives them (below), read from the
  ledger as the line is written; it triples a line's length, so it is asked
  for.
- **`maxx events [--after <id>]`** (`events()` in `nix/client.js`) prints each
  line as one line of JSON and keeps running. If the connection breaks, an
  error occurs, or 90 seconds pass without even a heartbeat, it reconnects
  after 1 second, doubling to 30, from the last line it printed, or from
  `max-head` if it printed none, so nothing in between is lost; the reason goes
  to stderr. EPIPE exits. `--after` takes `123` or `#123`.
- **The prompt**: to react to new messages, `maxx events` rather than
  polling `history`; its fields; `by`, so as not to answer itself;
  reconnecting when the stream breaks; and `--after` with the id kept in
  `/work`, to resume.
- **Tests**: the actor's (the head is the last row entered, then members'
  messages and Max's answers in order, ending when the actor stops), the
  table's (`Signal::Subscribe` reaches an actor `maxx wake` started),
  `vm/events.rs`'s (backfill, new rows, nothing before `after` again,
  heartbeats, the end, 400 for other queries, 503 for a conversation that
  doesn't answer, no holding up shutdown), and `maxx events` run with Node
  against the route, reconnecting from the last line.

### Rows as data

A program also has the timeline as data, not only as the text a model
reads, so it needn't parse back out what a row's media, mentions and edits
are.

- **`rows`** is a host tool the prompt doesn't declare (`service/rows.rs`):
  `tools.rows({after, before, limit})`, `maxx rows`. With `after` it reads on
  from that row, the first `limit`; without, the newest, before `before` if
  given; 100 by default, 1,000 at most. It answers `{rows, people, head}`.
- **A row** is the message as the core has it, `max_core::message::Message`
  as serde writes it, with `command` and `delivery` from the ledger beside it:
  `{id, conversation, sender: {identity, name, role}, at, content, turn, raw,
  command, delivery}`, `content` being a `message`, an `edit` or an `unsend`,
  and a message's `nodes` the core's. What the projection reads is what a
  program reads. A field that goes or changes meaning is a change to the
  contract with the guests; one more isn't. The tool's schema names a row's
  own fields.
- **`people`** maps each identity among the rows' senders and those they
  mention to the person's number.
- It isn't part of `history`, whose arguments are declared in the prompt for
  turns that should never ask for it.

## What a stopped or stopping conversation refuses

One function answers what an event may do (`Conversation::refuses`):

- A request of a turn that isn't running is refused whatever it is: `this turn
  has ended, so this wasn't done`.
- After `/stop`, what would have Max say or do something is refused with `Max
  is stopped here (/stop), so this wasn't done`: `say`, `send_image`,
  `send_file`, `send_voice` and `recall_message` as their posts reach the actor;
  `mute_member`, which asks the actor first (`Request::Act`); starting an agent
  or a background command; `ask`, `answer` and `wake`. VM notices are dropped.
  What reads still works: `history`, the searches, `/api`, `maxx events`.
  `/start` lets them through again. See [Commands](context.md#commands).
- As Max shuts down, what starts work is refused (`Max is restarting, so this
  wasn't done`); the core still running may finish what it says.
- Looking, steering and changing a setting are never refused.

Every tool's request of the actor is one event, `Event::Request`, whose
`Request` has a kind for each thing asked (configure, ask, answer, wake,
act), each carrying where its answer goes; `actor/requests.rs` does them once
the rule has let them through.

What the actor tells a tool or program, refusals and errors alike, is in
English, as are the tools' descriptions, guides, argument descriptions,
checks, results and failures, what the guest's commands print, and what the
VM service, the sender and the search tell a failed tool; a failure's code
follows its message in brackets, ` (not_found)`. Chinese stays in the system
prompt's own prose, the notices Max is shown and their tags (`[max-agent-3
完成]`, `[ask#5 问]`, which English guides quote as they are), the timeline's
marks, what stands in for a picture left out, the agent's own prompt, and what
`vm-check` prints.

## Asking another conversation

Max in one conversation can ask Max in another, which answers by its own
rules, with its own memory and people at hand. The asker gets the answer and
nothing else, never the other conversation's context, memory or files.
Conversations are otherwise isolated (`history`, the VM and `/work` are each
one conversation's; only the sticker library is shared). The reasoning behind
edges and their direction is in
[decisions/asking-another-conversation.md](../decisions/asking-another-conversation.md).

- **Permission is an edge between conversations**, not a person's: below a
  conversation nothing could be enforced, since its members share one VM as
  root and one context. A person's own permission is their private chat's.
- **An edge has a direction.** A→B lets Max in A ask Max in B, not the other
  way, and what it exposes is B: anyone in A can have A's Max ask, so the edge
  lets A's members try to talk B's Max into whatever B's Max can do, the
  [operations network](vm.md#the-operations-network) included, and the
  answering core is the one serving B's own chat, with all its tools. An edge
  into B is a weaker membership of B, made only where that is acceptable.
- **`/link` makes one**, with a code, as `/bind` does: `/link` in A answers
  with a six-digit code, valid 10 minutes and held in memory; `/link <code>`
  in B makes A→B. The side to be asked redeems the code, since it is the one
  exposed. Both directions take two links. `/unlink c#N` removes the edges
  between this conversation and that one, both ways, from either side. All
  three are for the people a conversation belongs to: a group's owner, not its
  administrators; the other party of a private chat; and Max's owners (see
  [Who may run what](commands.md#who-may-run-what)). The answers say which way
  an edge runs:

  | Command | Answer |
  | --- | --- |
  | `/link` in A | `code issued: 123456 lets Max here ask Max in another conversation, and not the other way`, then `send /link 123456 there (in a group: @maxx /link 123456)` and `valid for 10 minutes, once` |
  | `/link 123456` in B | `linked: Max in c#7 <title> may ask Max here now, and not the other way`, then `@maxx /unlink c#7 removes it`; or `skipped: Max in c#7 <title> may ask Max here already` |
  | `/link 123456` in A itself | `error: that code was issued here; send it in the conversation Max here is to ask` (the code is looked at before it is used, `Codes::peek`, so the slip doesn't use it up) |
  | a wrong, used or expired code | `error: no such code, or it has run out` |
  | `/unlink c#7` | `unlinked: Max here and Max in c#7 <title> can't ask each other any more`, or `skipped: no link with c#7` |
  | `/status` | `may ask   c#9 · c#12` and `asked by  c#7`, each only when there is someone |

  `/link` codes are kept apart from `/bind`'s (`code::Codes`). A isn't told
  when its code is used; its `/status` shows the edge.
- **Stored** in `links`: `asker_id`, `asked_id`, `made_at`, keyed by the pair.
  Mutable, like `conversation_settings`; the commands that changed it are rows
  of the ledger. No rule derives edges: on QQ a person's openid differs per
  group and in private chat, so even "a person's private chat may ask the
  groups they're in" can't be derived.
- **Names**: a conversation's handle is `c#N`, shown with
  `conversations.title` when there is one (`links::Peer`). A group's actor asks
  QQ's `info` for the group's name once as it starts, in a `side` task, and
  stores it as the title (`Conversation::learn_title`); a failure is only
  logged, and a renamed group is known by its new name after max restarts. A
  private chat on QQ has no name (see [The official QQ bot](qq.md#inbound)), so
  it is told apart by its number; how to name one is open. A title is a name
  its people chose and goes into what Max is shown, so it is one line,
  control characters as spaces, cut at 40 characters.
- **Tools** (`service/ask.rs`): `ask({ to, question })` returns
  `{ asked: "c#9 <title>" }` at once, and the answer wakes Max later;
  `to` is the conversation's number. `answer({ to, text })` answers question
  `ask#N` by its number and returns `{ to: "c#7 <title>" }`. A question or
  answer is at most 2,000 characters (`ASK_CHARS`), and a longer one is
  refused, not cut. A program in the VM can call both, as any tool; an agent
  asks its own Max with `maxx agent ask`, and another conversation with `maxx
  ask`, whose answer wakes Max.
- **Neither is said in a chat.** A question and its answer reach the other
  side's Max as a wake's item, shown to the model alone, like an agent's
  report. Nothing is a row of the ledger or goes to QQ:

  | Conversation | When | Item |
  | --- | --- | --- |
  | B | the question arrives | `[ask#5 问] c#7 <title>`, the question, and a line saying to answer with `answer` in this turn, that the asker hears it wasn't answered if the turn ends first, and that neither goes to the chat |
  | A | the answer arrives | `[回答] c#9 <title>`, then `问：` the question again and `答：` the answer |
  | A | it can't be asked, or B's turn ends or B is stopped before answering | `[没答成] c#9 <title>：<why>`, then the question |

  A's `ask` and B's `answer` are tool calls in their own transcripts. The
  answer's item repeats the question because nothing in A kept it, and the core
  that asked may be gone. The chats' people see nothing unless Max says so.
  What was asked and answered is in the turns' records (`turns.trigger`,
  `turn_outcomes.run`), not where `history` and `maxx events` look.
- **What Max is told**: the conversations it may ask are listed in the volatile
  block after the people, under `[能问的会话]`, a line each, read from `links`
  when a core starts (none, no block), so the system prompt stays the same for
  every conversation, and an edge made during a core shows from the next
  (`ask` checks the edge when called). The tools' guides say the rest; when to
  ask and what to answer is Max's to judge on each side.
- **The transcript stays append-only**: a question or an answer reaches a
  running core as a wake's item at the end of its input
  (`Conversation::wake_with`), or starts a core among its first inputs. B's wake
  has the reason `asked`, A's `answered`.
- **Nothing waits and nothing is timed.** A keeps nothing of a question: no
  number, no job, no timer. The question carries who asks and whom, and B's
  actor keeps it, numbered `ask#N`, for as long as the core that read it runs
  (`actor/asking.rs`); that entry is all that lets B's Max reach A, with one
  answer. The answer goes back through the table (`Signal::Heard`), which starts
  A's actor if needed and wakes A's Max with the question and the answer. When
  B's core ends with the question unanswered (idle window, killed, failed),
  B's actor answers for it as on `/stop`: A hears `[没答成] c#9 <title>：Max there
  ended its turn without answering`, and whether to ask again is A's to judge.
  An `answer` to a number not kept (answered, or from an earlier turn) is
  refused.
- **No answer**: A hears why, as `[没答成] …`. B can't be asked when it is
  stopped, Max is restarting there, or Max serves no chat of B (B's Max isn't
  told of such a question); or B was asked and didn't answer. Only a restart of
  max is silent: it forgets what B kept. A conversation A has no edge to and one
  that doesn't exist are refused alike, so asking tells nothing of which exist.
- **Not done**: a chain of origin when B asks C to answer A; files, which can't
  cross from one `/work` to another; derived edges; any record in the ledger.
