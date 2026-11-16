# The browser is a resident Chromium

The browser in a group's VM is a Chromium that stays up between programs,
not a camoufox started fresh for each run, as it was first built. The
design is in [The browser](../design/tools.md#the-browser).

## Context

After the model has looked at a page, the page must still be there when the
next `run_code` clicks on it. The browsers vendors give their models
(Playwright MCP, chrome-devtools-mcp, agent-browser, Hermes's
`browser_exec`) all stay resident, and Hermes, in code mode like Max, has
each call start a new interpreter that connects to the same Chromium over
CDP.

camoufox can't do this: when a Playwright connection drops, the server
closes the contexts that client opened (`cleanupContexts` in playwright-core
1.59), so keeping a page across processes would need a resident process of
Max's own to hold it; and Firefox no longer speaks CDP. CDP's state is the
browser's, and disconnecting closes no page: checked locally with Chrome and
playwright-core 1.59, the pages one process opened and the text it typed
were there when the next connected.

## Decision

Chromium from nixpkgs, resident in the guest, driven by programs with
Playwright directly. No browser tools (navigate, click): a snapshot helper
gives the numbered accessibility tree that every vendor's page
representation has converged on (Playwright MCP's `[ref=e5]`, Claude's
`ref_N`, agent-browser's `@e1`), which Playwright 1.59 has built in. The
Haskell version's list of "interactive elements plus CSS selectors" went.
The camoufox distribution, camoufox-js and its patches were deleted.

## Cost

Weaker anti-fingerprinting than camoufox; checks such as Cloudflare's block
it more readily. If that happens often, a resident service such as
camofox-browser can run in the VM.

## Not packaged: opencli

[opencli](https://github.com/jackwener/opencli) turns some 150 websites
into commands. It was packaged into the guest (the npm package, a lock
file, a wrapper giving each command its own tab, a passing nested test) and
taken out again: tools of this kind offer convenience rather than
primitives, their adaptations to sites go stale quickly, and Max can
install one when needed rather than Max's maintainers pinning and updating
it. The prompt keeps one sentence about it.
