# Max joins tailnets itself

The host puts no VM on a tailnet. When someone wants Max on their machines,
Max runs tailscaled in its conversation's VM, as a unit of its own, and is
let into their tailnet. The operations network, through which the host put
some groups' VMs on one tailnet, is gone. The design is in
[Tailnets](../design/vm.md#tailnets).

## Context

Some groups have Max work on machines: look at a service, change a
configuration, restart something. The machines are on a tailnet whose
Tailscale SSH lets a node in by its identity, so a node needs no key of
the machines'.

The operations network did this on the host, after the Haskell version's
`nix/operations.nix`. Groups listed in max's configuration had their VMs on
taps of their own, routed by source into a network namespace where a
tailscaled of the host's was the tailnet node. nft kept those VMs inside the
namespace and the namespace off the LAN; the guest got the tailnet's domain
on its command line and an ssh_config made from it; the host's own tailnet
address needed a DNAT of its own, since the host took it as local; and the
prompt of those groups had a section on it.

That was some 340 lines of the NixOS module, two kinds of slot in the VM
service and a fake tailnet in the nested test, and it failed in ways of its
own: networkd deleted the ip rule after a restart and the VMs were cut off,
unnoticed for a day; resolved renamed its stub from under the namespace's
client. And it served one tailnet: anyone else who wanted Max on their
machines had no way in, and which groups reached it was a list in the
host's configuration.

## Decision

- The host keeps no tailnet for the VMs: no namespace, taps or ip rule of
  their own, no `max.domain`, no ssh_config, no prompt section, no
  `vm.operations`.
- A guest reaches the internet, as every guest does, which is all Tailscale
  needs. Max runs tailscaled as one of its own units in
  `/work/.max/systemd`, with its state under `/work`, and whoever runs the
  tailnet lets the node in: a login URL they approve, or a key they give.
  For several tailnets at once Max runs a tailscaled each, in userspace
  networking, which keeps their routes and addresses apart.
- Nothing in the guest image or the prompt is for this. Max installs
  Tailscale as it installs any other program, and knows it as it knows them.
- Which conversations reach a tailnet is the tailnet's to say, by the nodes
  it admits and its ACLs, not max's configuration.

## Why

- **A primitive, not a convenience.** The host gives a VM the internet and
  a way to keep a program running; joining a network is something Max does
  with them, as it installs a tool.
- **Any tailnet.** Anyone who wants Max on their machines can let it in,
  with no change to the host.
- **The gate where it belongs.** A tailnet's admin decides which nodes join
  and what they reach, with Tailscale's own means (ACLs, SSH's check mode,
  key expiry), and each conversation is a node of its own.
- **Less to keep working.** The host's side of the VMs' network is one kind
  of tap and one set of nft rules; the failures above have nothing left to
  happen to.

## Cost

- **The node's key is in the VM.** The operations network kept it on the
  host, out of the guest's reach. Now anyone in the conversation can have
  Max read the node's state and use it from elsewhere, until the tailnet
  removes it. The conversation is the unit of permission (see
  [Asking another conversation](../design/jobs.md#asking-another-conversation)),
  and they could already have had Max give them their own way in to those
  machines; a tailnet that minds can expire the node's key.
- **A VM on several tailnets joins them**: anyone in the conversation can
  have Max carry things from one to another. The conversation's permission
  again; someone who wants Max on their machines alone lets in the VM of
  their private chat.
- **Each conversation is let in once.** The groups on the operations
  network had the tailnet from their first boot; now each conversation's
  node is admitted by hand, and the shared node is removed.
- **Slower paths, perhaps.** A guest can't reach the LAN, so it reaches
  machines on it by their public endpoints or a DERP relay. The namespace's
  client was kept off the LAN too, so this is as it was.

## Alternatives

- **`services.tailscale` in the image**, logged out until Max logs it in:
  it would make the first tailnet unlike the rest (kernel networking, a
  fixed state directory), when Max starts the second itself anyway, and
  every group's image would carry it.
- **A namespace per conversation on the host**: a node each, but still the
  host's wiring, and still for the tailnets the host's configuration names.
