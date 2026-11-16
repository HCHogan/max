# GitHub through keyed APIs, not host tools

Max opens PRs with its own account when asked, and revises, closes and
answers them itself. It reaches GitHub through the host's keyed APIs, not
through tools of the host's own. The design is in
[GitHub](../design/tools.md#github).

## Before: two host tools

- **`github_push`**: the guest made a bundle; the host created an empty bare
  repository, shallow-fetched the prerequisite commits, took the bundle with
  `fetch.fsckObjects` and pushed, so the host never ran git in a repository
  the guest had written.
- **`github`** called the REST API and returned `{status, body}`, cut past
  30,000 characters.
- **The host's rules**: writes only to Max's own repositories, the PRs and
  issues it opened and its own comments; at most 10 new PRs a day across all
  groups; an AI footnote appended to every PR description.

Over three days `github` was called 66 times (in 26 rounds) and
`github_push` 9 times (in 8 rounds), without an error.

## Decision

Remove both tools and their rules; reach GitHub through two keyed APIs,
`github` and `github-git`, and leave what to do to Max's judgement.

## Why

The groups are small, so abuse is unlikely; every model knows the fork,
clone, push and PR workflow well; and the rules' code outweighed what it
guarded against. The token still stays on the host, and is a classic token
limited to `public_repo`.

## Cost

Nothing on the host stops a PR nobody asked for, or one without its AI line;
`about` asks for both.
