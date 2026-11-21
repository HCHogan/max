# A new image restarts its VMs

max attaches only to a VM that booted the image max boots now. A deploy that brings a new guest image stops the VMs that run, and each boots the new one when it is next needed; no guest is switched where it runs, and there is no contract number. What runs is in [A VM outlives max](../design/vm.md#a-vm-outlives-max).

## Context

A VM outlives max, so that a deploy of max doesn't end the background commands, agents and resident programs in it ([lifetimes to systemd](lifetimes-to-systemd.md)). That leaves a VM older than the max that attaches to it, and two things kept the pair in step:

- **A contract number**, in the guest's image and in the record of each boot. A VM whose number wasn't max's was stopped at once; one with the same number ran on. It was raised by hand with any change to what the two say to each other: the arguments of `maxx`, a call's line, the layout of `/run/max/jobs`, the runner's input, the routes.
- **A switch in place.** A VM with max's number on an older image had its guest moved to the new system with `switch-to-configuration test`, with its jobs running through it. One whose kernel or initrd had changed too stayed stale, and booted again once nothing ran in it and nobody had used it for ten minutes.

The switch saved one reboot in one case: a new image with the old kernel, the old initrd and the old number. That case hardly came. An image changes for its scripts or for nixpkgs; a change to the scripts is most often a change to what the two say, and a move of nixpkgs most often brings a kernel. Over its first ten days the number was raised nine times, on each of the six days the image changed. Over three days of the deployed host's journal max started three times and attached to 25 VMs, and switched none.

What it cost was there all the time:

- Every change to the guest's side was a change to three ages of code at once: the image a job started under, the image whose hooks end it after a switch, and the max that talks to both. The layout of `/run/max/jobs` was in the contract for that alone.
- A unit of the guest's that mustn't restart under running work carried `restartIfChanged = false`, and one that forgot it would have been restarted under a job at some later deploy.
- The host kept a root for every image a VM had been switched to, a VM's state of not being whole on its image and a sweep's rule for it, and the guest's system and registration in what the flake says of an image.
- The number was raised by whoever changed either side, and a change that forgot it was found in a running group.

## Decision

- `boot.json` keeps the image a VM booted: the path of the guest's description in the configuration. When max attaches, a VM whose image isn't the one max boots is stopped, as one without a record is. It boots again when a call needs it, and at once if it is kept on.
- No switch: `max-switch`, the system and registration in the guest's description, the stale state and its rule, the roots of switched images and the `restartIfChanged` marks in the guest are gone.
- No contract number. The image's path stands for everything a guest and a max say to each other, and changes by itself with any change to the guest.

## Why

- **The image is the version.** Both ends of what a guest says come from one build, so nothing a guest's scripts, hooks or files hold is read by another image's.
- **Nothing to remember**: no number to raise, no mark on a unit.
- **Most deploys aren't touched.** max changes far more often than the guest: of the 116 commits of those ten days, 98 left the image as it was, and a deploy of max alone attaches as before.
- **Nobody needs more.** Max serves a few chats of people who know each other, and none needs its VM up through a deploy.

## Alternatives

- **The number without the switch**: a VM on an older image with max's number runs on until it is quiet, and boots the new one then. It keeps jobs through a change of image, and keeps the number, its rule, and old guests that talk to a new max.
- **VMs that end with max**, the VM's unit a part of max's: no attaching at all. max restarts several times a day while it is worked on, and each restart would end agents that run for hours.

## Cost

- A deploy that changes the guest's image ends every background command and agent that runs, in every chat, and tells nobody: Max waits for a `[max-job-… 完成]` that doesn't come. Resident programs start again with the boot, as they are written to; the browser's tabs are gone, and its logins stay.
- Any change to a file of the guest's is such a deploy, a comment's too.
- What the host gives a VM at its boot (the link its calls come by, the launcher, the command line) isn't the image's. A change to it reaches a running VM only at its next boot, and a deploy that can't wait stops the VMs by hand.
