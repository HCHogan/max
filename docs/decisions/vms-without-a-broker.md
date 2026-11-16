# The VMs run without a broker or root

The VMs run as an ordinary user, with no root broker beside them. They are
units of the host's systemd
([lifetimes to systemd](lifetimes-to-systemd.md)). The design is in
[VMs](../design/vm.md).

## Context

The Haskell version kept cloud-hypervisor with a NixOS guest, but
everything around it was a socket-activated root broker of about 1,000
lines ([ADR 011](https://github.com/HCHogan/max/blob/a5de2e1410f5cdfaa4b88c052bd499ee8b676759/docs/adr/011-native-systemd-runtime.md),
from when it still used nspawn): starting and stopping VMs, network
namespaces, addresses, volumes, commands in the guest and installing
packages. The VM's unit ran as root, and each VM had a network namespace
with NAT, the guest always `10.0.2.2`.

## Decision

Do as microvm.nix's own host module does: cloud-hypervisor runs as an
ordinary user in the `kvm` group, and only declarative configuration
applied at boot needs root (the `kvm` group, the pre-created taps, the
routes and nft rules, a polkit rule for the VMs' units). No broker, no
network namespaces per VM, addresses on the kernel command line rather
than by DHCP (no DHCP server on the host, and no extra share for DNS and
the key). The cloud-hypervisor and virtiofsd command
lines are Max's own, taking only the guest's kernel, initrd and command
line from its build: `microvm-run` hard-codes the tap name at
build time, and each VM differs in directories, tap and Landlock rules.

## Why

A VM escape yields `maxx` rather than root, and a thousand lines of root
code go.

## Verified on tank

Borrowing the Haskell version's guest, running as `maxx` under the
hardening of `maxx.service`:

- cloud-hypervisor 52 uses the pre-created multi-queue taps without needing `CAP_NET_ADMIN`. It merely notes that the tap already exists and does not change its address.
- When run as an ordinary user, virtiofsd 1.13 enters new user, mount, pid and net namespaces by itself, changes its root directory to the shared directory, and holds no capabilities. In `/work`, creating, deleting and renaming files, symbolic and hard links, chmod, flock, git and writing a 300 MB file all work. The guest's root is mapped to `maxx` and every other uid is squashed to `maxx`, so chown reports no error but has no effect; mknod fails, as in the Haskell version. `meta` and `chat` need the same mapping; otherwise `authorized_keys` in the guest is not owned by root and sshd refuses it.
- The hardening of `maxx.service` has to be relaxed in four places, and nothing else changes:
  - Remove `ProtectKernelTunables`, `ProtectKernelLogs` and `ProtectHostname`. They overlay read-only mounts on `/proc`, and the kernel then refuses to let virtiofsd mount another proc in its own user namespace. For a service without capabilities, these three options did not block much in any case.
  - `RestrictNamespaces` allows user, mnt, pid and net, which virtiofsd's sandbox needs.
  - `SystemCallFilter` adds `@mount`.
  - `PrivateDevices` stays; `/dev/kvm` and `/dev/net/tun` are brought in with `BindPaths` and permitted with `DeviceAllow`.

  `RestrictSUIDSGID` incidentally prevents the guest from setting the setuid bit in `/work`.
- cloud-hypervisor's Landlock can be enabled, but two rules must be added: `/sys/devices/virtual/net` read-only (to read the tap's flags) and the VM directory read-write (to create the vsock socket). Once Landlock is enabled, cloud-hypervisor has no capabilities, runs with `NoNewPrivs`, and has a seccomp filter.
- It takes about 3.8 seconds from starting the process to a working SSH connection. SSH over hybrid vsock first sends `CONNECT 22\n`, after which systemd's `systemd-ssh-proxy vsock-mux/<socket>` can connect; russh simply does the same.
- In the guest, `systemd-run --pipe --wait` brings back the output and the exit code. It writes escape sequences that set the terminal title into the output, so `SYSTEMD_ADJUST_TERMINAL_TITLE=0` must be set.
- tank's CPU has nested KVM enabled, so the guest can also be started inside the module's NixOS tests. The flake's `nestedChecks.x86_64-linux.vm` does exactly this: inside the test machine, the module sets up the taps, nft and the hardened `maxx.service`, and the equally hardened `maxx-vm-check` then starts a VM and runs `uname -a` through the same path that `shell` uses. It passed on tank, with the VM inside the test machine ready in 10 seconds. CI runners are themselves VMs and cannot give the test machine KVM, so this test is not part of `checks` and has to be run manually on tank.
- **aarch64 can be deployed too**: the flake's `guest` and `nestedChecks` also exist for aarch64-linux. On x86_64, cloud-hypervisor boots the ELF `vmlinux` directly; on aarch64 it boots `Image` and the serial port is a PL011, so the kernel and the console are chosen per architecture (`ttyS0`, `ttyAMA0`), as in microvm.nix's own runner; the x86_64 guest has not changed by a single byte. aarch64 has no early output comparable to `earlyprintk`, so with `quiet`, `serial.log` is normally empty. Verification: in a copy of the Mac's Linux builder (Virtualization.framework, with nested virtualisation enabled), `max vm-check` was run as an ordinary user; the guest came up, `uname -m` reported aarch64, and programs could call tools through MCP. Chromium and ffmpeg from the same guest also ran normally when run directly in the builder. However, the guest there sits beneath two layers of virtualisation and is more than ten times slower than on tank (50 seconds to boot, two minutes of CPU time to start Chromium), and all of the browser checks timed out, so the browser has not yet been fully verified in an aarch64 VM. The aarch64 `nestedChecks` need an aarch64 machine with nested KVM, which the Mac is not; see [research/nested-test-on-mac.md](../research/nested-test-on-mac.md).
