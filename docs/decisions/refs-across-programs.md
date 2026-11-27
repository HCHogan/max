# A snapshot's refs hold in the next program

A ref that `max.snapshot` showed works in later `run_code` programs too,
until the page navigates or changes above the element; a ref that can't be
resolved is refused at once. The design is in
[The browser](../design/tools.md#the-browser).

## Context

Playwright's refs are numbers that its script in the page gives elements as
a snapshot comes to them, kept on the elements and in that script. The
script is each connection's own, and every `run_code` is a new process and
a new connection, so a ref from one program named nothing in the next: a
new program had to take a snapshot before it used one.

The model didn't work that way. It read `[ref=e12]` in one program's result
and clicked `aria-ref=e12` in the next, taking the new snapshot after the
click to see what it did. In four weeks of use, 25 programs did that and 23
failed, each after Playwright's 30 seconds of waiting for the locator,
with an error that said only that it had timed out; programs that took the
snapshot first failed 10 times in 44. Refs went from 41 uses a week to
between 5 and 17 as the model fell back on CSS selectors.

## Decision

The SDK carries the refs over. `max.snapshot` leaves the tree in the
document. A program that connects takes the same snapshot of each tab that
has one, and compares the two line by line, without the refs and without
what an element is in at the moment: up to the first line that differs, the
lines are the same elements, and `page.locator("aria-ref=…")` turns the
kept ref into the new one. Refs after that line are refused, as are ones
the snapshot never had, with a message that says to take a new snapshot.

## Why

- **By position, up to the first difference**, because that is all a
  number means: a new connection numbers the page in order, so an element
  inserted above shifts every number after it. Stopping at the first
  difference refuses the refs that may have moved, and with them some that
  haven't; the cost of a refusal is one more snapshot, the cost of a wrong
  click is a click on something else, on pages where Max is logged in.
- **Translated, not required to be equal**: a connection keeps the numbers
  it gave and goes on counting for what is new, so a second snapshot in
  one program has a new row as e21 where a new connection counts it as e6.
  Requiring equal numbers refused everything below such a row.
- **Kept in the document**, so it goes when the refs do, at a navigation,
  with no file to key by tab and to clear.
- **Refused where the locator is made**, since Playwright has no error for
  a ref it doesn't know: it waits for the element until the timeout.

## Alternatives

- **Taking a snapshot at each program's start and letting the numbers
  fall where they do**, which is what the model did by hand when it
  followed the rule: on a page that changed, a ref clicks another element
  and nothing says so.
- **A resident process that holds the Playwright connection**, so the
  refs are the elements' for as long as they live, as in Playwright MCP:
  every program's Playwright calls would go through it, and Max would
  maintain that protocol.
- **Refs of the SDK's own**, by a selector engine and marks on the
  elements: the page sees the marks, and frames need their own handling.

## Cost

A program's start takes a snapshot of each tab that has one (0.2 seconds
for a page of 600 elements), whether or not it uses a ref. A page that
changes above the element between two programs, a field that was filled
in included, has its refs refused, and the model takes a snapshot again.
Two identical subtrees, one inserted above the other, aren't told apart.
`page.locator` on a page is wrapped, so a ref given to `page.click` or a
frame's `locator` goes to Playwright as it is.
