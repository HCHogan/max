# Feature parity with the Haskell version

## Feature parity checklist

Features are listed by the entries of [features.md](https://github.com/HCHogan/max/blob/a5de2e1410f5cdfaa4b88c052bd499ee8b676759/docs/features.md). Every feature that has not been removed must be complete before go-live. The v1 column is only a proposal and is revised in discussion.

| Feature | v1 | Notes |
| --- | --- | --- |
| Conversation lifetime and history | Partial | A single core instance, input delivery and the idle window. On restart, a running turn is given a grace period and then interrupted; after a crash, a turn that was running is recorded as `Lost`; see [Restarts](../design/actor.md#restarts) |
| Automations | — |  |
| Sandbox isolation | Partial | The runtime environment of codemode; v1 needs start on demand, idle shutdown, command execution and `/work` |
| Attachment fan-out and QQ best-effort recovery | — |  |
| Persistence | Partial | The ledger and turn records; for the new schema, see [Schema](../design/ledger.md#schema) |
| Canonical multi-platform conversations | Partial | The [Message format](../design/ledger.md#message-format) does not branch by platform; v1 has only QQ. Matrix and mirroring are deferred; see [Matrix](../decisions/2026-10-29-matrix-deferred.md#matrix) |
| Triggering | ✓ | Triggered by mentions (@) and replies; private chats by allowlist |
| Proactive triggering | ✓ | [Intent](../design/intent.md#intent-1), made part of v1 on 2026-10-27. Simplified on 2026-10-29: only debouncing, small-model classification and the hourly cap remain; the Haskell version's gates, three verdict categories and topic cooldown were all removed |
| Inbound message hooks | — | Not implemented for now; see [Features deliberately removed](../decisions/2026-10-28-features-removed.md#features-deliberately-removed-1) |
| QQ group allowlist | ✓ | Replaced by `/bind`: the platform itself lets only the bot's creator add it to groups, and unbound groups are not served; see [The official QQ bot](../design/qq.md#the-official-qq-bot-1) |
| Private chats | ✓ | Replaced by an allowlist: a private chat triggers only for people on the list; see step 2 of [Processing flow](../design/actor.md#processing-flow). The Haskell version replied to every private chat |
| Agent loop | ✓ | Processing and failure reactions are no longer attached; on failure, a one-sentence reply is sent; see [What the group sees](../design/actor.md#what-the-group-sees) |
| Background agents and feedback | Partial | pi + `maxx`; see [Background agents](../design/jobs.md#background-agents). The `agent` family of tools was implemented on 2026-10-30, and job results wake Max; during a job, it asks Max, or a conversation Max may ask, with Max's `ask` tool (`ask_max` until 2026-11-11) |
| Prompt shape and budget | Partial | See [Context projection](../design/context.md#context-projection-1) |
| Memory | Yes | Replaced by a single file that Max writes itself, injected on every turn; see [Memory](../design/context.md#memory). The Haskell version's proposals, versions and expiry were all dropped |
| Group lingo | — |  |
| Unified recall and vector search | Partial | `history` searches the current conversation's messages literally and by meaning (including the captions of images and stickers), and reads original text by speaker and time; see [Recall](../design/context.md#recall). Memory is not searched, since it is in the context on every turn; videos have no captions |
| Context operations | — | In the Haskell version, the context console in the admin panel: overrides and deferrals, rebuilding summaries, recomputing vectors and retrieval traces. To be built together with the Admin JSON API. The model's own context operation is `history`; see [Recall](../design/context.md#recall) |
| LLM profiles | ✓ |  |
| Streaming | ✓ |  |
| Share cards | — |  |
| Images | — | For images in tool results, see [Multimodal results](../design/tools.md#multimodal-results); for Max sending images and stickers, see [Sending images](../design/media.md#sending-images) |
| Group awareness | — | The group's name, member count and maxx's role in the group are available (`info`, `bot_state`; verified in testing). The member list requires allowlisting; the group owner and administrators can be recognised only once they have spoken (messages carry the sender's role); see the group management part of [The official QQ bot](../design/qq.md#the-official-qq-bot-1) |
| Moderation (QQ groups) | — | `recall_message` and `mute_member` were implemented on 2026-10-29; see the outbound and group management parts of [The official QQ bot](../design/qq.md#the-official-qq-bot-1). Muting was verified in the test group; maxx retracting an ordinary member's message as an administrator has not been tested |
| Browser | — | A resident Chromium in the group VM, driven by programs directly with Playwright over CDP (completed 2026-10-29); see [The browser](../design/tools.md#the-browser) |
| Replies | ✓ | QQ always receives native Markdown, and tables and code blocks are no longer rendered as images; see [The official QQ bot](../design/qq.md#the-official-qq-bot-1). Max does not send QQ face emoticons; stickers and images are sent as images; see [Sending images](../design/media.md#sending-images) |
| Tools | Partial | Pure codemode plus `shell`; see [Tools and codemode](../design/tools.md#tools-and-codemode-1). Which tools v1 exposes is **TBD** |
| Skills | — | A skill is only documentation: loading one only appends to the end of the context, and the tools array stays unchanged; see [Pure codemode](../design/tools.md#pure-codemode) |
| Destiny 2 (opt-in) | Partial | 2026-11-05: public read-only data goes through the [Host-keyed APIs](../design/tools.md#host-keyed-apis) (`[api.bungie]`, configured in nix-config); Max writes its own scripts and caches the manifest. Features that require a player to log in (inventory, moving and equipping items) are not implemented: they would need per-person OAuth, whereas the forwarder holds one fixed key and cannot tell who in the VM is calling. Only 3 people ever logged in to the Haskell version |
| Commands | Partial | `/kill` and other runtime commands, handled by the conversation actor rather than the core |
| SSH fleet operations | ✓ | 2026-11-05; see [The operations network](../design/vm.md#the-operations-network) |
| Admin JSON API | — |  |
| Token accounting | Partial |  |
| Estimated cost | — |  |
| Subscription health | — |  |
