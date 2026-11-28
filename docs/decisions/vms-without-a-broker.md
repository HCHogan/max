# The VMs run without a broker or root

The VMs run as an ordinary user, with no root process beside them. Each
is a unit of the host's systemd
([what runs in a VM is systemd's to keep](lifetimes-to-systemd.md)). The
design is in [VMs](../design/vm.md).

## Context

A conversation's VM is cloud-hypervisor with a NixOS guest. Around it
something has to start and stop VMs, give each a network and an address,
share directories with it and run commands in it.

## Decision

Do as microvm.nix's own host module does: cloud-hypervisor runs as an
ordinary user in the `kvm` group, and only declarative configuration
applied at boot needs root (the `kvm` group, the pre-created taps, the
routes and nft rules, a polkit rule for the VMs' units).

- No broker and no network namespace per VM.
- Addresses go on the kernel command line, not by DHCP: there is no DHCP
  server on the host, and no extra share for DNS and the key.
- The cloud-hypervisor and virtiofsd command lines are Max's own, taking
  only the guest's kernel, initrd and command line from its build:
  `microvm-run` hard-codes the tap name at build time, and each VM
  differs in directories, tap and Landlock rules.

## Why

A VM escape yields `maxx` rather than root, and there is no root code of
Max's own to keep.

## What it rests on

Checked on tank, as `maxx` under the hardening of `maxx.service`:

- cloud-hypervisor uses the pre-created multi-queue taps without
  `CAP_NET_ADMIN`. It notes that the tap already exists and leaves its
  address alone.
- Run as an ordinary user, virtiofsd enters new user, mount, pid and net
  namespaces by itself, changes its root to the shared directory and
  holds no capabilities. In `/work`, creating, deleting and renaming
  files, symbolic and hard links, chmod, flock, git and large files work.
  The guest's root is mapped to `maxx` and every other uid squashed to
  it, so chown reports no error and has no effect, and mknod fails.
- The hardening of `maxx.service` is relaxed in four places:
  - `ProtectKernelTunables`, `ProtectKernelLogs` and `ProtectHostname`
    are off. They overlay read-only mounts on `/proc`, and the kernel
    then refuses to let virtiofsd mount another proc in its own user
    namespace. For a service without capabilities they block little.
  - `RestrictNamespaces` allows user, mnt, pid and net, which virtiofsd's
    sandbox needs.
  - `SystemCallFilter` adds `@mount`.
  - `PrivateDevices` stays; `/dev/kvm` and `/dev/net/tun` come in with
    `BindPaths` and are permitted with `DeviceAllow`.

  `RestrictSUIDSGID` also keeps the guest from setting the setuid bit in
  `/work`.
- cloud-hypervisor's Landlock is on, with two rules added:
  `/sys/devices/virtual/net` read-only, to read the tap's flags, and the
  VM's directory read-write, for the vsock socket. cloud-hypervisor then
  has no capabilities, runs with `NoNewPrivs` and has a seccomp filter.
- SSH over hybrid vsock first sends `CONNECT 22\n`, as systemd's
  `systemd-ssh-proxy vsock-mux/<socket>` does.
- In the guest, `systemd-run --pipe --wait` brings back the output and
  the exit code. It writes escape sequences that set the terminal title
  into the output unless `SYSTEMD_ADJUST_TERMINAL_TITLE=0` is set.
- tank's CPU has nested KVM, so a guest also starts inside the module's
  NixOS test, `nestedChecks.x86_64-linux.vm`. CI's runners are VMs
  themselves and can't give the test machine KVM, so that test isn't
  among `checks` and runs on tank.
- aarch64 builds too: cloud-hypervisor boots `Image` there, where on
  x86_64 it boots the ELF `vmlinux`, and the serial port is a PL011, so
  the kernel and the console are chosen per architecture. A guest comes
  up in the Mac's Linux builder under two layers of virtualisation, more
  than ten times slower than on tank, and the browser's checks time out
  there; see
  [research/nested-test-on-mac.md](../research/nested-test-on-mac.md).

## Cost

Everything a broker would do at run time is fixed at boot: the number of
taps is the number of VMs that can run, and a change to the network is a
change to the host's configuration.

## Alternatives

- **A socket-activated root broker** that starts and stops VMs, makes a
  network namespace with NAT for each, hands out addresses and volumes,
  runs commands in the guest and installs packages: about a thousand
  lines of root code, and the VM's unit running as root.
- **microvm.nix's runner as it is**: see Decision.
