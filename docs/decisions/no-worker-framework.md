# The derived-data workers share conventions, not a framework

The workers that derive data (download, captions, embeddings, recall
vectors) each run a loop of their own and share only a list of conventions.

## Context

The first derived-data workers ran on a generic driver that ordered units
by `Throttle`, `Debounce` or `Urgent`.

## Decision

Take the driver apart and move scheduling back into each worker. What the workers share is the list of conventions in
[The three roles](../architecture.md#the-three-roles): an exclusive output
table, reentrant units, notification plus a scan for gaps, and each
worker's own loop and constants.

## Why

- Every scheduling policy piled up in the driver, which had to know every
  worker's needs.
- Whether a unit was done was recorded twice, in the driver's queue and in
  the database, and the two could disagree. With the database as the only
  record, a lost notification costs a scan, not a wrong answer.
- The Haskell version had converged on the same shape in its September
  simplification: a bounded local queue plus a scan for what is missing.

## Cost

Each worker writes a loop of its own, and the conventions are kept by
review rather than by a type.
