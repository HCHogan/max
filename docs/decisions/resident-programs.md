# Resident programs are systemd units Max writes

What Max keeps running in a group (a reminder, a watcher, a listener) is an
ordinary systemd unit that Max writes in the group's VM. The design is in
[Resident programs](../design/jobs.md#resident-programs).

## Context

Max needs things that keep running: reminders, checking CI or a page every
few minutes, a listener that stays connected. The Haskell version's monitor
had four kinds, each built by itself: cron, message matching, external
polling and HTTP.

## Decision

A general mechanism instead: Max writes ordinary systemd units in the
group's VM and combines what the sandbox has. A `.timer` is cron, a `.path`
watches files, `Restart=` handles crashes. The units live in
`/work/.max/systemd/`, which is the registry, as the memory file is: no
table, no tool. The host only keeps a VM with units running, takes its wakes,
and later gave programs the tools and the chat's stream.

## How it was built

1. **Units follow `/work`**: `max-units` installs them at boot
   and when Max asks, with `max.units=off` as the escape hatch.
2. **The host side**: kept VMs, waking Max, and counting boots
   that fail. At first through a second vsock port, 7778, taking one line of
   JSON per connection (`{"wake": "…"}` or `{"units": 2}`); waking was capped
   at 6 an hour per group, with further wakes held for the hour's end.
3. **Programs call tools with `maxx`**: a call without a token
   was a resident program's, outside any turn, with a subset of tools at first;
   `say` and `wake` exist only for programs. Port 7778 went: `/units` joined the
   same service as the tools.
4. **`maxx events`**: a program reacting to the chat could only
   poll `history`; a ping-responder Max wrote in one group queried
   every 2 seconds, about 19 calls a minute through the actor to the
   database, and split rendered lines with regular expressions that break
   silently when the format changes. The stream replaced that. (Max was asked
   to move its own program to it; it is Max's, in the group's `/work`.)

Later came rows as data, so that programs needn't parse rendered text: the
first thing a turn running in the guest would need.

## What was learned in use

- **The home is `/work`**: systemd set no `HOME` for
  units without `User=`, so `bash -lc` ran without one and `/etc/profile`
  built a PATH from entries hanging off `/`, and a `/root` on tmpfs would lose
  every dotfile at boot. Not a second persistent `/root`: the host reads only
  `/work`, and with two persistent directories Max would have to remember
  which the host sees; renaming the mount would break every script and unit
  that hard-codes `/work`. Max already used `/work` as its home, and tank's
  disk had 11T free, so caches do no harm and stay warm.
- **Links aren't units**: a unit file that was a link ran and
  kept the VM on, but after a restart max, counting only files, didn't boot
  that VM, and the program quietly stopped.
- **Kept slots** went from 4 to 12 on tank, when the 4 were full (three
  groups and a private chat) and friends were to use Max as a personal
  agent; tank had 62 GiB, and idle VMs drop their caches.
- **vm-check's own directory**: sharing max's, a hand-run
  vm-check on the last slot started a second instance of a VM max already
  ran, deleting its "leftover" sockets and binding its own; the second
  instance's virtiofsd and cloud-hypervisor failed on locks, but the running
  VM's sockets had been replaced, so its guest lost the host and max couldn't
  open new SSH connections into it, until a restart.
- **No limit on wakes**: Max wanted to play chess move by move,
  and every move needs a wake. A program waking Max constantly is invisible
  in the group (Max can answer `[silence]` each time), so the count in the
  hour is shown with each wake instead.
- **Unfilled ids in `say`**: shells
  swallowed JS's `${…}` into nothing in programs Max wrote through the shell,
  and three programs sent `[reply#]` and the like into the chat. First a
  scanner of its own refused them, judging ids by a list of words and
  refusing examples in code too; now the segmenter's parser notes them, so
  the check agrees with what is sent.
- **A `say` goes out whole**: messages were sent one at a time,
  each waiting for its receipt, and once the actor came to drop calls nobody
  waits for, a `say` given up on partway would have lost the rest.
- **Calls nobody waits for are dropped**: only the wait had
  been limited; the call went on after the program was told it timed out, and
  nothing limited how many ran at once.
- **Lifetimes moved to the guest**: with every call the VM's,
  there is no token to leave out, and a turn's tools mark their rows as
  programs' do.
