# A new image restarts its VMs

max attaches only to a VM that booted the image max boots itself. A
deploy that brings a new guest image stops the VMs that run, and each
boots the new one when it is next needed. No guest is switched where it
runs, and no number says which guests a max can talk to. What runs is in
[A VM outlives max](../design/vm.md#a-vm-outlives-max).

## Context

A VM outlives max, so that a deploy of max doesn't end the background
commands, agents and resident programs in it
([what runs in a VM is systemd's to keep](lifetimes-to-systemd.md)). That
leaves VMs older than the max that attaches to them, and a guest and max
say a good deal to each other: the arguments of `maxx`, the line a call
prints, the runner's input, the routes a guest calls.

What changes, measured over ten days: of 116 commits, 98 left the image
as it was. When the image does change it is for its scripts or for
nixpkgs; a change to the scripts is most often a change to what the two
say, and a move of nixpkgs most often brings a kernel.

## Decision

- `boot.json` keeps the image a VM booted: the path of the guest's
  description in the configuration. When max attaches, a VM whose image
  isn't the one max boots is stopped, as one without a record is. It
  boots again when a call needs it, and at once if it is kept on.
- The image's path stands for everything a guest and a max say to each
  other, and changes by itself with any change to the guest.

## Why

- **The image is the version.** Both ends of what a guest says come from
  one build, so nothing a guest's scripts, hooks or files hold is read by
  another image's.
- **Nothing to remember**: no number to raise, no mark on a unit.
- **Most deploys aren't touched.** max changes far more often than the
  guest, and a deploy of max alone attaches as before.
- **Nobody needs more.** Max serves a few chats of people who know each
  other, and none needs its VM up through a deploy.

## Cost

- A deploy that changes the guest's image ends every background command
  and agent that runs, in every chat, and tells nobody: Max waits for a
  `[max-job-… 完成]` that doesn't come. Resident programs start again
  with the boot, as they are written to; the browser's tabs are gone, and
  its logins stay.
- Any change to a file of the guest's is such a deploy, a comment's too.
- What the host gives a VM at its boot (the link its calls come by, the
  launcher, the command line) isn't the image's. A change to it reaches a
  running VM only at its next boot, and a deploy that can't wait stops
  the VMs by hand.

## Alternatives

- **A contract number and a switch in place.** The number is in the
  guest's image and in the record of each boot, raised by hand with any
  change to what the two say; a VM with max's number on an older image
  has its guest moved to the new system with `switch-to-configuration
  test`, its jobs running through it. The switch saves one reboot in one
  case, a new image with the old kernel, the old initrd and the old
  number, and that case hardly comes: the number was raised on each of
  the six days in ten that the image changed, and of 25 VMs attached to
  over three days none was switched. What it costs is there all the time:
  - every change to the guest's side is a change to three ages of code at
    once, the image a job started under, the image whose hooks end it
    after a switch, and the max that talks to both;
  - a unit of the guest's that mustn't restart under running work carries
    `restartIfChanged = false`, and one that forgets it is restarted
    under a job at some later deploy;
  - the host keeps a root for every image a VM was switched to, and a
    state for a VM that isn't whole on its image;
  - a change that forgets to raise the number is found in a running
    group.
- **The number without the switch**: a VM on an older image with max's
  number runs on until it is quiet, and boots the new one then. It keeps
  jobs through a change of image, and keeps the number, its rule, and old
  guests that talk to a new max.
- **VMs that end with max**, the VM's unit a part of max's: no attaching
  at all. max restarts several times a day while it is worked on, and
  each restart would end agents that run for hours.
