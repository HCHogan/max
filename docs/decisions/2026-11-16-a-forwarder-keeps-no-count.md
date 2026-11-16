# A forwarder keeps no count

Decided 2026-11-16 with the owner. What runs is in [A VM's forwarder](../design/vm.md#a-vms-forwarder), under [Background agents](../design/jobs.md#background-agents) and in [Host-keyed APIs](../design/tools.md#host-keyed-apis).

**Context.** A VM's forwarder passes on what needs none of max: the models' calls from the VM and the keyed APIs'. It also counted both.

- It read every model answer on its way back for what the call used (`max_llm::Meter`, which only the forwarder used), and one task recorded that for the VM's conversation as an `llm_usage` row of purpose `job`, which `/status` summed with Max's own calls. For that, each forwarder kept a connection to the database and read `[database]` from the configuration.
- An API's `per_hour` was every chat's together, so the forwarders, a process each, counted an API's calls in one file under `<vm.dir>/api/`, locked while it was read and written, off the runtime's threads, with a count in the process for when the file couldn't be had.

A look the same day at where Max's code goes found the forwarder to be, for the most part, a reverse proxy written again. The counting, about a third of it, was the part no proxy would have done, and what kept a forwarder from being a function of its configuration alone: it was why one held a connection, and why one shared anything with another.

**The decision.**

- A model call from a VM isn't counted. The forwarder gives it the provider's key, puts the model's id in its place and passes the answer back as it comes, broken off only if the provider goes quiet. It has no connection to the database and reads `[llm]`, `[api]` and `[log]`. `/status` shows what Max's own calls used.
- An API's `per_hour` is each chat's. A forwarder counts its own VM's calls of the last hour in memory, which was the fallback before.

**Why.** The owner: if the complexity is there for the counting, better not to count, or to leave it to the upstream.

- The upstream does count the models' calls: the provider's records have every one, for all the groups together. Having a gateway in front of the providers count by group instead was looked at: CLIProxyAPI, which the owner runs, keeps no totals any more by its documentation, and publishes a record for each request to a queue that something of ours would have to drain and store, which is the same code in another place.
- `per_hour` isn't a statistic but a guard: a key the VM never sees can still be used by anyone who can have Max run a command, within `allow` and `per_hour`. So it stays, in the form that needs nothing shared. The API's own limit stands behind it.

**What it costs.**

- `/status` no longer includes what a conversation's background agents used, which for a group that runs agents is likely most of what it spends. The rows of purpose `job` written until now stay, and `/status` sums those its 7 days still hold.
- A key is good for `per_hour` calls from each chat, not from all of them: tank's Bungie key allows 1,000 an hour in all, which two busy chats at 1,000 each would overrun, and the API would say so.
- A forwarder's count starts over when it reads a configuration anew, which is whenever max comes back, and with its VM's boot. A chat can have more than `per_hour` in an hour that a deploy falls in.
- The files in `<vm.dir>/api/` are no longer read, and can be removed by hand.
