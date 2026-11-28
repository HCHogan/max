# Max joins tailnets itself

The host puts no VM on a tailnet. When someone wants Max on their
machines, Max runs tailscaled in its conversation's VM, as a unit of its
own, and is let into their tailnet. The design is in
[Tailnets](../design/vm.md#tailnets).

## Context

Some groups have Max work on machines: look at a service, change a
configuration, restart something. The machines are on a tailnet whose
Tailscale SSH lets a node in by its identity, so a node needs no key of
the machines'.

## Decision

- The host keeps no tailnet for the VMs: no namespace, taps or ip rule of
  their own, nothing on the guest's command line, no prompt section and
  nothing in max's configuration.
- A guest reaches the internet, as every guest does, which is all
  Tailscale needs. Max runs tailscaled as one of its own units in
  `/work/.max/systemd`, with its state under `/work`, and whoever runs
  the tailnet lets the node in: a login URL they approve, or a key they
  give. For several tailnets at once Max runs a tailscaled each, in
  userspace networking, which keeps their routes and addresses apart.
- Nothing in the guest image or the prompt is for this. Max installs
  Tailscale as it installs any other program, and knows it as it knows
  them.
- Which conversations reach a tailnet is the tailnet's to say, by the
  nodes it admits and its ACLs.

## Why

- **A primitive, not a convenience.** The host gives a VM the internet
  and a way to keep a program running; joining a network is something Max
  does with them, as it installs a tool.
- **Any tailnet.** Anyone who wants Max on their machines can let it in,
  with no change to the host.
- **The gate where it belongs.** A tailnet's admin decides which nodes
  join and what they reach, with Tailscale's own means (ACLs, SSH's check
  mode, key expiry), and each conversation is a node of its own.
- **Less to keep working.** The host's side of the VMs' network is one
  kind of tap and one set of nft rules.

## Cost

- **The node's key is in the VM.** Anyone in the conversation can have
  Max read the node's state and use it from elsewhere, until the tailnet
  removes it. The conversation is the finest grain of permission (see
  [permission-by-conversation.md](permission-by-conversation.md)), and
  they could already have Max give them their own way in to those
  machines; a tailnet that minds can expire the node's key.
- **A VM on several tailnets joins them**: anyone in the conversation can
  have Max carry things from one to another. The conversation's
  permission again; someone who wants Max on their machines alone lets in
  the VM of their private chat.
- **Each conversation is let in by hand**, once.
- **Slower paths, perhaps.** A guest can't reach the LAN, so it reaches
  machines on it by their public endpoints or a DERP relay.

## Alternatives

- **A network on the host for some groups' VMs**: the VMs of groups
  listed in max's configuration on taps of their own, routed by source
  into a network namespace where a tailscaled of the host's is the
  tailnet node, with nft keeping those VMs inside the namespace and the
  namespace off the LAN. The node's key stays out of the guest's reach.
  It is some 340 lines of the NixOS module, two kinds of slot in the VM
  service and a fake tailnet in the nested test, and it fails in ways of
  its own: networkd deletes the ip rule after a restart and the VMs are
  cut off; resolved renames its stub from under the namespace's client.
  And it serves one tailnet: anyone else who wants Max on their machines
  has no way in, and which groups reach it is a list in the host's
  configuration.
- **`services.tailscale` in the image**, logged out until Max logs it in:
  it would make the first tailnet unlike the rest (kernel networking, a
  fixed state directory), when Max starts the second itself anyway, and
  every group's image would carry it.
- **A namespace per conversation on the host**: a node each, but still
  the host's wiring, and still for the tailnets the host's configuration
  names.
