# The derived-data workers share conventions, not a framework

The workers that derive data (download, captions) each run a loop of
their own and share only a list of conventions.

## Context

A worker reads the ledger or another derived table and writes a table of
its own. Each has to decide when to run a unit of work, how many at once,
and what to do when one fails.

## Decision

Scheduling is each worker's. What the workers share is the list of
conventions in [The three roles](../architecture.md#the-three-roles): an
exclusive output table, reentrant units, notification plus a scan for
gaps, and each worker's own loop and constants.

## Why

- A generic driver that orders units by policy (throttle, debounce,
  urgent) gathers every scheduling policy in one place, which then has to
  know every worker's needs.
- With a driver, whether a unit is done is recorded twice, in the
  driver's queue and in the database, and the two can disagree. With the
  database as the only record, a lost notification costs a scan, not a
  wrong answer.

## Cost

Each worker writes a loop of its own, and the conventions are kept by
review rather than by a type.
