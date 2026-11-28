# Decisions

Why Max is built the way it is now: one file for each subject that was a
real trade-off, with its context, what is decided, why, what it costs and
the alternatives that lost. How each part works is in
[design/](../design/); these say why it isn't otherwise. They are kept
true as the design is: a decision that changes is rewritten, and how it
got so is in git's history.

## The agent and its context

- [The agent loop is written in-house, sans-I/O](own-agent-loop.md)
- [The LLM client is written in-house](own-llm-client.md)
- [The tail is split into messages by turn](tail-split-by-turn.md)
- [Memory is a file Max writes and tidies itself](memory-is-a-file.md)
- [No historian, no summaries](no-summaries.md)
- [Recall is one tool, and search goes by keywords](history-tool.md)
- [Rare cases fail plainly](rare-cases-fail-plainly.md)
- [Direct triggers aren't held back](no-debounce.md)
- [Max says little, and joins in seldom](max-says-little.md)
- [The classifier wakes Max in two cases, given by example](classifier-by-example.md)

## Tools and programs

- [A guest's calls come straight to max, over plain HTTP](guests-reach-max-directly.md)
- [Keyed APIs are forwarded by the host, GitHub among them](host-keyed-apis.md)
- [The browser is a resident Chromium, and a snapshot's refs hold](resident-chromium.md)
- [Resident programs are systemd units Max writes, with every tool](resident-programs.md)
- [What wakes Max from outside the chat is a row](wakes-are-rows.md)
- [A link lets Max into another conversation's VM, and that is all](links-enter-only.md)
- [A background agent is fx in a background command](agents-are-background-commands.md)

## VMs and processes

- [The VMs run without a broker or root](vms-without-a-broker.md)
- [What runs in a VM is systemd's to keep](lifetimes-to-systemd.md)
- [A guest reset ends its VM](a-guest-reset-ends-its-vm.md)
- [A new image restarts its VMs](a-new-image-restarts-its-vms.md)
- [Idle guests drop their caches; the VMs' sizes stay](idle-guests-drop-caches.md)
- [Max joins tailnets itself](max-joins-tailnets-itself.md)
- [The derived-data workers share conventions, not a framework](no-worker-framework.md)
- [Max has a Postgres cluster of its own](own-postgres.md)

## Platforms and people

- [The conversation is the finest grain of permission](permission-by-conversation.md)
- [A platform is an adapter crate behind max's trait](platform-adapters.md)
- [QQ through the official bot API](official-qq-bot.md)
- [WeChat through the desktop client](wechat-through-the-desktop-client.md) (on hold)
- [No matching people by avatar](no-avatar-matching.md)
- [Matrix is deferred](matrix-deferred.md)
- [Features deliberately removed](features-removed.md)

## Engineering

- [Tests keep to the critical path](tests-on-the-critical-path.md)
- [The pins move by themselves each night](pins-move-nightly.md)
