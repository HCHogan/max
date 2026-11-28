# Resident programs are systemd units Max writes, with every tool

What Max keeps running in a conversation (a reminder, a watcher, a
listener) is an ordinary systemd unit that Max writes in the
conversation's VM. Its programs may call every tool, and nothing caps how
often. The design is in
[Resident programs](../design/jobs.md#resident-programs).

## Context

Max needs things that keep running: reminders, checking CI or a page
every few minutes, a listener that stays connected, a game played move by
move.

## Decision

- **Units, not kinds.** Max writes ordinary systemd units and combines
  what the sandbox has: a `.timer` is cron, a `.path` watches files,
  `Restart=` handles crashes.
- **The directory is the registry.** The units live in
  `/work/.max/systemd/`, as the memory is a file: no table, no tool. The
  host keeps a VM with units running, and counts boots that fail.
- **The home is `/work`**, for units as for Max's commands.
- **A unit file is a file.** A link in the directory isn't installed and
  doesn't keep the VM on.
- **Programs call the tools with `maxx`**, every one of them, plus `say`
  and `wake`.
- **No caps**: none on what programs send in an hour, none per run on any
  tool, none on how often a program wakes Max.
- **`maxx events`** gives a program the chat as a stream, and rows as
  data.
- **A `say` goes out whole**: all its messages are handed over before any
  receipt is awaited. A `say` with an id left unfilled sends nothing.
- **A call nobody waits for is dropped.**
- **vm-check has a directory of its own.**

## Why

- **A general mechanism costs the host the least.** A monitor with kinds
  (cron, message matching, polling, HTTP) is each kind built by itself;
  systemd has them all, and the model knows it.
- **`/work` as the home.** systemd sets no `HOME` for units without
  `User=`, and a `/root` on the tmpfs would lose every dotfile at boot. A
  second persistent directory would have Max remember which one the host
  sees, since the host reads only `/work`; renaming the mount would break
  every script and unit that names `/work`. Caches there do no harm and
  stay warm.
- **Links don't count**, so that what runs and what max counts when it
  decides which VMs to keep on are the same thing.
- **Every tool**: the programs are written by Max, and what they do is
  Max's decision, as muting and recalling are left to Max's judgement.
- **No caps**, because a cap is met by honest use first. A program that
  sends one board picture a move uses up 30 messages an hour before a
  game is over, and Max then has the program wake Max to send for it,
  which costs more than no cap; raising the cap only moves the limit. A
  program that sends too much shows at once in the group: someone says
  so, and Max stops it. QQ's own limit of 20 a minute is the backstop.
- **No limit on wakes** either: a game played move by move needs a wake a
  move. Every wake is a row in the record, there to read.
- **A stream, not polling.** A program that reacts to the chat by polling
  `history` asks every couple of seconds, some 19 calls a minute through
  the actor to the database, and splits rendered lines with regular
  expressions that break silently when the format changes.
- **Unfilled ids are refused** because shells swallow JS's `${…}` into
  nothing in programs written through the shell, and `[reply#]` then goes
  into the chat as text. The segmenter's own parser notes them, so the
  check agrees with what is sent.
- **Whole, and dropped.** Sent one at a time, each waiting for its
  receipt, a `say` given up on partway would lose the rest. And a call
  that runs on after its program was told it timed out is work for
  nobody, with nothing to limit how many run at once.
- **vm-check apart.** In max's own directory, a vm-check run by hand
  could start a second instance of a VM max already runs and replace its
  sockets, cutting the running guest off from the host.

## Cost

- A runaway loop can use up a group's daily quota within an hour, after
  which Max can't speak there; and `web_search` is charged per call, so a
  search in a loop costs money.
- A program that wakes Max constantly is invisible in the group: Max can
  answer `[silence]` each time. `/status` shows the hour's count.
- Nothing tells Max when the kept slots are full: its VM then stops when
  idle, its units with it, and they start again at its next boot.

## Alternatives

- **A monitor with kinds**: see Why.
- **A subset of tools for programs**, withholding muting and recalling
  lest a program act on members without Max's judgement, and whatever
  spends money. A program is Max's own writing, and everything in a VM is
  one caller.
- **Caps**: so many messages an hour for programs, so many calls a run
  for each tool, so many wakes an hour with the rest held. See Why.
- **A port of its own for programs to wake Max and report their units**,
  a line of JSON a connection. The tools' service does it.
