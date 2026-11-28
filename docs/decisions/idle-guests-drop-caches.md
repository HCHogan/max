# Idle guests drop their caches; the VMs' sizes stay

An idle guest gives its page cache back to the host, while the VMs' sizes
and their idle shutdown stay as they are. The design is in
[Resources](../design/vm.md#resources).

## Context

A VM's memory is allocated on use, and pages the guest frees go back to
the host by the balloon's free page reporting. A guest's page cache
doesn't count as free memory, so reporting never returns it, and it stays
until the VM's idle shutdown. Nor does the guest forget the files it has
looked up, each of which the store's virtiofsd holds open on the host.

Measured on tank over a week: at most 7 VMs ran at once, usually 1 to 4;
the 7 used 0.8 to 5.7 GiB each, with virtiofsd holding another 4.3 GiB,
the store virtiofsd of one private chat with 1.67 million open
descriptors after a scan of the store; CPU and memory pressure on the
host were near 0.

## Decision

A guest drops its caches and compacts its memory once nothing of Max's
has run in it for 10 minutes, and every 10 minutes after while it stays
unused, so the freed blocks go back to the host. A timer in the guest
does it. The VMs' size (8 vCPUs, 16 GiB, 64 GiB disk), the two-hour idle
shutdown and the 32 slots stay. Balloon resizing and hot-plug aren't
used.

## Why

- **Dropping the cache is all a smaller limit would do.** Idle vCPUs cost
  nothing and memory is allocated on use, so shrinking a VM's limit only
  forces the guest to drop its cache, which dropping it directly does
  without an API socket and without something on the host to decide the
  sizes.
- **The timer is the guest's**, since a VM outlives max and what runs in
  it is the guest's systemd's to keep.
- **Ten quiet minutes, not a quiet moment.** A moment with nothing
  running can fall between two calls of a turn, and dropping the cache
  then makes the second read from disk what the first had just written.

## Cost

- A VM that is busy for hours keeps its page cache for as long, up to its
  16 GiB.
- The first call after a quiet spell reads from disk again.
- Each VM pays for its size whatever it uses: the guest's kernel keeps
  some 390 MiB for a 16 GiB machine.
