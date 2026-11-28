# Jobs: agents, commands and programs

What runs apart from a turn: background agents, background commands and
resident programs, all units of the guest's systemd that max keeps no
state about. Why lifetimes are the guest's is in
[decisions/lifetimes-to-systemd.md](../decisions/lifetimes-to-systemd.md).

## Background agents

Work of many steps runs apart from the turn, as an agent of Max's: fx, in
the group's VM, on a task Max wrote for it, for hours if need be, while Max
goes on in the chat. An agent is a background command (below) that runs
fx; it has no tool of its own, and max keeps nothing of it. Why, and why
fx, is in
[decisions/agents-are-background-commands.md](../decisions/agents-are-background-commands.md).

- **Running one**: Max runs, with `shell` and `background`, `cd <dir> &&
  fx ask --session <name> <<'EOF'`, the task, and `EOF`. fx works until it
  settles, printing what it says and the commands it runs as it goes, its
  report last. The unit is a background command's, `max-job-…`: its limit
  (6 hours, or `timeout_ms` up to 24), its output in `/work/.max/out/`,
  and its line in `systemctl list-units 'max-job-*'`. The session's name
  is Max's to choose.
- **The end** is the background command's notice: `[max-job-… 完成] $ cd
  /work/max && fx ask --session review-pr-25 <<'EOF'`, the exit status,
  the end of what fx printed and the output's file. That end is the
  report, after the last of what the agent said and ran on the way, or
  why a model call was refused. The title is the command's first line, so
  the notice says which directory and session it was, and a turn that
  didn't start the agent can go on with it. At its limit or when stopped
  (`systemctl stop`, `/kill`), fx exits at once with no report, and the
  output ends with the step it was in: the notice at the limit says it is
  out of time, and a stop tells nobody.
- **Going on**: the same `--session` in the same directory goes on with
  the agent's whole conversation, all it read and did, and then the new
  task: an answer to its question, more to go on, a change of direction, a
  redo, or work that ran out of time. A running agent can't be told
  anything: Max stops it and runs it again, and the step it was in is
  lost, which the agent is told. The run may name another model or
  effort.
- **Questions**: an agent stuck on what only Max or the people know decides
  what it can and says in its report what it assumed; when it can't go on,
  its last words are the question, and the run ends. Max answers by running
  it again. Nothing holds an agent for an answer.
- **Models.** `job = { model, effort }` in `[llm]` is the agents' default;
  without it there are no agents. fx holds no key: its calls go to
  `http://127.0.0.1:7777/llm/<endpoint>`, where max sends a
  call that names a configured model (`provider/model`, as `/model` names
  them) to that provider and any other to the agents' own, replaces `model`
  with the provider's id, adds the provider's key and headers, and passes
  the rest on as fx wrote it; the answer streams back unchanged. A provider
  quiet for `stream_idle_timeout_secs` is cut off, and fx tries again. Only
  the endpoint of the model's protocol is accepted.
  - `GET /llm` says what a harness must know before it calls: `{api, model,
    window, max_output, effort}` for the agents' own, and under `models` the
    same for every configured model, without the effort; 404 when there are
    no agents. `api` is `openai-chat-completions` or `openai-responses`.
    The guest's fx writes it into fx's settings (below).
  - `fx models` lists the models with their windows, and `--model <name>`
    and `--effort <level>` run an agent on another. There is no list of
    models agents may use: whatever `/model` offers a turn, an agent can
    run on, priced ones too.
  - **No sessions**: `/llm` takes any call on a VM's socket, and nothing
    knows which agent called. So anything in the VM can spend on any
    configured model, which is accepted, as the VM is the group's own and
    its programs could always run an agent.
- **Usage** isn't recorded: max (`service/forward.rs`) passes a
  call on and its answer back without reading what it used, and `/status`
  shows what Max's own calls used. What the agents spend is in the
  provider's records, for all the groups together; why is in
  [decisions/guests-reach-max-directly.md](../decisions/guests-reach-max-directly.md).
- **Tools**: an agent is a program, which calls every tool with `maxx` from
  its shell (`maxx history`, `maxx web-search`, `webread`), with no tools of
  its own on the host. It could speak in the chat too; its system text tells
  it not to, and nothing enforces that. fx's own tools are its to use: the
  shell, files, and agents of its own within the run, which report to it
  and end with it.
- **No limits of their own**: as many run at once as background commands
  do, and each has its unit's time.
- **What max shows**: `/status` lists no agents; the guest's systemd lists
  them with the other background commands, by their command lines.
  `agent#3` and `max-agent-3`, as agents were once named, are still in
  the wakes the turns' records kept, with the reason `job`; nothing reads
  a record's reason back.
- **When to hand off**: the system prompt says work of many steps goes to an
  agent, not into the turn (reading a whole repository, reviewing or changing
  code, installing, building, testing, opening PRs, reading many pages or
  files); Max says in the chat that it has taken it on and about how long it
  will take, then runs fx. The prompt gives the command, the models, and
  what the task must carry since the agent doesn't see the chat. Of
  sessions it says what is so and leaves the rest to Max: a name used
  before in a directory goes on with that conversation and a new one
  starts another; a running agent hears nothing new, and can be stopped,
  which reports nothing and loses the step it was in, with the
  conversation kept. What a few steps answer, Max does itself.
- **Project directories**: the directory is the one Max goes into; the VM,
  not the directory, is the boundary. fx reads the directory's `AGENTS.md`,
  and its parents' below `/work`.

### fx in the VM

`fx` on the guest's PATH is the pinned fx behind a wrapper,
`nix/fx.sh`, so that anything in the VM can run it on max's models
without a key:

- **Models**: before each run the wrapper asks `GET /llm` and writes every
  model max serves into fx's `settings.json`, as models of two custom
  connections, `max` for Chat Completions and `max-responses` for
  Responses, since a connection of fx's has one protocol: each by max's
  name for it (`--model cliproxy/gpt-5.6-luna`), with its window and
  output limit, and the efforts it may be asked for, `minimal` to `max`
  and the one max names. The agents' default goes in with its effort,
  and a run that names a model is passed that model's connection,
  `--provider`.
  fx waits 15 minutes for an answer to start or to go on, longer than max
  waits for a provider, so that max is the one to give up on a call.
  With max out of reach a run goes on with what an earlier one was told,
  kept in `~/.max/fx/about.json`. `fx models` is the wrapper's own, from
  the same answer: fx's lists one connection's models.
- **System text**: `nix/fx-system.md`, as `AGENTS.md` in the fx home,
  after fx's own prompt: it is Max's background agent
  and doesn't see the chat; `maxx history`, `maxx web-search` and
  `webread`; not to speak in the chat; its last message is its report; to
  decide what it can and say what it assumed, and to end with its question
  when it can't go on; the environment; that it is stopped at its limit
  with nothing reported, so long work keeps what it has in files.
- **Sessions**: fx names its sessions itself, and `fx ask` goes on with
  one by fx's id or with the directory's last. So `--session NAME` is the
  wrapper's: each name has an fx home of its own,
  `~/.max/fx/sessions/NAME` under `/work`, where the directory's last
  session is that name's, and the wrapper passes `--resume last` when
  there is one. It refuses a name whose session is kept only for other
  directories, with status 2 and where it is, where fx would start anew;
  and a name that isn't of letters, digits, `-`, `_` and `.`, as it is a
  directory's. A run without a name keeps no session (`--no-save`), in
  the fx home `~/.max/fx/home`, which is also where anything but `ask`
  runs.
- **Nobody to ask**: every `ask` runs with `--full-access`, fx's
  permission checks off, as the VM is the boundary.

### What the guest's fx relies on in fx

Checked with fx 0.0.18:

- `fx ask` takes the task as its arguments, or from standard input when
  there are none, so a heredoc is the task. It writes each text the agent
  says to stdout as it comes, the report last, and to stderr the commands
  it runs with their output and its own notices; it exits 0. A background
  command's unit writes both to its output file.
- A model call the provider or max refuses (4xx) ends the run at once:
  `fx ask: API request failed · HTTP 404 · <the error's message>` on
  stderr, status 1. A call that fails otherwise (5xx, or an answer cut
  off midway) is tried again after a growing wait, 1, 2, 4, 7, 14, 29
  seconds and on, without end, each wait a `[notice]` on stderr: nothing
  caps the tries, and an agent whose provider stays down runs to its
  unit's limit. A call that a restart of max cuts off fails once: the
  next try waits at max's socket for the max that comes. The session is
  kept either way.
- fx exits at once on SIGTERM, and the command it was running is killed.
  A run that goes on shows the model that call as aborted, and a note
  that the turn was cut and what it ran may have partly happened.
- Its `shell` tool waits for a command 30 seconds, or as long as the
  model asks up to 5 minutes, and then hands it back still running, to be
  waited on again: a long build costs a model call every 5 minutes. What
  still runs when fx exits is killed.
- A session is a workspace's, the directory fx ran in, and is kept under
  the fx home, `FX_HOME`, which must be an absolute path. `fx sessions
  --json` counts the directory's, and with `--all` says each one's
  `workspace_root`. `--resume last` goes on with the directory's latest,
  and `--no-save` keeps none. A session gone on with stays on the
  connection it began on unless the run names one, `--provider`, and
  then goes on over that one's protocol with the whole conversation.
- `settings.json` in the fx home: `providers.<name>` with `protocol`,
  `base_url` (fx adds `/chat/completions` or `/responses`; plain HTTP
  for loopback only), `auth`, `timeouts` and `model_metadata`, whose
  `reasoning_efforts` maps a level's name to the request fields that ask
  for it; `provider`, `models` and `effort` stand when the command line
  names none. An effort the model doesn't declare isn't sent, with a
  notice. `yolo_acknowledged` is fx's note that full access was
  explained: without it fx writes it, and a copy of the file, each run.
- A Responses call is sent with `store: false`, its system text as the
  first item of `input`, and asks for the reasoning encrypted, which the
  next call carries back: max passes all of it on as it is.
- `AGENTS.md` in the fx home goes after fx's own prompt, and the
  directory's after that. fx reads `AGENTS.md` alone: a `CLAUDE.md` only
  as a link from one.
- With `auto_upgrade` off (`FX_AUTO_UPGRADE=0`) fx calls nothing but the
  model: checked in a network namespace with no way out.
- fx holds the agent to the task's language when the task reads as
  English: an answer in another script is asked for again once, and then
  the run fails with status 1. A task in Chinese is held to nothing. The
  same check runs on a turn that a report of fx's own agents starts.
- With a session kept, fx gives the agent a `subagent` tool, agents of
  its own in the same process and session; `fx ask` ends when they have.
  `fx ask` has no way to leave the tool out.

fx comes from numtide's llm-agents.nix, pinned in the flake's lock, which
[moves each night](../decisions/pins-move-nightly.md). fx calls itself
experimental and changes its command line and settings between releases,
so the flake's `fx` check, which `scripts/check-fx` runs by hand, is
what lets a pin move: the wrapper with the pinned fx against a fake
`/llm`, for the default model, its protocol and effort, the system text,
another model by max's name over the other protocol, going on with a
session and on another model, the refusal in another directory, the models listed, max out of
reach, and no call of anything else. What surrounds fx is in the NixOS
test `checks.<system>.jobs`, and `max vm-check` runs one agent in a real
VM against a provider of its own.

Another harness would need only a wrapper of its own that tells it of
the models from `GET /llm`: a background command is the rest.

## Background commands

A command that runs for minutes (a build, a test run, a download) needs no
other model, but inside the turn it keeps the group waiting. So `shell` has
`background`: the tool returns at once, the command runs on, and Max is
woken when it ends.

- **Everything Max runs in the VM is a unit**, a transient one in the guest's
  `max-jobs.slice`, started by `maxx jobs` (`nix/max-jobs.sh`,
  `nix/jobs.nix`): systemd limits it (`RuntimeMaxSec=`), stops it and sees it
  end. A unit is a call or a background command from its start, which its
  name says, `max-call-…` or `max-job-…` with 16 hex digits of the guest's
  choosing, and neither becomes the other. The host says what it wants as
  one JSON object (`maxx jobs run '{…}'`), and the flags are the guest
  image's. One is `--expand-environment=no`, since systemd would otherwise
  fill in every `${…}` of a command (and make `$$` a `$`) before bash saw it,
  heredoc quotes or not.
- **Each rule has one side.** The host says the limit, in seconds, and how
  much of an output a call's line carries: they are what the model's tools
  declare (`RUN_TIME`, `BACKGROUND_TIME`, `SHOWN_BYTES`). The guest names
  the unit, resolves a working directory that isn't absolute under `/work`,
  and titles the unit by the command's first line, up to 200 characters,
  unless the host gives a title, as it does for `run_code`. `maxx jobs` has
  no defaults: it refuses a call without a limit.
- **systemd keeps what a unit is**: its title is the unit's description,
  and when it began and the most it may run are the unit's own
  (`ActiveEnterTimestampMonotonic`, `RuntimeMaxUSec`). Nothing is written of
  a unit beside it. `/run/max/jobs` has a call's directory while it runs,
  and a background command's notice from its end until Max has it.
- **A call** (`maxx jobs run`) is `shell` without `background`, and
  `run_code`. The guest starts the unit, waits for its end, and prints one
  line of JSON: how systemd says it ended (`success`, `exit-code`,
  `timeout`…) and what it wrote, all of it, or 8 KiB of its head and as much
  of its tail with the file that has the whole. `tools::wait` reads that
  line. `run_code` is the same with the runner as the command,
  the program on stdin and its stderr apart. The unit writes its own output,
  under `/work/.max/out/`, kept only when the output didn't fit.
- **A call ends with its caller.** max gives `maxx jobs run` the command's
  input, as many bytes as `input` says, then holds the channel's input open,
  silent, for as long as it waits. When that input ends, the caller is gone:
  a reader beside the unit's wait stops the unit, again until it has ended,
  since it may not have started yet, and `maxx jobs run` removes what the
  call wrote and prints nothing. So a turn killed during a call stops it by
  closing the channel (dropping `ssh::Command` hands it to the VM's
  `closer`, since russh closes nothing on drop), and a call whose max
  restarted, crashed or lost its connection is stopped by the guest alone.
  Only a pipe or a socket is somebody's to hold, as max's channel is: given
  `/dev/null` for its input, a call runs to its end. If `maxx jobs run`
  itself is killed, its unit ends at its limit and the unit's hook clears
  up.
- **A background command** (`maxx jobs start`): the guest answers with the
  unit's name, `max-job-…`, and the file its output is written to as it
  runs, and the tool tells the model both with the limit (6 hours, or
  `timeout_ms` up to 24), in the host's words (`tools/shell.rs`).
- **When it ends**, the unit's `ExecStopPost=` (`maxx jobs ended`) writes
  the notice, as a wake's arguments, to `/run/max/jobs/<unit>.json`, and
  starts `max-notify@<unit>.service`, a oneshot that gives it to `maxx
  wake`: `[<unit> 完成] $ make` (the unit's title), the exit status and run
  time, the end of the output (a wake takes 4,000 characters) and the
  file's path; `到点了，下面是做到一半的` at its limit. With `Restart=on-failure` systemd retries it until
  max takes it, so a notice isn't lost while max is away, and `systemctl
  list-units 'max-notify@*'` lists those that wait. Max sees it as
  `[max-wake] [max-job-… 完成] …`. A unit stopped on request (`systemctl stop`,
  `/kill`) tells nobody, since whoever asked knows: the hook knows it by
  systemd's stop job for the unit, still there while the hook runs
  (`systemctl list-jobs`). One that ends by SIGTERM of its own is told, as
  `ended by SIGTERM`.
- **What Max does with them**: `systemctl list-units 'max-job-*'` shows what
  runs, each by its title, and
  `systemctl stop <unit>` stops one. `/kill` has the guest's systemd stop
  them all, `systemctl stop 'max-job-*.service'` (`Vm::stop_jobs`, in a task
  of the actor's `side`), a person's way to stop what runs without asking
  Max; `/status` doesn't list them.
- **The VM stays up** while one runs: every minute the VM service asks the
  guest's systemd whether any is active (`systemctl is-active --quiet
  'max-job-*.service'`, which answers by its exit status); a VM with any is
  in use and isn't evicted.
- **A working directory is checked first**, since systemd applies it to the
  unit's hook too and a unit in a missing directory would end without saying
  how; `maxx jobs` refuses it. It needn't be there at the end: the unit has
  `WorkingDirectory=-…`, so a command that removes its own directory still
  has its hook run.
- No limit on how many run at once: the VM's room bounds them. A call not
  done at its limit is stopped, and Max runs it again with `background`.
- **The prompt** says a command that will run for minutes should use
  `background`: a unit whose name comes back at once; in the same output Max
  tells the group, then stops and waits for `[max-job-… 完成]`; `systemctl
  list-units 'max-job-*'` and `systemctl stop` look at them and stop one.
- **Tests**: `nix/tests/jobs.nix` boots the guest's jobs with a fake max and
  no VM: a call's line, its limit, a long output, its input and environment,
  a background command's notice and its title, the lines max asks the
  guest's systemd, the notice that waits while max is away, and a call
  whose caller is gone. `vm-check` starts a background
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
  object. It takes a lock, so the run at boot and Max's can't collide.
- At boot `max-units.service` runs it once, after `/work`, `/tmp`, the
  network and nix-daemon are up; when Max changes the directory, it runs `maxx units
  apply` itself. Starting never blocks
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
  and that units don't read it (`Environment=` instead). A `~/.bashrc`
  can't do the same to max's own commands: sshd runs them in root's shell,
  and bash reads `~/.bashrc` for a command sshd runs, so the guest's sshd
  gives its sessions another home (`SetEnv HOME=/var/empty`). What Max runs
  has its home from systemd. Packages from `nix
  profile add` are in `/nix/var/nix/profiles/default`, persistent and on
  PATH.
- Only `/work` and the store survive: whatever a unit runs is in `/work`, a
  store path or `nix run`, and its state is written to files, since programs
  start again with every boot, and a deploy that brings a new image is one.
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
  `<vm.dir>/check`. After that the sweep reads the same directory of every
  VM that runs, each minute (`Service::sweep`): a group with unit files is
  kept on if it is already or a slot is free, and one with none isn't. The
  guest tells max nothing of its units, and nothing tells Max when the
  slots are full: its VM then stops when idle, its units with it, and they
  start again at its next boot. A kept but idle VM still drops its caches
  (see [Resources](vm.md#resources)).
- **Waking**: `maxx wake '…'` is a call of the tool `wake`, through the
  conversation table to the actor (started if not running), which the
  tool asks with `Request::Wake`. The actor
  enters the words as a row that is never sent (see
  [The timeline](ledger.md#the-timeline)), which the model sees as
  `[12:00 max-wake #45]: …`, cut to one item's cap; the row is fed to the
  running core or is the first input of a new one, and its trigger, with
  the reason `Reason::Program`. The program is told Max was woken. There
  is no limit on how often: every wake is in the record, where a turn
  that didn't see the earlier ones reads them, and Max can find which
  program it is; `/status` shows `woken`, the hour's count.
- **Failing to boot**: each time a group's VM fails to start or stops by
  itself, it is counted, kept or not. Twice within 30 minutes and the next
  boot adds `max.units=off`, and Max is told (`Signal::Vm`), in a row as
  a wake's is, `[12:00 VM #46]: …`. A VM
  that comes up so is kept on as any other whose `/work` has units, and
  runs them again once Max has fixed them and run `maxx units apply`. If it
  fails even without units, they aren't the cause: it isn't kept, and boots
  when a tool needs it rather than every minute.
- **The prompt**: an idle VM stops, except in groups with resident programs;
  anything that must keep running, run on a schedule or watch something is a
  unit in `/work/.max/systemd/` followed by `maxx units apply`; `.timer`,
  `.path` and `Restart=on-failure`; absolute paths in `ExecStart`; state in
  `/work`; `systemctl status` and `journalctl -u` to check; `maxx wake` only
  when there is genuinely something new.
- **Tests**: `vm-check` puts a unit that records the boot id in
  `/work/.max/systemd` and runs `maxx units apply`; the nested test runs it
  twice, checking the unit is active before the second boot's apply and both
  boots are recorded, and that `maxx wake` reached `vm-check`; a VM whose
  `/work` has a unit is kept on, and comes back by itself after it ends.

### Programs call tools

Programs use the same tools as Max (see [maxx](tools.md#maxx-one-command-for-everything-in-the-vm)):
a call is the VM's, whatever made it. Why programs have every tool, and no
caps, is in
[decisions/resident-programs.md](../decisions/resident-programs.md).

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
  `程序发的`; vm-check's background command runs `maxx wake`.

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
  takes; `by` is `max` or `program`, absent for members (a row that woke
  Max isn't the chat's, and isn't given); `text` is what
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
  program reads. A field that goes or changes meaning breaks the programs
  the groups keep; one more doesn't. The tool's schema names a row's
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
  `mute_member`, which asks the actor first (`Request::Act`); starting a
  background command, an agent among them; and `wake`. VM notices are dropped.
  What reads still works: `history`, the searches, `/api`, `maxx events`.
  `/start` lets them through again. See [Commands](context.md#commands).
- As Max shuts down, what starts work is refused (`Max is restarting, so this
  wasn't done`); the core still running may finish what it says.
- Looking, steering and changing a setting are never refused.

Every tool's request of the actor is one event, `Event::Request`, whose
`Request` has a kind for each thing asked (configure, wake, act), each carrying where its answer goes; `actor/requests.rs` does them once
the rule has let them through.

What the actor tells a tool or program, refusals and errors alike, is in
English, as are the tools' descriptions, guides, argument descriptions,
checks, results and failures, what the guest's commands print, and what the
VM service, the sender and the search tell a failed tool; a failure's code
follows its message in brackets, ` (not_found)`. Chinese stays in the system
prompt's own prose, the notices Max is shown and their tags (`[max-job-…
完成]`, `max-wake`, which English guides quote as they are), the timeline's
marks, what stands in for a picture left out, the agent's own prompt, and what
`vm-check` prints.
