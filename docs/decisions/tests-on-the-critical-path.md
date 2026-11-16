# Tests keep to the critical path

Max's tests cover the critical path and little else: 93 tests in about 4,700 lines, where there had been 374 in 17,800. Which tests there are, and how one is written, is in [AGENTS.md](../../AGENTS.md#testing) and [the actor's Testing](../design/actor.md#testing).

## Context

There were 374 tests in 17,800 lines, against some 20,000 lines of the code they tested. A test or more had come with nearly every change, since a commit passes its tests by itself and changes are written faster than they are read. Most of the code is a shell around a database, a model and a platform, so most tests first built that world: 138 took a database each, and a quarter of the test code was fixtures. The tests were the repository's second largest part, and would shrink only with the rules they held, never on their own.

## Decision

Keep the tests that are on the critical path and worth their lines, under 5,000 lines in all.

- **Kept:** the core's and intent's state machines; what the segmenter and its parser send to the chat; the base context and a day's rows as the model reads them; each protocol's request, and its answers as four providers recorded them; a call that is cut off or goes quiet; the ledger's rows, turns and accounts read back as written, and the migrations; the actor once for each way a turn starts and ends; the table binding a group, and a turn lost in a crash; what QQ sends in and what goes out to it; a program calling Max's tools through the runner; a call naming its own VM; a path that stays in `/work` and an API call that stays under its base; the command parser, the bind code, `Scope`, a call's line as the guest prints it, and a boot's record.
- **Gone:** every tool's own tests (history, files, pictures, stickers, muting, taking back, asking another conversation, settings); the commands' output; the workers (download, captions, embeddings, recall, the dreamer) and their tables; the media store and what prepares a picture; the VM service's slots, images and units; `/events`; the forwarder's own routes; the configuration's parsing; `webread`; the chunker's unit tests, whose properties are proved in `verify/`.

## Why these

A kept test guards something that a mistake in doesn't show by itself (a context built wrong, a row stored in another shape, an answer taken for whole), or a wall (a guest's path, a key's base, whose VM a call is), or is the one pass through a path that everything else rides on. What went is seen at once when it breaks (a command's wording, a tool's refusal), or is made again from the ledger (the workers' tables), or was never really tested without a VM (the VM service, the forwarder), where `vm-check`, the jobs test and the nested test still are.

## Cost

- A change to a tool, a worker, the VM service or the configuration is no longer checked by `cargo nextest`. It is read, tried by hand or in the nested test, and otherwise found in production.
- The code is written by agents, which lean on tests more than a person does: a test was what kept the next change from undoing a rule nobody remembered. Those rules now stand only in the design files and the code's comments.
- A cut test's name was the record that its rule was meant. The names are in the history: `git show --stat` of the commit that made this cut lists the files, and `git restore --source=<that commit>^ -- <path>` brings one back.
