# Max's documentation

How Max is built, as it is now. Start with [architecture.md](architecture.md),
then read the part of [design/](design/) you are working on.

| Where | What it holds |
| --- | --- |
| [architecture.md](architecture.md) | Goals, principles, the task tree, the technology and the crates |
| [design/](design/) | Each part of Max as it is now |
| [decisions/](decisions/) | Why things are as they are: one decision a file, [listed by subject](decisions/README.md) |
| [research/](research/) | What was looked at and what came of it |
| [archive/](archive/) | Finished history: v1, the rewrite's go-live, the import, the parity checklist with the Haskell version, and the steps by which lifetimes moved to systemd |

The design, in reading order:

1. [core.md](design/core.md): the turn's state machine
2. [actor.md](design/actor.md): the conversation actor that drives it
3. [lifetimes.md](design/lifetimes.md): scopes, cancellation and timeouts
4. [ledger.md](design/ledger.md): the ledger, entries, turn records and the schema
5. [context.md](design/context.md): what a request holds, memory and recall
6. [intent.md](design/intent.md): what wakes Max
7. [tools.md](design/tools.md): codemode, the tools and the guest's calls
8. [vm.md](design/vm.md): the group VMs and their forwarders
9. [jobs.md](design/jobs.md): agents, background commands, resident programs, questions
10. [commands.md](design/commands.md), [identity.md](design/identity.md), [config.md](design/config.md)
11. [qq.md](design/qq.md), [media.md](design/media.md)

How to keep these files is in [AGENTS.md](../AGENTS.md#documentation).
