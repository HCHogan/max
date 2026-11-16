# A forwarder keeps no count

Decided 2026-11-16 with the owner. What runs is in [A VM's forwarder](../design/vm.md#a-vms-forwarder) and under [Background agents](../design/jobs.md#background-agents).

**Context.** A VM's forwarder passes on what needs none of max: the models' calls from the VM and the keyed APIs'. It also counted the first. It read every model answer on its way back for what the call used (`max_llm::Meter`, which only the forwarder used), and one task recorded that for the VM's conversation as an `llm_usage` row of purpose `job`, which `/status` summed with Max's own calls. For that, each forwarder kept a connection to the database and read `[database]` from the configuration. A look the same day at where Max's code goes found the forwarder to be, for the most part, a reverse proxy written again; the counting was the part no proxy would have done, and what kept a forwarder from being a function of its configuration alone.

**The decision.** A model call from a VM isn't counted. The forwarder gives it the provider's key, puts the model's id in its place and passes the answer back as it comes, broken off only if the provider goes quiet. It has no connection to the database and reads `[llm]`, `[api]` and `[log]`. `/status` shows what Max's own calls used.

**Why.** The owner: if the complexity is there for the counting, better not to count, or to leave it to the upstream. The upstream does count: the provider's records have every call, for all the groups together. Having a gateway in front of the providers count by group instead was looked at: CLIProxyAPI, which the owner runs, keeps no totals any more by its documentation, and publishes a record for each request to a queue that something of ours would have to drain and store, which is the same code in another place.

**What it costs.** `/status` no longer includes what a conversation's background agents used, which for a group that runs agents is likely most of what it spends: the answer to "what did this group cost" is now only Max's own turns, its intent calls and its captions. The rows of purpose `job` written until now stay, and `/status` sums those its 7 days still hold.
