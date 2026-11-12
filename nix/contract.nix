# The contract between a host and a guest: a number for everything max
# says to a guest it didn't boot itself, and for what the guest keeps
# between images. A VM outlives max, so a new max meets guests an older
# one booted; one whose number isn't max's is restarted at once.
#
# Raise it with any change to: max-jobs' arguments or the line a call
# prints; the layout of /run/max/jobs; the runner's input; the routes a
# guest calls (/mcp, /llm, /api, /events, /units). See "Lifetimes move to
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
3
