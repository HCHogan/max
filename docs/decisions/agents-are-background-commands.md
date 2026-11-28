# A background agent is fx in a background command

Max hands work of many steps to an agent by running fx
(`vercel-labs/fx`), `fx ask`, in a background command. There is no agent
tool, and max keeps nothing of an agent. What runs is
[Background agents](../design/jobs.md#background-agents).

## Context

Some work takes hours and many steps: reading a repository, building,
opening a PR. It runs apart from the turn, while Max goes on in the chat.

An agent needs a unit that runs for hours, its output kept in a file, a
notice of how it ended with the end of what it printed, tried again until
max takes it, and a way to stop it. A background command is all of these
already. What an agent adds is a harness: a loop with a shell and file
tools that runs on max's models and keeps its conversation, so that the
work can be gone on with.

## Decision

- The guest's `fx` is a wrapper, `nix/fx.sh`, that writes what `GET /llm`
  says of the models into fx's settings and adds the agent's system text,
  and otherwise is fx.
- Max runs `cd <dir> && fx ask --session <name>` with `shell` and
  `background`, the task as a heredoc, and hears of its end as of any
  background command's.
- To tell an agent more, answer it, redo or go on with its work, Max runs
  it again by the same name in the same directory. A running one is
  stopped first, and an agent with a question ends with it.
- An agent has no command, unit kind, directory or notice of its own, no
  limit on how many run, and no notes kept for it.
- Only `fx ask` is used. Telling a running agent more, over `fx acp`,
  isn't built.

## Why a background command

- **Primitives, not scaffolding.** A tool for agents decides things for
  the model: when an agent may be told more, how long it waits for an
  answer, when it wraps up, where it keeps notes. A shell, a long-running
  command and a session that can be gone on with are things the model
  already knows how to use, and gets better at without changes here.
- **One way to run things.** An agent's start, limit, output, end and
  stop are a background command's, so what is said of those, and their
  tests, is said once.
- **Going on is one act.** Steering, answering, redoing and taking up
  work that ran out of time are each a run with the same session.
- **Less to keep true.** The wrapper rests on the harness's command line,
  settings and sessions, which are its public surface.

## Why fx

- **The way to a running agent is the harness's own.** What agents lack
  most is being told more while they run. fx has a protocol for it,
  `fx acp`: a message sent while a turn runs is read at the agent's next
  step, and one sent as the turn ends starts the next. A driver would
  speak a documented protocol.
- **It takes max's models as they are.** A custom connection is a base
  URL, a protocol and the request fields each effort stands for, so both
  of max's protocols and every effort a provider spells go through
  without a table of fx's own models. A Responses call carries its
  reasoning back by itself.
- **It is small**: one binary of 15 MB that needs only glibc.
- **An agent's output says what it did.** fx prints what the agent says
  and runs as it goes, so the output file of an agent that ran out of
  time, or was stopped, has how far it got.

## Cost

- A running agent can't be told anything. Stopping it loses the step it
  was in, and it reports nothing: fx exits at once on SIGTERM. The session
  keeps what it did, and running it again goes on from there.
- An agent with a question ends rather than waiting, so answering it is a
  new run, which sends the whole conversation again; when the provider's
  cache has gone cold, that costs the input once more.
- Nothing bounds how many agents run, or for how long beyond a background
  command's 24 hours: each costs model calls while it runs.
- The session's name is Max's to choose and remember: a name used again
  in the same directory goes on with an older conversation. The notice
  carries the command's first line, which names it.
- **fx is young and says so.** It calls itself experimental, and most of
  its releases change a flag, a setting or a file's format. The `fx`
  check is what tells a pin that breaks the wrapper from one that
  doesn't; a night's pin that fails it stays where it was.
- **Sessions have no names in fx.** The wrapper gives each name an fx
  home of its own and goes on with that home's last session in the
  directory, and refuses a name kept only for another directory, where fx
  would start afresh in silence.
- **A failing provider is tried without end**: an agent whose provider
  stays down runs to its unit's limit, 6 hours unless Max set another.
- **A long command costs model calls.** fx's shell tool hands back a
  command that runs past its wait, at most 5 minutes a call, and what
  still runs when fx exits is killed.
- **The notice has more than the report**: the end of the output is the
  report, and before it the last of what the agent said and ran.
- **fx holds the answer to the task's language** when the task reads as
  English, asks again once and then fails the run. Max's tasks are in
  Chinese, which it holds to nothing.
- **fx's own agents come with it.** `fx ask` can't leave out the
  `subagent` tool, so an agent may start agents of its own within its
  run, each costing model calls.
- A project's `AGENTS.md` is read; its `CLAUDE.md` only as a link from
  that.

## Alternatives

- **An agent tool of the guest's**: `maxx agent` to start, steer and ask,
  a unit kind and a directory for each agent, and a plugin in the harness
  that reads steers from an inbox, holds an agent that asked something,
  warns it before its limit and writes its report. It is the larger part
  of the guest's scripts, each piece decides something for the model, and
  the plugin rests on an extension API with no version, to be checked at
  every move of the pin.
- **The inbox alone**: a small plugin that reads steers at each turn's
  end, so a running agent is told more without being stopped. It keeps
  the dependence on the extension API for the one case where stopping and
  running again costs the step in flight.
- **A new session forked from the ended one**, so that the earlier one
  stays as it was and can be taken up twice. It needs something of the
  guest's to number and fork sessions; going on in the same session is
  what the harness does by itself.
- **pi as the harness**, in print mode with its own named sessions. It
  works, but the way to a running agent is its RPC mode or its SDK behind
  a driver of the guest's own; its closure with Node is 214 MB of the
  image; it prints nothing until the end; and it gives up on a failing
  provider after 8 tries.
- **libfx**, fx as a library: it has no shell or file tools of its own,
  which would be written here.
