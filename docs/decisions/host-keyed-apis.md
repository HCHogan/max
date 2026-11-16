# Keyed APIs are forwarded by the host

Programs in a VM call services that need a key, such as one that sends
email, through the host, which adds the key. The design is in
[Host-keyed APIs](../design/tools.md#host-keyed-apis).

## Context

A host tool for every service that needs a key, as for GitHub and web
search, is too heavy. The key must still never enter the VM: group members
can have Max run anything there and read whatever it holds.

## Alternatives considered

- **Terminating HTTPS at the egress** and swapping placeholders the VM sends
  for the real key: [iron-proxy](https://github.com/ironsh/iron-proxy) (Go,
  Apache-2.0, refusing every unlisted domain), and the same feature in Docker
  Sandboxes and Deno Sandbox. git, gh and SDKs need no change; but the guest
  must trust a CA and all traffic detours through a proxy, while Max's VMs
  need the whole internet (the browser, `webread`).
- **An explicit proxy**: Fly.io's [tokenizer](https://github.com/superfly/tokenizer),
  which clients use as an HTTP proxy; it adds the key and sends the request
  out over HTTPS, each secret bound to the hosts it may go to.

## Decision

A proxy in tokenizer's manner, beside the background agents' `/llm`, on the
channel the VM already has to the host: `http://127.0.0.1:7777/api/<name>/…`,
with each API's `base_url`, where its key goes, which methods and paths it
allows and an hourly count in the configuration. No extra service to run:
the VM's forwarder answers it
([what leaves the host](what-leaves-the-host.md)).

## Cost

The key can't leak, but it can be misused by anyone who can have Max run
commands, within `allow` and `per_hour`. Where control needs the content
looked at, a host tool is still the answer.
