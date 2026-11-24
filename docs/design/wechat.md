# WeChat through the desktop client

Max is on WeChat through the official desktop client for Linux, in a VM,
which [wxdesk](https://github.com/HCHogan/wxdesk) reads and drives:
it reads the window through AT-SPI, the accessibility bus Qt exposes, and
acts through XTEST and the X clipboard, as a person at the screen would.
Nothing is hooked, injected or decrypted. wxdesk serves what it reads over
TCP, one JSON value a line (`wxdesk-proto`), and WeChat's adapter (see
[Platforms](platforms.md)) is `crates/max-wechat`. Why the desktop client,
and not WeChat's bot channel or a hook, is in
[decisions/wechat-through-the-desktop-client.md](../decisions/wechat-through-the-desktop-client.md).

It is for one group and a few friends who talk to Max privately: wxdesk
keeps the group open and goes to a private chat only when the session list
shows news there.

The configuration is `[platforms.wechat]`, which `max-wechat` reads:
`address`, where wxdesk listens; `token_file`, the token wxdesk wants
first; and `name`, what Max is called on WeChat, as the client shows it.

## The client and wxdesk

- WeChat runs as the user `wx` in an Xvnc display of its own, with the
  accessibility bus on (`QT_ACCESSIBILITY=1`). It is logged in once, by
  scanning a QR code through VNC; the login lasts in the VM's disk, but
  when the client starts again the phone has to confirm it. So a deploy
  doesn't restart the VM: a new image boots when its service is next
  started.
  wxdesk's NixOS module runs both; the group's name is in the VM's
  `/var/lib/wxdesk/env`, out of the store and the repository.
- **Reading**: the open chat's messages are a list whose items are named by
  their content alone. Who sent a row shows only in the widgets WeChat
  draws it with, an avatar named after the sender, which wxdesk pairs with
  the row where it is drawn. New rows are those past the ones read before;
  a row that changes as it goes (a file downloading, a voice message
  played) is the same row.
- **Private chats**: wxdesk opens one when its item in the session list
  changes, reads what is new, and goes back to the group.
- **Pictures and files**: a picture is copied from the window (right-click,
  复制) once it has downloaded; a file is taken from the client's download
  directory once the client marks it read-only, as it does when the
  download is whole.
- **Sending**: text is pasted into the chat's input; a mention is typed as
  `@`, the name and a pick from the client's list, before the text; a
  picture and a file are pasted from the clipboard.

## Connection

- `max-wechat` connects to wxdesk as Max listens, not as max starts: the
  VM may be starting still. It connects again 5 seconds after the
  connection drops, for as long as max runs; WeChat never shuts Max out
  for good.
- wxdesk keeps up to 500 messages while no client is connected, and gives
  them to the next one after its hello: what is said while max restarts
  comes after it. What is said while wxdesk restarts is lost.
- One connection carries both ways: the listener reads it and hands the
  sender wxdesk's answers to its commands, by id.

## Inbound

- **Chats** are `group:<the group's name>` and `user:<the friend's
  name>`, as the session list shows them: renaming a group makes another
  chat.
- **People** are known by their names, as the client shows them: the
  window shows no other id. A friend's name is the remark the owner gives
  them. Someone who changes their name is someone else to Max. A member
  of the group has the role member: the window doesn't tell the owner or
  the admins.
- **A message's id** is wxdesk's run and its sequence number.
- **Mentions** are `@name` followed by a four-per-em space: Max's own,
  of everyone (`@所有人`), or of someone by name.
- **Quotes** come as the quoted sender's name and text, which the
  quoted message is found by.
- **Pictures and files** come with their bytes, which go into the content
  store. Voice messages and stickers come as what they are, without
  their content. Lines of the client's own, such as someone joining, and
  Max's own messages aren't entered.

## Outbound

- The sender says one message at a time, in the order committed: wxdesk
  says everything in one window. A message's text goes first, with its
  mentions before it, then its picture or file: a picture as PNG, a file
  under its name, up to 64 MiB.
- WeChat shows no id for what Max says: a delivered row's native id is
  `out-` and its own id.
- wxdesk answers each command once it has pressed send. A command waits
  up to 3 minutes, as wxdesk may be copying a picture or reading a private
  chat; past that, or when the connection drops, whether it went out isn't
  known.
- Recalling and editing aren't possible: wxdesk does neither, and the
  model is told so.

## Open

- A chat that gets more messages between two looks than the window shows
  loses the ones in between.
