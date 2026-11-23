# Jobs: agents, commands, programs and questions

What runs apart from a turn: background agents, background commands and
resident programs, all units of the guest's systemd that max keeps no
state about, and questions between conversations, which live only as long
as the turn that read them. Why lifetimes are the guest's is in
[decisions/lifetimes-to-systemd.md](../decisions/lifetimes-to-systemd.md).

## Background agents

Work of many steps runs apart from the turn, as an agent of Max's: pi, in
the group's VM, on a task Max wrote for it, for hours if need be, while Max
goes on in the chat. An agent is a background command (below) that runs
pi; it has no tool of its own, and max keeps nothing of it. Why is in
[decisions/agents-are-background-commands.md](../decisions/agents-are-background-commands.md).

- **Running one**: Max runs, with `shell` and `background`, `cd <dir> &&
  pi -p --session-id <name> <<'EOF'`, the task, and `EOF`. pi works in
  print mode until it settles, and prints its last text, the report. The
  unit is a background command's, `max-job-…`: its limit (6 hours, or
  `timeout_ms` up to 24), its output in `/work/.max/out/`, and its line in
  `systemctl list-units 'max-job-*'`. The session's name is Max's, one for
  each piece of work.
- **The end** is the background command's notice: `[max-job-… 完成] $ cd
  /work/max && pi -p --session-id review-pr-25 <<'EOF'`, the exit status,
  the end of what pi printed (the report, or why its last model call
  failed) and the output's file. The title is the command's first line, so
  the notice says which directory and session it was, and a turn that
  didn't start the agent can go on with it. At its limit or when stopped
  (`systemctl stop`, `/kill`), pi exits at once with no report, and at most
  `Request aborted` for the model call it was in: the
  notice at the limit says it is out of time, and a stop tells nobody.
- **Going on**: the same `--session-id` in the same directory goes on with
  the agent's whole conversation, all it read and did, and then the new
  task: an answer to its question, more to go on, a change of direction, a
  redo, or work that ran out of time. A running agent can't be told
  anything: Max stops it and runs it again, and the step it was in is lost.
  The run may name another model or effort; `--fork <id>` takes the
  conversation into another directory.
- **Questions**: an agent stuck on what only Max or the people know decides
  what it can and says in its report what it assumed; when it can't go on,
  its last words are the question, and the run ends. Max answers by running
  it again. Nothing holds an agent for an answer. To ask another
  conversation, the agent runs `maxx ask` as Max would; the answer wakes
  Max, who passes it on.
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
    no agents. The guest's pi writes it into its own files (below).
  - `pi --list-models` lists the models with their windows, and `--model
    <name>` and `--thinking <level>` run an agent on another. There is no
    list of models agents may use: whatever `/model` offers a turn, an
    agent can run on, priced ones too.
  - **No sessions**: `/llm` takes any call on a VM's socket, and nothing
    knows which agent called. So anything in the VM can spend on any
    configured model, which is accepted, as the VM is the group's own and
    its programs could always run an agent.
- **Usage** isn't recorded: max (`service/forward.rs`) passes a
  call on and its answer back without reading what it used, and `/status`
  shows what Max's own calls used. What the agents spend is in the
  provider's records, for all the groups together; why is in
  [decisions/forwarder-keeps-no-count.md](../decisions/forwarder-keeps-no-count.md).
- **Tools**: an agent is a program, which calls every tool with `maxx` from
  its shell (`maxx history`, `maxx web-search`, `webread`), with no tools of
  its own on the host. It could speak in the chat too; its system text tells
  it not to, and nothing enforces that.
- **No limits of their own**: as many run at once as background commands
  do, and each has its unit's time.
- **What max shows**: `/status` lists no agents; the guest's systemd lists
  them with the other background commands, by their command lines.
  `agent#3` and `max-agent-3`, as agents were once named, are still read
  from the wakes the ledger kept, as the reason `job` (`Reason::Answered`'s
  alias).
- **When to hand off**: the system prompt says work of many steps goes to an
  agent, not into the turn (reading a whole repository, reviewing or changing
  code, installing, building, testing, opening PRs, reading many pages or
  files); Max says in the chat that it has taken it on and about how long it
  will take, then runs pi. The prompt says how: the command, a new name for
  each piece of work, the models, what the task must carry since the agent
  doesn't see the chat, and going on with the same name and directory,
  stopping a running one first. What a few steps answer, it does itself.
- **Project directories**: the directory is the one Max goes into; the VM,
  not the directory, is the boundary. pi reads the directory's `AGENTS.md`
  or `CLAUDE.md`, and its parents', and `~/.pi/agent/AGENTS.md`; a
  project's `.pi/` is trusted only with `--approve`.

### pi in the VM

`pi` on the guest's PATH is the pinned pi behind a wrapper,
`nix/pi.sh`, so that anything in the VM can run it on max's models
without a key:

- **Models**: before each run the wrapper asks `GET /llm` and writes every
  model max serves into pi's `models.json`, in `~/.pi/agent` under `/work`,
  as a model of the provider `max`: by max's name for it (`--model
  cliproxy/gpt-5.6-luna`, or `max/cliproxy/gpt-5.6-luna`), over its
  protocol, with its window and output limit. Any may be asked to think,
  and `xhigh` and `max` go as they are. Into `settings.json` go the
  agents' default model and effort as pi's defaults, `off` without an
  effort (pi then sends none), and at least 8 retries, to outlast a restart
  of max. The rest of both files, and of the directory, is whoever's runs
  pi. With max out of reach a run goes on with what an earlier one wrote.
- **System text**: `nix/pi-system.md`, as the directory's
  `APPEND_SYSTEM.md`, after pi's own prompt: it is Max's background agent
  and doesn't see the chat; `maxx history`, `maxx web-search` and
  `webread`; not to speak in the chat; its last message is its report; to
  decide what it can and say what it assumed, and to end with its question
  when it can't go on; the environment; that it is stopped at its limit
  with nothing reported, so long work keeps what it has in files.
- **Sessions** are a directory's: `--session-id ID` starts a session by
  that name, or goes on with the current directory's. The wrapper refuses
  an id pi keeps only for other directories, with status 2 and where it
  is: pi would start a new session by that name, saying so only on stderr.

### What the guest's pi relies on in pi

Checked with pi 1.6.0:

- Print mode writes the last text to stdout and exits 0; when the last
  model call fails it writes the error to stderr and exits 1. The session
  is kept either way. A background command's unit writes both to its
  output file.
- pi exits at once on SIGTERM, with status 143 and nothing on stdout; a
  model call under way leaves `Request aborted` on stderr, which the unit
  writes to the output file with the rest.
- Standard input that isn't a terminal goes before the first prompt, so a
  heredoc is the task; as an argument, a leading `@` would be read as a
  file.
- `--session-id ID` takes the current directory's session of that name or
  makes one, warning on stderr; the id is letters, digits, `-`, `_` and
  `.`. Sessions are in the agent directory's `sessions/`, a directory for
  each working directory; with `--session-dir` they are all in that one,
  and pi still takes an id only for the working directory's. `--session
  <id>` from another directory asks on standard input whether to fork it,
  which a background command's empty input answers no, and exits 0 having
  done nothing; the prompt doesn't use it. `--fork` copies a session into
  the current directory.
- A model of `models.json` takes its own `api`. One with `reasoning` is
  sent `reasoning_effort` as the thinking level says, none for `off`, and
  `xhigh` and `max` as `thinkingLevelMap` maps them; one without is never
  sent any. `defaultProvider`, `defaultModel` and `defaultThinkingLevel` in
  `settings.json` stand when the command line names none, and a model is
  found by its id alone too.
- `APPEND_SYSTEM.md` in the agent directory goes after pi's own prompt; a
  project's `.pi/APPEND_SYSTEM.md` would take its place, but print mode
  trusts a project's `.pi/` only with `--approve`. Context files load
  whatever the trust.
- pi retries a failed model call 3 times by default, about 14 seconds in
  all; `retry.maxRetries` gives it longer. A call that a restart of max
  cuts off fails once: the next try waits at max's socket for the max that
  comes.

pi comes from numtide's llm-agents.nix, pinned in the flake. So
`scripts/check-pi` runs after moving the pin or changing `pi.sh` or
`pi-system.md`: the wrapper with the pinned pi against a fake `/llm`, for
the default model and effort, the system text, another model by max's
name, going on with a session, the refusal in another directory, max out
of reach, and the rest of pi's files kept. What surrounds pi is in the
NixOS test `checks.<system>.jobs`, and `max vm-check` runs one agent in a
real VM against a provider of its own.

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
  boot adds `max.units=off`, and Max is told (`Heard::Vm`, `[VM] …`). A VM
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
  background command, an agent among them; `ask`, `answer` and `wake`. VM notices are dropped.
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
prompt's own prose, the notices Max is shown and their tags (`[max-job-…
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
  asks its own Max with its last words, and another conversation with `maxx
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
