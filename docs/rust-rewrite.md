# The Rust rewrite of Max (moved)

This document was split up on 2026-11-15; [README.md](README.md) is the index.
Code, Nix files and migrations still name its sections ("See \"Memory\" in
docs/rust-rewrite.md"); this page says where each section is now, so those
references keep working. Migrations must never be edited to fix them: sqlx
checks an applied migration's checksum.

| Section | Now at |
| --- | --- |
| Goals | [architecture.md](architecture.md#goals) |
| Versions | [archive/v1.md](archive/v1.md#versions) |
| &nbsp;&nbsp;v1 scope | [archive/v1.md](archive/v1.md#v1-scope) |
| &nbsp;&nbsp;Features deliberately removed | [decisions/2026-10-28-features-removed.md](decisions/2026-10-28-features-removed.md#features-deliberately-removed-1) |
| &nbsp;&nbsp;Feature parity checklist | [archive/haskell-parity.md](archive/haskell-parity.md#feature-parity-checklist) |
| Technology choices | [architecture.md](architecture.md#technology-choices) |
| Configuration | [design/config.md](design/config.md#configuration-1) |
| &nbsp;&nbsp;Source and validation | [design/config.md](design/config.md#source-and-validation) |
| &nbsp;&nbsp;Relationship to NixOS | [design/config.md](design/config.md#relationship-to-nixos) |
| &nbsp;&nbsp;Two layers: the configuration file and runtime settings | [design/config.md](design/config.md#two-layers-the-configuration-file-and-runtime-settings) |
| &nbsp;&nbsp;Settings a conversation sets | [design/config.md](design/config.md#settings-a-conversation-sets) |
| &nbsp;&nbsp;LLM: providers, models and selection | [design/config.md](design/config.md#llm-providers-models-and-selection) |
| Runtime structure | [architecture.md](architecture.md#runtime-structure) |
| &nbsp;&nbsp;The three roles | [architecture.md](architecture.md#the-three-roles) |
| &nbsp;&nbsp;How resources end | [design/lifetimes.md](design/lifetimes.md#how-resources-end) |
| &nbsp;&nbsp;Cancellation safety | [design/lifetimes.md](design/lifetimes.md#cancellation-safety) |
| &nbsp;&nbsp;Timeouts | [design/lifetimes.md](design/lifetimes.md#timeouts) |
| Data and execution model | [architecture.md](architecture.md#data-and-execution-model) |
| &nbsp;&nbsp;Principles | [architecture.md](architecture.md#principles) |
| &nbsp;&nbsp;The ledger | [design/ledger.md](design/ledger.md#the-ledger-1) |
| &nbsp;&nbsp;The timeline | [design/ledger.md](design/ledger.md#the-timeline) |
| &nbsp;&nbsp;Message format | [design/ledger.md](design/ledger.md#message-format) |
| &nbsp;&nbsp;How replies are written | [design/ledger.md](design/ledger.md#how-replies-are-written) |
| &nbsp;&nbsp;Outbound | [design/ledger.md](design/ledger.md#outbound) |
| &nbsp;&nbsp;Turn records | [design/ledger.md](design/ledger.md#turn-records) |
| &nbsp;&nbsp;Entries | [design/ledger.md](design/ledger.md#entries) |
| &nbsp;&nbsp;The core | [design/core.md](design/core.md#the-core-1) |
| &nbsp;&nbsp;I/O tasks and protocol adapters | [design/core.md](design/core.md#io-tasks-and-protocol-adapters) |
| &nbsp;&nbsp;The conversation actor | [design/actor.md](design/actor.md#the-conversation-actor-1) |
| &nbsp;&nbsp;Processing flow | [design/actor.md](design/actor.md#processing-flow) |
| &nbsp;&nbsp;What the group sees | [design/actor.md](design/actor.md#what-the-group-sees) |
| &nbsp;&nbsp;Cancellation | [design/actor.md](design/actor.md#cancellation) |
| &nbsp;&nbsp;Restarts | [design/actor.md](design/actor.md#restarts) |
| &nbsp;&nbsp;Size and retention | [design/actor.md](design/actor.md#size-and-retention) |
| &nbsp;&nbsp;Testing the core and the actor | [design/actor.md](design/actor.md#testing-the-core-and-the-actor) |
| &nbsp;&nbsp;Other uses of the same pattern | [design/actor.md](design/actor.md#other-uses-of-the-same-pattern) |
| &nbsp;&nbsp;Open questions | [design/actor.md](design/actor.md#open-questions) |
| Context projection | [design/context.md](design/context.md#context-projection-1) |
| &nbsp;&nbsp;Request layout | [design/context.md](design/context.md#request-layout) |
| &nbsp;&nbsp;Follow-up input | [design/context.md](design/context.md#follow-up-input) |
| &nbsp;&nbsp;Rules for a stable prefix | [design/context.md](design/context.md#rules-for-a-stable-prefix) |
| &nbsp;&nbsp;Budget | [design/context.md](design/context.md#budget) |
| &nbsp;&nbsp;Summaries | [design/context.md](design/context.md#summaries) |
| &nbsp;&nbsp;Commands | [design/context.md](design/context.md#commands) |
| &nbsp;&nbsp;Memory | [design/context.md](design/context.md#memory) |
| &nbsp;&nbsp;Recall | [design/context.md](design/context.md#recall) |
| &nbsp;&nbsp;What was cut | [design/context.md](design/context.md#what-was-cut) |
| Media | [design/media.md](design/media.md#media-1) |
| &nbsp;&nbsp;Sending images | [design/media.md](design/media.md#sending-images) |
| &nbsp;&nbsp;Sending files | [design/media.md](design/media.md#sending-files) |
| &nbsp;&nbsp;Reading files | [design/media.md](design/media.md#reading-files) |
| Schema | [design/ledger.md](design/ledger.md#schema) |
| &nbsp;&nbsp;Conventions | [design/ledger.md](design/ledger.md#conventions) |
| &nbsp;&nbsp;The v1 tables | [design/ledger.md](design/ledger.md#the-v1-tables) |
| &nbsp;&nbsp;What became of the old tables | [design/ledger.md](design/ledger.md#what-became-of-the-old-tables) |
| &nbsp;&nbsp;Import | [design/ledger.md](design/ledger.md#import) |
| Identity | [design/identity.md](design/identity.md#identity-1) |
| &nbsp;&nbsp;Tables | [design/identity.md](design/identity.md#tables) |
| &nbsp;&nbsp;Matching by avatar | [design/identity.md](design/identity.md#matching-by-avatar) |
| &nbsp;&nbsp;What the model sees | [design/identity.md](design/identity.md#what-the-model-sees) |
| &nbsp;&nbsp;Resolution and sending | [design/identity.md](design/identity.md#resolution-and-sending) |
| &nbsp;&nbsp;Permissions | [design/identity.md](design/identity.md#permissions) |
| &nbsp;&nbsp;Deferred from v1, with room reserved | [design/identity.md](design/identity.md#deferred-from-v1-with-room-reserved) |
| Intent | [design/intent.md](design/intent.md#intent-1) |
| &nbsp;&nbsp;Direct triggers and debouncing | [design/intent.md](design/intent.md#direct-triggers-and-debouncing) |
| &nbsp;&nbsp;Small-model classification | [design/intent.md](design/intent.md#small-model-classification) |
| &nbsp;&nbsp;State held only in memory | [design/intent.md](design/intent.md#state-held-only-in-memory) |
| The official QQ bot | [design/qq.md](design/qq.md#the-official-qq-bot-1) |
| Matrix | [decisions/2026-10-29-matrix-deferred.md](decisions/2026-10-29-matrix-deferred.md#matrix) |
| Tools and codemode | [design/tools.md](design/tools.md#tools-and-codemode-1) |
| &nbsp;&nbsp;Pure codemode | [design/tools.md](design/tools.md#pure-codemode) |
| &nbsp;&nbsp;Running in the group VM | [design/tools.md](design/tools.md#running-in-the-group-vm) |
| &nbsp;&nbsp;VM processes | [design/vm.md](design/vm.md#vm-processes) |
| &nbsp;&nbsp;The operations network | [design/vm.md](design/vm.md#the-operations-network) |
| &nbsp;&nbsp;The guest's calls | [design/tools.md](design/tools.md#the-guests-calls) |
| &nbsp;&nbsp;Multimodal results | [design/tools.md](design/tools.md#multimodal-results) |
| &nbsp;&nbsp;Web search | [design/tools.md](design/tools.md#web-search) |
| &nbsp;&nbsp;The browser | [design/tools.md](design/tools.md#the-browser) |
| &nbsp;&nbsp;GitHub | [design/tools.md](design/tools.md#github) |
| &nbsp;&nbsp;Host-keyed APIs | [design/tools.md](design/tools.md#host-keyed-apis) |
| &nbsp;&nbsp;Open items | [design/tools.md](design/tools.md#open-items) |
| Background agents | [design/jobs.md](design/jobs.md#background-agents) |
| &nbsp;&nbsp;Decoupling from the harness | [design/jobs.md](design/jobs.md#decoupling-from-the-harness) |
| Background commands | [design/jobs.md](design/jobs.md#background-commands) |
| Resident programs | [design/jobs.md](design/jobs.md#resident-programs) |
| Asking another conversation | [design/jobs.md](design/jobs.md#asking-another-conversation) |
| Lifetimes move to systemd | [decisions/2026-11-12-lifetimes-to-systemd.md](decisions/2026-11-12-lifetimes-to-systemd.md#lifetimes-move-to-systemd-1) |
| &nbsp;&nbsp;What the host knows | [decisions/2026-11-12-lifetimes-to-systemd.md](decisions/2026-11-12-lifetimes-to-systemd.md#what-the-host-knows) |
| &nbsp;&nbsp;Decided | [decisions/2026-11-12-lifetimes-to-systemd.md](decisions/2026-11-12-lifetimes-to-systemd.md#decided) |
| &nbsp;&nbsp;Checked first | [decisions/2026-11-12-lifetimes-to-systemd.md](decisions/2026-11-12-lifetimes-to-systemd.md#checked-first) |
| &nbsp;&nbsp;Step 1: a call is a unit, and so is a background command | [decisions/2026-11-12-lifetimes-to-systemd.md](decisions/2026-11-12-lifetimes-to-systemd.md#step-1-a-call-is-a-unit-and-so-is-a-background-command) |
| &nbsp;&nbsp;Step 2: the VMs outlive max | [decisions/2026-11-12-lifetimes-to-systemd.md](decisions/2026-11-12-lifetimes-to-systemd.md#step-2-the-vms-outlive-max) |
| &nbsp;&nbsp;Step 3: an agent is a unit of its own | [decisions/2026-11-12-lifetimes-to-systemd.md](decisions/2026-11-12-lifetimes-to-systemd.md#step-3-an-agent-is-a-unit-of-its-own) |
| &nbsp;&nbsp;Step 4: one caller | [decisions/2026-11-12-lifetimes-to-systemd.md](decisions/2026-11-12-lifetimes-to-systemd.md#step-4-one-caller) |
| &nbsp;&nbsp;Step 5: a question keeps no wait | [decisions/2026-11-12-lifetimes-to-systemd.md](decisions/2026-11-12-lifetimes-to-systemd.md#step-5-a-question-keeps-no-wait) |
| &nbsp;&nbsp;Afterwards | [decisions/2026-11-12-lifetimes-to-systemd.md](decisions/2026-11-12-lifetimes-to-systemd.md#afterwards) |
| &nbsp;&nbsp;What changes for the group and for Max | [decisions/2026-11-12-lifetimes-to-systemd.md](decisions/2026-11-12-lifetimes-to-systemd.md#what-changes-for-the-group-and-for-max) |
| What leaves the host process | [decisions/2026-11-14-what-leaves-the-host.md](decisions/2026-11-14-what-leaves-the-host.md#what-leaves-the-host-process-1) |
| &nbsp;&nbsp;The survey | [decisions/2026-11-14-what-leaves-the-host.md](decisions/2026-11-14-what-leaves-the-host.md#the-survey) |
| &nbsp;&nbsp;A VM's forwarder | [design/vm.md](design/vm.md#a-vms-forwarder) |
| Crate layout | [architecture.md](architecture.md#crate-layout) |
| &nbsp;&nbsp;Toolchain | [../AGENTS.md](../AGENTS.md#toolchain) |
| Reviewability constraints | [../AGENTS.md](../AGENTS.md#reviewability-constraints) |
| Testing | [../AGENTS.md](../AGENTS.md#testing) |
| &nbsp;&nbsp;Test environment | [archive/go-live.md](archive/go-live.md#test-environment) |
| v1 implementation order | [archive/v1-implementation-order.md](archive/v1-implementation-order.md#v1-implementation-order-1) |
| Go-live: conditions for a drop-in replacement | [archive/go-live.md](archive/go-live.md#go-live-conditions-for-a-drop-in-replacement) |
| Research: DSH and qq-bridge | [research/dsh-qq-bridge.md](research/dsh-qq-bridge.md#research-dsh-and-qq-bridge-1) |
| Research: the classification model | [research/classification-model.md](research/classification-model.md#research-the-classification-model-1) |
| Open for discussion | [archive/open-for-discussion.md](archive/open-for-discussion.md#open-for-discussion-1) |

Older names some comments use:

| Name | Section |
| --- | --- |
| schema | [Schema](design/ledger.md#schema) |
| 身份 | [Identity](design/identity.md#identity-1) |
| 后台 agent | [Background agents](design/jobs.md#background-agents) |
| 记忆 | [Memory](design/context.md#memory) |
| 摘要 | [Summaries](design/context.md#summaries) |
| historian | [Summaries](design/context.md#summaries) |
