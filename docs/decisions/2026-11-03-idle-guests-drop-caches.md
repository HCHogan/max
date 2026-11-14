# Idle guests drop their caches; the VMs' sizes stay

2026-11-03, with the wait restored on 2026-11-13. The design is in
[Resources](../design/vm.md#resources).

## Context

A guest's page cache doesn't count as free memory, so the balloon's free
page reporting never returns it, and it stayed until the VM's idle
shutdown (the owner's choice on 2026-10-30: a VM normally uses 1 to 2 GiB,
and memory is tight only when several groups build at once).

Data from tank on 2026-11-03: over a week, at most 7 VMs ran at once,
usually 1 to 4; the 7 used 0.8 to 5.7 GiB each, with virtiofsd holding
another 4.3 GiB, the store virtiofsd of one private chat with 1.67 million
open descriptors (someone had scanned the store again); CPU and memory
pressure on the host were near 0.

## Decision

A guest drops its caches and compacts its memory once nothing of Max's has
run in it for 10 minutes, and every 10 minutes after while it stays
unused, so the freed blocks go back to the host. The VMs' size (8 vCPUs,
16 GiB, 64 GiB disk), the two-hour idle shutdown and the 32 slots stay.
Balloon resizing and hot-plug aren't used.

## Adjustments

- At first the host had the guest drop its caches over SSH once a VM had
  gone unused for 10 minutes. With lifetimes moved to the guest on
  2026-11-12 it became a timer in the guest, which for a day asked only
  that nothing ran at that moment: that could fall between two calls of a
  turn and make the second read from disk what the first had just written.
  On 2026-11-13 the owner had the 10-minute wait back (`maxx units idle
  600`).
