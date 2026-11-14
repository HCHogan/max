# What leaves the host process

A survey of 2026-11-14, asked for by the owner with the long run in mind: which parts of max are worth a process of their own, and which could move from the host into a group's VM. Two things are, in this order, and the rest stays where it is. The first, the forwarder, is done: see [A VM's forwarder](../design/vm.md#a-vms-forwarder) (the owner: do this and the rows, and leave the context). The second isn't designed. Until then `/llm` and `/api` were routes of max's service to each VM, so every deploy cut an agent's model call in the middle (pi tries again, which is why this was bearable) and any `git push` or API call in flight.

## The survey

- **What a restart of max loses for good** is the turn that runs, after the 20 seconds it is given, and the call it was making. What a guest asks while max is away is asked again by the guest's client; `/events` is opened again; the VMs, the background commands, the agents and the units Max keeps run on. So nothing but a turn that runs in the guest makes a deploy cost a group nothing, and the model calls of such a turn would have to outlive max too.
- **Worth doing:** the models' calls and the keyed APIs out of max, in a process that outlives it (the forwarder); the timeline as data for a program ("Rows as data" under [Resident programs](../design/jobs.md#resident-programs)); then a turn's loop in the guest, assembling its own context, with the host keeping the chat's connection, the ledger, the keys and intent.
- **What a turn in the guest still lacks:** what it says with `say` is a program's row, of no turn; the records of a turn and its usage are the actor's to write; a wake has one taker, the actor's core; and every turn would need a VM that runs, where one that calls no tool boots none today, 4.5 to 10 seconds on a cold reply. The owner hasn't decided how the assembling of context is to be taken out; nothing of it is built.
- **Stays in max:**
  - *The tools' service.* Every call goes through the conversation's actor, and 9 of the 13 tools need it: to say something, to change a setting, to ask another conversation and answer one, to wake, and for a mute's permission. A process of its own would need a second channel that mirrors the first.
  - *History and search.* The database has the other groups' rows, and the embeddings' key.
  - *The VMs' lifecycle.* It holds the SSH connections the calls run on, and a guest isn't trusted to stop itself.
  - *The chat's adapter.* A restart costs it next to nothing already: the gateway resumes, and the sender drains.
  - *Intent.* It is what triggers a turn and what caps the spending, and what lets a VM sleep.
  - *The commands.* `/kill` and `/stop` must work when the VM or the model doesn't.
- **The workers** (download, caption, embedding, recall) could be a process of their own, and what that would buy is isolation: the decoding of the chat's pictures away from the process that holds the keys. It buys no quieter deploy, since every process comes from one package and restarts with it. They are lossy notification plus a scan for gaps already, so a short poll by row id would wake them; `LISTEN`/`NOTIFY` was rejected for them earlier. Not done.
- **Could leave the host altogether, and haven't:** the dreamer, which reads and writes `/work` and makes one model call, both of which a unit in the guest could do; and `web_search`, which could be one more keyed API.
