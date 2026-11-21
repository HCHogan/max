# A background agent is pi in a background command

Max hands work of many steps to pi by running it, `pi -p`, in a background command; there is no agent tool. What runs is [Background agents](../design/jobs.md#background-agents).

## Context

Agents were a tool of the guest's: `maxx agent start`, `steer`, `models` and `ask`, a starter script that numbered them, gave each a unit of its own kind and a directory of files under `/run/max/jobs`, and a plugin in pi that read steers from an inbox at each turn's end, held an agent that had asked something for ten minutes, warned it five minutes before its limit, took SIGUSR2 to stop with a report, wrote the report to a file and kept notes for each directory. A wrapper built pi's configuration for each run. Ending one had a notice of its own kind, and taking up an ended one a fork with a new number. Together they were the largest part of the guest's scripts, and the plugin rested on pi's extension API, which has no version.

Meanwhile a background command already gave most of what an agent needs: a unit that runs for hours, its output kept in a file, a notice with how it ended and the end of what it printed, retried until max takes it, and `systemctl stop` and `/kill`. pi's print mode prints just the agent's last text, which is its report, and pi keeps sessions of its own, which `--session-id` names and goes on with.

## Decision

The guest's `pi` is a wrapper that writes what `GET /llm` says of the models into pi's own files and adds the agent's system text, and otherwise is pi. Max runs it with `shell` and `background`, `cd <dir> && pi -p --session-id <name>` with the task as a heredoc, and hears of its end as of any background command's. To tell an agent more, answer it, redo or go on with its work, Max runs it again with the same name in the same directory; a running one is stopped first. An agent with a question ends with it. `maxx agent`, its unit kind, its directory, its notice, the plugin, the limits of three at once and six hours each, and the notes are gone.

## Why

- **Primitives, not scaffolding.** Each piece of the plugin decided something for the model: when it may be told more, how long it waits, when it wraps up, where it keeps notes. A shell, a long-running command and a resumable session are things the model already knows how to use, and get better at without changes here.
- **Less to keep true.** Every move of pi's pin meant checking the plugin's hooks against an unversioned API; the wrapper relies only on pi's configuration files, print mode and sessions, which are its public surface.
- **One way to run things.** An agent's start, limit, output, end and stop are a background command's, so what is said of those, and their tests, is said once.
- **Going on is the same act for everything.** Steering, answering, redoing and taking up work that ran out of time were four mechanisms (`steer`, the hold, `--resume`, the wrap-up); now each is a run with the same session.

The other way looked at was to keep only the inbox: a small plugin that reads steers at each turn's end, so a running agent can be told more without being stopped. It would keep the dependence on pi's extension API for the one case where stopping and running again costs the step in flight; that wasn't worth it.

## Cost

- A running agent can't be told anything. Stopping it loses the step it was in, and its last text if it had written none since.
- An agent stopped or out of time reports nothing: pi exits on SIGTERM at once. The session keeps what it did, and running it again goes on from there, but the notice at the limit has no text.
- An agent with a question ends rather than waiting, so answering it is a new run, which sends the whole conversation again; when the provider's cache has gone cold, that costs the input once more.
- Nothing bounds how many agents run, or for how long beyond a background command's 24 hours: each costs model calls while it runs.
- The session id is Max's to choose and remember: a name used again in the same directory goes on with an older conversation. The notice carries the command's first line, which names it, and the wrapper refuses a name kept only for another directory, where pi would otherwise start afresh in silence.
- Notes for each directory are gone; a project's own `AGENTS.md` or `CLAUDE.md` is still read.
