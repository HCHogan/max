# A guest reset ends its VM

A guest that reboots, or whose kernel panics, isn't booted again in place:
the VM's unit ends at once, and max boots the VM again when it is next
needed, as it does any VM that stopped by itself. What runs is under
[Starting a VM](../design/vm.md#starting-a-vm).

## Context

The guest's kernel command line has `reboot=t panic=-1`: a reboot and a
panic both end in a triple fault, which cloud-hypervisor takes as a reset.
It answers a reset by making the VM again in the same process, with every
device connected anew.

The two virtiofsd beside it each serve one connection and end when it
closes, and nothing starts another. Left to itself, the VM that
cloud-hypervisor makes again waits a minute for a virtiofsd that isn't
there before it gives up and fails. In the nested test, for a reboot and
for a panic alike:

- The unit goes on running with no guest in it. cloud-hypervisor takes no
  SIGTERM while it waits.
- max finds the connection gone at its next sweep, tries to attach for
  ten seconds, since the unit still runs, fails, and stops the unit. A
  call that finds the connection gone goes the same way, and is told the
  VM didn't start.
- A kept VM is down for about two minutes.

## Decision

The launcher runs each virtiofsd so that cloud-hypervisor is killed when
it ends. A reset then leaves a unit that has ended, within a second, and
max takes the path it already has for one: nothing to attach to, so the
call that found it boots the VM again and waits for that.

## Why not a reboot in place

It would take a virtiofsd that comes back for each new connection, and a
max that waits out a boot where it gives a guest that should be up ten
seconds.

And max would not see the reset. A unit of Max's that reboots the guest
or panics its kernel at every boot would do so for ever; with the VM
ended each time, max counts the ends, and after two the next boot comes
without Max's units (see
[Kept on, woken, failing](../design/jobs.md#kept-on-woken-failing)).

Ending the VM also covers a virtiofsd that fails by itself, which
otherwise leaves a guest that hangs on its files under a unit that runs.

## Cost

- A reboot counts as a VM that stopped by itself, Max's own reboots among
  them: two within 30 minutes and the next boot is without Max's units,
  with a notice that blames a unit.
- A kept VM nobody calls still waits for the sweeps: up to a minute until
  max finds it ended, and a minute more until it boots.
- Nothing tells Max that the background commands and agents which ran in
  the guest are gone, and a panic's trace isn't kept: `serial.log` holds
  the boot that runs, emptied by cloud-hypervisor as the guest resets.
