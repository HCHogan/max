# Programs have every tool, and no caps

2026-11-05, the owner. The design is in
[Programs call tools](../design/jobs.md#programs-call-tools).

## Context

When programs got tools (2026-11-02), they had only `history`,
`find_stickers`, `web_search`, `send_image` and `send_file`: `mute_member`
and `recall_message` were withheld lest they act on members without Max's
judgement, and the agent tool lest it spend money with nobody watching.
Messages programs sent were capped at 30 per group per hour, to leave
headroom in QQ's quota of 20 a minute and 1,000 a day per group; each tool
could declare a cap per run (`per_run`: 5 for `send_image`, 5 for
`mute_member`, 20 for `web_search`, …).

On 2026-11-04 a gomoku program Max wrote sent one board picture per move
and used up the 30 messages before a game was over; Max then had the
program wake Max to send for it past the cap, which cost more than no cap.

## Decision

- Every tool for programs: they are written by Max, and what they do is
  Max's decision, as muting and retracting are left to Max's judgement.
- The cap was raised to 200 on 2026-11-04 and removed the next day, with the
  tools' per-run caps.

## Why

A program that sends too much shows at once in the group: someone says so,
and Max stops it. QQ's own limit of 20 a minute is the backstop.

## Cost

A runaway loop can use up a group's daily quota within an hour, after which
Max can't speak there; and `web_search` is charged per call, so a search in a
loop costs money.
