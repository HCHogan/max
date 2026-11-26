# Background agents run fx

The harness of Max's background agents is fx (`vercel-labs/fx`), run as `fx ask` in a background command, in place of pi. What runs is [Background agents](../design/jobs.md#background-agents).

## Context

An agent is [a harness in a background command](agents-are-background-commands.md): the guest has a wrapper that tells the harness of max's models, and a background command is the rest. The harness was pi, in print mode, with sessions named by `--session-id`.

That decision's first cost is that a running agent can't be told anything: Max stops it and runs it again, and the step in flight is lost. What comes next for agents is telling a running one more, and agents that start and tell each other. In pi that means its RPC mode or its SDK behind a driver of the guest's own. fx has it as a protocol of its own, `fx acp`: a message sent while a turn runs is read at the agent's next step, and one sent as the turn ends starts the next.

## Decision

The guest's `fx` is a wrapper, `nix/fx.sh`, that writes what `GET /llm` says of the models into fx's settings and adds the agent's system text, and otherwise is fx. Max runs `cd <dir> && fx ask --session <name>` with the task as a heredoc, and everything else of an agent is as it was: its unit, limit, output, notice and stop are a background command's, and going on is another run by the same name. `GET /llm` names a model's protocol as fx does.

Only `fx ask` is used. Telling a running agent more, over `fx acp`, is not built.

## Why

- **The way to a running agent is the harness's own.** With fx a driver would speak a documented protocol, where pi's needed a plugin on an extension API with no version, or its RPC mode.
- **It takes max's models as they are.** A custom connection is a base URL, a protocol and the request fields each effort stands for, so both of max's protocols and every effort a provider spells go through without a table of fx's own models. A Responses call carries its reasoning back by itself.
- **It is small.** One binary of 15 MB that needs only glibc, where pi's closure with Node was 214 MB of the guest's image.
- **An agent's output says what it did.** fx prints what the agent says and runs as it goes, so the output file of an agent that ran out of time, or was stopped, has how far it got; pi's had nothing until the end.

Staying on pi was the other way: it worked, and its sessions took a name. libfx, fx as a library, has no shell or file tools of its own, and would have left them to be written here.

## Cost

- **fx is young and says so.** It calls itself experimental, and most of its releases change a flag, a setting or a file's format. The wrapper rests on its command line, settings and session listing, and the `fx` check is what tells a pin that breaks them from one that doesn't; a night's pin that fails it stays where it was.
- **Sessions have no names in fx.** The wrapper gives each name an fx home of its own and goes on with that home's last session in the directory. The settings and the system text are written into each.
- **A failing provider is tried without end.** pi gave up after 8 tries and Max was told; an fx agent whose provider stays down runs to its unit's limit, 6 hours unless Max set another.
- **A long command costs model calls.** fx's shell tool hands back a command that runs past its wait, at most 5 minutes a call, and what still runs when fx exits is killed.
- **The notice has more than the report.** The end of the output is the report, and before it the last of what the agent said and ran.
- **fx holds the answer to the task's language** when the task reads as English, asks again once and then fails the run. Max's tasks are in Chinese, which it holds to nothing.
- **fx's own agents come with it.** `fx ask` can't leave out the `subagent` tool, so an agent may start agents of its own within its run, each costing model calls; a turn their report starts is held to the report's language as above.
- A project's `CLAUDE.md` is read only as a link from its `AGENTS.md`.
