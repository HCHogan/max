# Decisions

Why Max is built the way it is: one file for each decision that was a real trade-off, with its context, what was decided, why, and what it costs. How each part works now is in [design/](../design/); these say why it isn't otherwise.

## The agent and its context

- [The agent loop is written in-house, sans-I/O](own-agent-loop.md)
- [The LLM client is written in-house](own-llm-client.md)
- [The tail is split into messages by turn](tail-split-by-turn.md)
- [Memory is a file Max writes itself](memory-is-a-file.md)
- [Max tidies its own memory](max-tidies-its-own-memory.md)
- [No historian, no summaries](no-summaries.md)
- [One tool for recall, on trigrams and half-precision vectors](history-tool.md)
- [Rare cases fail plainly](rare-cases-fail-plainly.md)

## Tools and programs

- [The guest calls the host over plain HTTP, as one caller](plain-http-for-the-guest.md)
- [Keyed APIs are forwarded by the host](host-keyed-apis.md)
- [GitHub through keyed APIs, not host tools](github-through-keyed-apis.md)
- [The browser is a resident Chromium](resident-chromium.md)
- [Resident programs are systemd units Max writes](resident-programs.md)
- [Programs have every tool, and no caps](no-limits-for-programs.md)
- [One conversation's Max can ask another's](asking-another-conversation.md)
- [An ended agent is taken up by a fork](resume-by-fork.md)

## VMs and processes

- [The VMs run without a broker or root](vms-without-a-broker.md)
- [What runs in a VM is systemd's to keep](lifetimes-to-systemd.md)
- [What leaves the host process](what-leaves-the-host.md)
- [max's socket is systemd's](max-socket-is-systemds.md)
- [A guest's calls come straight to max](guests-reach-max-directly.md)
- [A guest reset ends its VM](a-guest-reset-ends-its-vm.md)
- [A forwarder keeps no count](forwarder-keeps-no-count.md)
- [Idle guests drop their caches; the VMs' sizes stay](idle-guests-drop-caches.md)
- [The derived-data workers share conventions, not a framework](no-worker-framework.md)

## Platforms and people

- [QQ through the official bot API](official-qq-bot.md)
- [No matching people by avatar](no-avatar-matching.md)
- [Matrix is deferred](matrix-deferred.md)
- [Features deliberately removed](features-removed.md)

## Engineering

- [Tests keep to the critical path](tests-on-the-critical-path.md)
