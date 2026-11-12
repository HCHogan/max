# The contract between a host and a guest: a number for everything max
# says to a guest it didn't boot itself, and for what the guest keeps
# between images. A VM outlives max, so a new max meets guests an older
# one booted; one whose number isn't max's is restarted at once.
#
# Raise it with any change to: max-jobs' arguments or the line a call
# prints; the layout of /run/max/jobs; the runner's input; the routes a
# guest calls (/mcp, /llm, /api, /events, /units). See "Lifetimes move to
# systemd" in docs/rust-rewrite.md.
1
