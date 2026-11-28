# WeChat through the desktop client

Max isn't on WeChat for now. The way onto it that was built is the
official desktop client for Linux in a VM, read through the accessibility
bus and driven with synthetic input, by wxdesk.
Its design is `git show 8b33f38d:docs/design/wechat.md`, and the adapter
`crates/max-wechat` at the same commit; the rows from then keep their
platform.

## Context

Max is wanted in a WeChat group, and in private chats with a few people.
WeChat has no bot API for personal accounts' groups:

- **iLink**, WeChat's channel for bots, is private chats only, with a
  limit on how many messages answer one.
- **Hooks** of the Windows client (injected DLLs) break with each client
  version, risk the account, and are the kind of project Tencent has had
  taken down.
- **Decrypting the client's database** to read messages: Tencent had a
  dozen such repositories on GitHub taken down in 2026, and max's
  repository is public.
- **Web and iPad protocols** are reimplementations of Tencent's private
  protocols, run by third parties, and risk the account.

## Decision

The official WeChat for Linux runs in a NixOS VM, logged in once by QR
code over VNC. wxdesk, in a repository of its own, reads the window
through AT-SPI, as a screen reader does, and acts with XTEST and the X
clipboard, as a person at the screen does; it serves what it reads over
TCP to an adapter crate, `max-wechat`.

## Why

- It uses the client as it is, with nothing injected and nothing
  decrypted: what the account does is what a person at the window could
  do, and nothing in max's repository is a target.
- Linux's client exposes its widgets on the accessibility bus with their
  text, so reading needs no OCR; the Windows client is the other way to
  this, at the cost of a Windows VM.
- A VM keeps the client, its display and its login apart from the host,
  with the rest of Max's VMs on tank.

## Cost

- People are known only by the names the client shows: the window has no
  stable id. Someone who changes their name is someone else, and two
  members of one name are one.
- It is slow and narrow: one window, so one message at a time, and one
  group watched; a private chat is read only when the session list shows
  news there. More messages between two looks than the window shows are
  lost.
- No recalling, editing, muting or quoting by Max, and voice messages and
  stickers come without their content.
- It breaks when the client's window changes, as a new version may.
