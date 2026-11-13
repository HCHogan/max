# The contract between a host and a guest: a number for everything max
# says to a guest it didn't boot itself, and for what the guest keeps
# between images. A VM outlives max, so a new max meets guests an older
# one booted; one whose number isn't max's is restarted at once.
#
# Raise it with any change to: the arguments of what max runs with maxx,
# or the line a call prints; the layout of /run/max/jobs; the runner's input; the routes a
# guest calls (/tools, /llm, /api, /events, /units). See "Lifetimes move to
# systemd" in docs/rust-rewrite.md.
#
# 2 (2026-11-12): a background agent is a unit of the guest's. /job is
# gone, /llm takes any call from the VM and says what the model is, and
# /run/max/jobs keeps an agent's task, inbox and model.
#
# 3 (2026-11-12): one caller. Nothing in a guest has a token: max-jobs
# takes no --setenv, the runner's input has none, and /mcp runs every
# call for the VM. A call's unit has MAX_CALL, and the line it prints
# lists what it left for the model to see.
#
# 4 (2026-11-13): a call ends with its caller. max-jobs run takes
# --input BYTES, and the rest of its input is the caller's to hold open:
# when that ends, the guest stops the unit. max stops none by name.
#
# 5 (2026-11-14): one command. max-jobs, max-agent, max-units and
# max-wake are maxx's own `units` and `agent`, beside the host's tools:
# max runs `maxx units run`, `start`, `list` and `stop-all`, each with
# its arguments as a JSON object and its answer as one. A program has
# them as tools.<name>, with tools.show and tools.video where max.image
# and max.video were. The host's tools are plain HTTP, GET /tools and
# POST /tools/<name> with the arguments as JSON, where /mcp spoke MCP;
# the runner's input names max by `url`, and the guest's forwarder is
# max-host.
5
