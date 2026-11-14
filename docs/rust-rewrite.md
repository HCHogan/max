# The Rust rewrite of Max (moved)

This document was split up on 2026-11-15, by kind: the design as it is now, the
decisions and their reasons, research, and finished history. [README.md](README.md)
is the index. Comments in code, Nix files and migrations still name its sections
(`See "Memory" in docs/rust-rewrite.md`), so this page says where each one is
now. A migration must never be edited to update such a comment: sqlx checks an
applied migration's checksum.

| Section | Now at |
| --- | --- |
| Goals | [architecture.md](architecture.md#goals) |
| Versions | [archive/v1.md](archive/v1.md#versions) |
| v1 scope | [archive/v1.md](archive/v1.md#v1-scope) |
| Features deliberately removed | [decisions/2026-10-28-features-removed.md](decisions/2026-10-28-features-removed.md) |
| Feature parity checklist | [archive/haskell-parity.md](archive/haskell-parity.md) |
| Technology choices | [architecture.md](architecture.md#technology) |
| Configuration | [design/config.md](design/config.md) |
| Source and validation | [design/config.md](design/config.md#source-and-validation) |
| Relationship to NixOS | [design/config.md](design/config.md#nixos) |
| Two layers: the configuration file and runtime settings | [design/config.md](design/config.md) |
| Settings a conversation sets | [design/config.md](design/config.md#settings-a-conversation-sets) |
| LLM: providers, models and selection | [design/config.md](design/config.md#models) |
| Runtime structure | [architecture.md](architecture.md#runtime-structure) |
| The three roles | [architecture.md](architecture.md#the-three-roles) |
| How resources end | [design/lifetimes.md](design/lifetimes.md#how-resources-end) |
| Cancellation safety | [design/lifetimes.md](design/lifetimes.md#cancellation-safety) |
| Timeouts | [design/lifetimes.md](design/lifetimes.md#timeouts) |
| Data and execution model | [architecture.md](architecture.md#principles-of-the-data-and-execution-model) |
| Principles | [architecture.md](architecture.md#principles-of-the-data-and-execution-model) |
| The ledger | [design/ledger.md](design/ledger.md) |
| The timeline | [design/ledger.md](design/ledger.md#the-timeline) |
| Message format | [design/ledger.md](design/ledger.md#message-format) |
| How replies are written | [design/ledger.md](design/ledger.md#how-replies-are-written) |
| Outbound | [design/ledger.md](design/ledger.md#outbound) |
| Turn records | [design/ledger.md](design/ledger.md#turn-records) |
| Entries | [design/ledger.md](design/ledger.md#entries) |
| The core | [design/core.md](design/core.md) |
| I/O tasks and protocol adapters | [design/core.md](design/core.md#io-tasks-and-protocol-adapters) |
| The conversation actor | [design/actor.md](design/actor.md) |
| Processing flow | [design/actor.md](design/actor.md#processing-flow) |
| What the group sees | [design/actor.md](design/actor.md#what-the-group-sees) |
| Cancellation | [design/actor.md](design/actor.md#cancellation) |
| Restarts | [design/actor.md](design/actor.md#restarts) |
| Size and retention | [design/actor.md](design/actor.md#size-and-retention) |
| Testing the core and the actor | [design/actor.md](design/actor.md#testing) |
| Other uses of the same pattern | [design/actor.md](design/actor.md#testing) |
| Open questions | [design/actor.md](design/actor.md#open) |
| Context projection | [design/context.md](design/context.md) |
| Request layout | [design/context.md](design/context.md#request-layout) |
| Follow-up input | [design/context.md](design/context.md#follow-up-input) |
| Rules for a stable prefix | [design/context.md](design/context.md#rules-for-a-stable-prefix) |
| Budget | [design/context.md](design/context.md#budget) |
| Summaries | [decisions/2026-11-02-no-summaries.md](decisions/2026-11-02-no-summaries.md) |
| Commands | [design/commands.md](design/commands.md) |
| Memory | [design/context.md](design/context.md#memory) |
| Recall | [design/context.md](design/context.md#recall) |
| What was cut | [design/context.md](design/context.md#not-there) |
| Media | [design/media.md](design/media.md) |
| Sending images | [design/media.md](design/media.md#sending-images) |
| Sending files | [design/media.md](design/media.md#sending-files) |
| Reading files | [design/media.md](design/media.md#reading-files) |
| Schema | [design/ledger.md](design/ledger.md#schema) |
| Conventions | [design/ledger.md](design/ledger.md#conventions) |
| The v1 tables | [design/ledger.md](design/ledger.md#tables) |
| What became of the old tables | [archive/import.md](archive/import.md#what-became-of-the-old-tables) |
| Import | [archive/import.md](archive/import.md#import) |
| Identity | [design/identity.md](design/identity.md) |
| Tables | [design/identity.md](design/identity.md#tables) |
| Matching by avatar | [decisions/2026-11-06-no-avatar-matching.md](decisions/2026-11-06-no-avatar-matching.md) |
| What the model sees | [design/identity.md](design/identity.md#what-the-model-sees) |
| Resolution and sending | [design/identity.md](design/identity.md#resolution-and-sending) |
| Permissions | [design/identity.md](design/identity.md#permissions) |
| Deferred from v1, with room reserved | [design/identity.md](design/identity.md#open) |
| Intent | [design/intent.md](design/intent.md) |
| Direct triggers and debouncing | [design/intent.md](design/intent.md#direct-triggers-and-the-debounce) |
| Small-model classification | [design/intent.md](design/intent.md#the-small-model) |
| State held only in memory | [design/intent.md](design/intent.md#state-held-only-in-memory) |
| The official QQ bot | [design/qq.md](design/qq.md) |
| Matrix | [decisions/2026-10-29-matrix-deferred.md](decisions/2026-10-29-matrix-deferred.md) |
| Tools and codemode | [design/tools.md](design/tools.md) |
| Pure codemode | [design/tools.md](design/tools.md#pure-codemode) |
| Running in the group VM | [design/tools.md](design/tools.md#running-in-the-groups-vm) |
| VM processes | [design/vm.md](design/vm.md) |
| The operations network | [design/vm.md](design/vm.md#the-operations-network) |
| The guest's calls | [design/tools.md](design/tools.md#the-guests-calls) |
| Multimodal results | [design/tools.md](design/tools.md#multimodal-results) |
| Web search | [design/tools.md](design/tools.md#web-search) |
| The browser | [design/tools.md](design/tools.md#the-browser) |
| GitHub | [design/tools.md](design/tools.md#github) |
| Host-keyed APIs | [design/tools.md](design/tools.md#host-keyed-apis) |
| Open items | [design/tools.md](design/tools.md#open) |
| Background agents | [design/jobs.md](design/jobs.md#background-agents) |
| Decoupling from the harness | [design/jobs.md](design/jobs.md#what-a-harness-keeps) |
| Background commands | [design/jobs.md](design/jobs.md#background-commands) |
| Resident programs | [design/jobs.md](design/jobs.md#resident-programs) |
| Asking another conversation | [design/jobs.md](design/jobs.md#asking-another-conversation) |
| Lifetimes move to systemd | [decisions/2026-11-12-lifetimes-to-systemd.md](decisions/2026-11-12-lifetimes-to-systemd.md) |
| What leaves the host process | [decisions/2026-11-14-what-leaves-the-host.md](decisions/2026-11-14-what-leaves-the-host.md) |
| The survey | [decisions/2026-11-14-what-leaves-the-host.md](decisions/2026-11-14-what-leaves-the-host.md#the-survey) |
| A VM's forwarder | [design/vm.md](design/vm.md#a-vms-forwarder) |
| Crate layout | [architecture.md](architecture.md#crate-layout) |
| Toolchain | [../AGENTS.md](../AGENTS.md#toolchain) |
| Reviewability constraints | [../AGENTS.md](../AGENTS.md#reviewability) |
| Testing | [../AGENTS.md](../AGENTS.md#testing) |
| Test environment | [archive/go-live.md](archive/go-live.md#test-environment) |
| v1 implementation order | [archive/v1-implementation-order.md](archive/v1-implementation-order.md) |
| Go-live: conditions for a drop-in replacement | [archive/go-live.md](archive/go-live.md#go-live-conditions-for-a-drop-in-replacement) |
| Research: DSH and qq-bridge | [research/dsh-qq-bridge.md](research/dsh-qq-bridge.md) |
| Research: the classification model | [research/classification-model.md](research/classification-model.md) |
| Open for discussion | [archive/open-for-discussion.md](archive/open-for-discussion.md) |

Other names comments use:

| Name | Now at |
| --- | --- |
| Derived-data workers | [architecture.md](architecture.md#the-three-roles) |
| Tool contract | [design/tools.md](design/tools.md#tool-contract) |
| Rows as data | [design/jobs.md](design/jobs.md#rows-as-data) |
| Resume across restarts | [design/qq.md](design/qq.md#connection) |
| Inbound | [design/qq.md](design/qq.md#inbound) |
| schema | [design/ledger.md](design/ledger.md#schema) |
| 身份 | [design/identity.md](design/identity.md) |
| 后台 agent | [design/jobs.md](design/jobs.md#background-agents) |
| 记忆 | [design/context.md](design/context.md#memory) |
| 摘要 | [decisions/2026-11-02-no-summaries.md](decisions/2026-11-02-no-summaries.md) |
| historian | [decisions/2026-11-02-no-summaries.md](decisions/2026-11-02-no-summaries.md) |
| 按头像接上 | [decisions/2026-11-06-no-avatar-matching.md](decisions/2026-11-06-no-avatar-matching.md) |
| 发图 | [design/media.md](design/media.md#sending-images) |
| 重启 | [design/actor.md](design/actor.md#restarts) |
