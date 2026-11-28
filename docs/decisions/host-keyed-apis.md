# Keyed APIs are forwarded by the host, GitHub among them

Programs in a VM call services that need a key, such as one that sends
email, through the host, which adds the key. GitHub is two such APIs, not
tools of the host's own. The design is in
[Host-keyed APIs](../design/tools.md#host-keyed-apis) and
[GitHub](../design/tools.md#github).

## Context

A key must never enter a VM: group members can have Max run anything
there and read whatever it holds. A host tool for every service that
needs a key is too heavy.

Max has a GitHub account of its own. When someone asks for a PR, Max
forks, clones, pushes and opens it, and later revises it, closes it and
answers comments.

## Decision

- A proxy on the channel the VM already has to the host:
  `http://127.0.0.1:7777/api/<name>/…`, in the manner of Fly.io's
  [tokenizer](https://github.com/superfly/tokenizer). The configuration
  gives each API's `base_url`, where its key goes, which methods and
  paths it allows and an hourly count. max answers it: there is no extra
  service to run.
- GitHub is two of these, `github` for the REST API and `github-git` for
  git over HTTPS. The host has no rules for them: what to open, revise or
  close is left to Max's judgement.

## Why

- Programs use curl, fetch, git or an SDK as they are, with another base
  URL. Nothing in the guest trusts a CA, and the guest's other traffic
  goes out as it did.
- A new service is a section of the configuration.
- For GitHub: the groups are small, so abuse is unlikely; every model
  knows the fork, clone, push and PR workflow well; and rules on the host
  outweigh what they guard against. The token still stays on the host,
  and is a classic token limited to `public_repo`.

## Cost

- The key can't leak, but it can be misused by anyone who can have Max
  run commands, within `allow` and `per_hour`. Where control needs the
  content looked at, a host tool is still the answer.
- Nothing on the host stops a PR nobody asked for, or one without its
  line saying an AI opened it; `about` asks for both.

## Alternatives

- **Terminating HTTPS at the egress** and swapping placeholders the VM
  sends for the real key:
  [iron-proxy](https://github.com/ironsh/iron-proxy), and the same
  feature in Docker Sandboxes and Deno Sandbox. git, gh and SDKs need no
  change at all; but the guest must trust a CA and all traffic detours
  through a proxy, while Max's VMs need the whole internet (the browser,
  `webread`).
- **Host tools for GitHub**: one that pushes a bundle the guest made, so
  that the host never runs git in a repository the guest wrote, and one
  that calls the REST API, with rules on the host (writes only to Max's
  own repositories, PRs, issues and comments; a daily cap on new PRs; a
  line appended to every PR). The rules' code outweighs what it guards
  against.
