# Open for discussion

> Finished history, kept as written then: its dates and its "now" are of that time. What is true now is in [design/](../design/).


1. ~~Where the code lives~~: decided (2026-10-27): in this repository's `maxx` branch; see the beginning of the document.
2. ~~The initial crate layout~~: decided (2026-10-27); see [Crate layout](../architecture.md#crate-layout).
3. ~~Whether v1 includes tools~~: decided (2026-10-27): it does; see [Tools and codemode](../design/tools.md). Intent classification is also in v1; see [Intent](../design/intent.md).
4. ~~The design of the new schema, and the mapping for importing from the old database~~: decided (2026-10-27); see [Schema](../design/ledger.md#schema).
5. ~~Whether the NixOS module's interface stays unchanged~~: decided (2026-10-27): it does not; see [Configuration](../design/config.md).
6. ~~Whether Matrix encrypted rooms are supported~~: decided (2026-10-27): they are; on 2026-10-29 Matrix as a whole was deferred; see [Matrix](../decisions/matrix-deferred.md).
7. ~~The v1 test environment~~: decided (2026-10-27): a parallel `maxx` set of services; see [Test environment](go-live.md#test-environment).
8. ~~The Rust toolchain version and edition~~: decided (2026-10-27): stable with a pinned version, edition 2024; see [Toolchain](../../AGENTS.md#toolchain).
9. ~~The size limit for each commit~~: decided (2026-10-27); see [Reviewability constraints](../../AGENTS.md#reviewability).
10. The TBD items at the end of the [Data and execution model](../architecture.md#principles-of-the-data-and-execution-model) section: retention, and whether to give notice of turns lost in a crash. How the base context is stored and its trimming rules have been decided, and suspended turns are no longer resumed.
11. ~~The identity model~~: decided (2026-10-27); see [Identity](../design/identity.md). Cross-platform merging will be done together with mirroring.
12. The TBD items at the end of the [Tools and codemode](../design/tools.md) section: which Max tools v1 opens up, the image budget, and code escaping. Calling into the VM has been decided: it uses russh.
