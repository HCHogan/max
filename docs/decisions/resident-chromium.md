# The browser is a resident Chromium, and a snapshot's refs hold

The browser in a conversation's VM is a Chromium that stays up between
programs, driven with Playwright directly. A ref that `max.snapshot`
showed works in later `run_code` programs too, until the page navigates
or changes above the element; a ref that can't be resolved is refused at
once. The design is in [The browser](../design/tools.md#the-browser).

## Context

After the model has looked at a page, the page must still be there when
the next `run_code` clicks on it, and every `run_code` is a new process.
The browsers vendors give their models (Playwright MCP,
chrome-devtools-mcp, agent-browser, Hermes's `browser_exec`) all stay
resident, and Hermes, in code mode like Max, has each call start a new
interpreter that connects to the same Chromium over CDP.

CDP's state is the browser's, and disconnecting closes no page: the pages
one process opened and the text it typed are there when the next
connects.

Playwright's refs are another matter. They are numbers that its script in
the page gives elements as a snapshot comes to them, kept on the elements
and in that script. The script is each connection's own, so a ref from
one program names nothing in the next. The model doesn't work that way:
it reads `[ref=e12]` in one program's result and clicks `aria-ref=e12` in
the next, taking the new snapshot after the click to see what it did. In
four weeks without carried refs, 25 programs did that and 23 failed, each
after Playwright's 30 seconds of waiting for the locator, with an error
that said only that it had timed out; programs that took the snapshot
first failed 10 times in 44, and the model fell back on CSS selectors.

## Decision

- Chromium from nixpkgs, resident in the guest, driven by programs with
  Playwright.
- No browser tools (navigate, click). A snapshot helper gives the
  numbered accessibility tree that every vendor's page representation has
  converged on (Playwright MCP's `[ref=e5]`, Claude's `ref_N`,
  agent-browser's `@e1`), which Playwright has built in.
- The SDK carries the refs over. `max.snapshot` leaves the tree in the
  document. A program that connects takes the same snapshot of each tab
  that has one, and compares the two line by line, without the refs and
  without what an element is in at the moment: up to the first line that
  differs, the lines are the same elements, and
  `page.locator("aria-ref=…")` turns the kept ref into the new one. Refs
  after that line are refused, as are ones the snapshot never had, with a
  message that says to take a new snapshot.
- Nothing that turns websites into commands is packaged in the guest.

## Why

- **Chromium, because CDP keeps pages across connections.** See Context.
- **By position, up to the first difference**, because that is all a ref
  means: a new connection numbers the page in order, so an element
  inserted above shifts every number after it. Stopping at the first
  difference refuses the refs that may have moved, and with them some
  that haven't; the cost of a refusal is one more snapshot, the cost of a
  wrong click is a click on something else, on pages where Max is logged
  in.
- **Translated, not required to be equal**: a connection keeps the
  numbers it gave and goes on counting for what is new, so a second
  snapshot in one program has a new row as e21 where a new connection
  counts it as e6. Requiring equal numbers would refuse everything below
  such a row.
- **Kept in the document**, so it goes when the refs do, at a navigation,
  with no file to key by tab and to clear.
- **Refused where the locator is made**, since Playwright has no error
  for a ref it doesn't know: it waits for the element until the timeout.

## Cost

- Weaker anti-fingerprinting than a hardened Firefox; checks such as
  Cloudflare's block it more readily. If that happens often, a resident
  service such as camofox-browser can run in the VM.
- A program's start takes a snapshot of each tab that has one (0.2
  seconds for a page of 600 elements), whether or not it uses a ref.
- A page that changes above the element between two programs, a field
  that was filled in included, has its refs refused, and the model takes
  a snapshot again.
- Two identical subtrees, one inserted above the other, aren't told
  apart.
- `page.locator` on a page is wrapped, so a ref given to `page.click` or
  a frame's `locator` goes to Playwright as it is.

## Alternatives

- **camoufox, started fresh for each run**: better against
  fingerprinting, but it can't stay. When a Playwright connection drops,
  the server closes the contexts that client opened (`cleanupContexts` in
  playwright-core), so keeping a page across processes would need a
  resident process of Max's own to hold it; and Firefox doesn't speak
  CDP.
- **Taking a snapshot at each program's start and letting the numbers
  fall where they do**: on a page that changed, a ref clicks another
  element and nothing says so.
- **A resident process that holds the Playwright connection**, so the
  refs are the elements' for as long as they live, as in Playwright MCP:
  every program's Playwright calls would go through it, and Max would
  maintain that protocol.
- **Refs of the SDK's own**, by a selector engine and marks on the
  elements: the page sees the marks, and frames need their own handling.
- **[opencli](https://github.com/jackwener/opencli) in the guest**, which
  turns some 150 websites into commands. Tools of this kind offer
  convenience rather than primitives, their adaptations to sites go stale
  quickly, and Max can install one when needed rather than Max's
  maintainers pinning and updating it. The prompt has one sentence about
  it.
