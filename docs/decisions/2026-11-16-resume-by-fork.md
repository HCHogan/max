# An ended agent is taken up by a fork

Decided 2026-11-16 with the owner, who asked for Max to be able to resume a given pi conversation. What runs is "Going on from an ended agent" under [Background agents](../design/jobs.md#background-agents).

**Context.** pi already kept every agent's session in `/work/.max/jobs`, but under `<time>_<uuid>.jsonl`: only the time tied a session to its unit, and once `/run` was gone nothing said what an agent without a report had been for. An agent that ended took all it had read and done with it; a new one on the same work had only the notes for its directory and what Max wrote into its task. Steers reach only an agent that runs.

**The decision.** Sessions are named after their unit and titled (`--session-id`, `--name`). `maxx agent start --resume max-agent-3` starts a new agent, `max-agent-7`, whose session is a fork of max-agent-3's: pi copies it and goes on from its end with the new task. An agent that runs can't be taken up; it is steered.

**Why a fork, and a new number.** The other ways were to run max-agent-3 again under its own name, or to have the new agent append to the earlier session (`--session`).

- A unit is one run: its number, directory under `/run/max/jobs`, markers, limits, report and wake each belong to one run of pi. Running a name again would leave the old `stopped`, `error` or `asked` for the new run to meet, and write the new report over the old, which Max has only the first 2,000 characters of in its ledger.
- One session file is one agent's. Appended to, max-agent-3's would hold max-agent-7's turns as well.
- An earlier session left as it was can be taken up twice, to try two ways from one point.
- The fork's header names the session it came from (`parentSession`), so a chain of agents is in the files without anything kept for it.

The names come from the session files, not from a list: Max finds them in its wakes and with `ls` in `/work/.max/jobs`, with the title in each session. There is no `maxx agent list`.

**What it costs.** A fork copies the whole session, up to a megabyte or so for a long agent. A session pi named before this (by a uuid) can't be taken up. A resumed agent runs on the agents' default model unless told otherwise, so one whose history doesn't fit the new model's window is compacted by pi, a model call of its own. The new argument is in `agent_start`'s declaration, which the host's prompt carries: a guest that hasn't been switched to the new image refuses it as an argument it doesn't know, until it is.
