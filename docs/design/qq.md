# The official QQ bot

Max is on QQ through Tencent's official bot API (the QQ Open Platform,
individually verified; the bot is named maxx), with the protocol in
[qqbot](https://github.com/HCHogan/qqbot), which also reads and writes
QQ's markup (mentions, faces, the transcripts below, Markdown as QQ
renders it) and says what QQ's errors mean, and QQ's adapter (see
[Platforms](platforms.md)) in `crates/max-qq`. Why not NapCat and OneBot, and how sending settled on
what it is, is in
[decisions/official-qq-bot.md](../decisions/official-qq-bot.md).
"Tested" below means tried in the test group; the rest is from QQ's
documentation.

The configuration is `[platforms.qq]`, which `max-qq` reads:
`app_id_file` and `app_secret_file`. The AppID isn't a secret, but it identifies the bot, so
like group ids it stays out of the repository.

## Connection

- The AppID and AppSecret are exchanged for an access token
  (`bots.qq.com/app/getAppAccessToken`, valid about two hours; a new one
  can be had only in the old one's last minute, and the old one stays valid
  a minute more, so it is exchanged 50 seconds before expiry). REST goes to
  `api.bot.qq.com` (the old `api.sgroup.qq.com` still works) with
  `Authorization: QQBot <token>`. Some errors come back as 200, so the
  body's `err_code` is checked.
- Events arrive over a WebSocket gateway that Max connects out to, so the
  host needs no public ingress (webhooks would, and exclude the
  WebSocket). It works like Discord's: Hello gives the heartbeat interval,
  Identify carries the token and intents, and after a disconnect the session
  id and the last sequence number Resume it; 1,500 new sessions a day.
- **Resume across restarts**: at shutdown the session id and last sequence
  number are stored in the database, and at startup Max resumes rather than
  starting a new session, so what was said during a restart is delivered
  again (a new session delivers nothing missed). Stops of 2 and 10 minutes
  resumed with everything delivered (tested); beyond the window only a new
  session is possible, and what was said meanwhile is lost. `qqbot` sends
  events into an unbounded channel, so a dropped connection future leaves
  no event counted in the sequence number but undelivered: after intake
  stops, the events left in the channel are read, and
  `Session::resumable`'s sequence number is exactly where to continue. A
  message delivered again that was already entered is dropped by the actor,
  by platform id. A separate resident process or a queue such as Redis would
  buy only an unbroken connection, which Resume already gives.
- The gateway session is a pure state machine (heartbeat, Resume,
  reconnection, each close code), tested without I/O; its driver is tested
  against a local WebSocket server.

## Groups and private chats

- **Which groups**: an individual's bot can be added only by its creator,
  only to groups where the creator is owner or administrator. The group
  owner turns on two switches in the group's settings:
  - "接收群内全部消息": every message arrives as `GROUP_MESSAGE_CREATE`,
    those that @ Max included (whether one does shows in `mentions`).
    Without it only @s arrive.
  - "机器人主动发言": Max may send at any time. Every message Max sends is
    proactive, so without it Max can't send at all; QQ answers 40034105
    "主动消息失败, 无权限" (tested).
- **Private chats**: an individual's bot can chat privately only with the
  trial users added under "开发设置" in the management console (tested).
  That list is the private-chat allowlist.
- **Identity**: no QQ numbers or group numbers, only openids per bot. A
  group is a `group_openid`; a member is a `member_openid`, different for
  the same person in each group; a private chat is a `user_openid`,
  different again. So on QQ an identity is one person in one group, or one
  private-chat partner. People aren't recognised across groups (memory is
  per conversation too); `union_openid` needs a separate application, which
  isn't made. Only the owner needs recognising, and `/bind` does it.
- **Endpoints**: `native_id` is `group:<group_openid>` or
  `c2c:<user_openid>`. The Haskell version's QQ endpoints and accounts are
  the platform `qq_legacy`, which has no adapter: openids and QQ numbers
  aren't one namespace.
- **`/bind`**: a new group is unbound; its messages are dropped and no
  conversation is created (step 1 of the
  [Processing flow](actor.md#processing-flow)). Binding takes two steps:
  1. The owner sends Max `/bind <old group number>` in a private chat, or
     `/bind` alone for a new conversation. Max answers with a 6-digit code,
     valid for 10 minutes.
  2. The owner sends `@maxx /bind <code>` in the new group. Its endpoint
     joins the old group's conversation (the one holding the `qq_legacy`
     endpoint), so the timeline continues from the old messages, and the
     sender's identity in the group is merged into the owner's principal
     (`merged_into`), so the owner is known there from then on.

  The code is held in memory and lost on restart. A group is bound once.
  In an unbound group `@maxx /bind <code>` is the only command recognised;
  a wrong code is dropped and logged, there being no endpoint to answer
  through. The `/bind` that succeeds goes from the conversation table to
  the actor as `Event::Bound`, is entered as usual and answered with
  `绑好了`. A stretch of old records joins one group only: a conversation may
  have one endpoint with an adapter, or two actors would write one
  timeline, so this is checked when the code is issued and again when it is
  used. The owners file lists only the owner's private `user_openid` for
  QQ, taken from the `c2c:` endpoint after the owner first writes to Max.

## Inbound

- Group and private messages share one message type, with `group_openid`
  nullable; a group event without one is malformed and logged. Other events
  (joining or leaving, switching proactive messages, …) aren't entered;
  their name and content are logged at info.
- **Sender**: `username` is the QQ nickname, not the group card (tested),
  and the group card isn't available, though the QQ client shows group
  cards in quotes and @s; so the name Max uses may differ from the one seen
  in the group, which is accepted. `member_role` is owner, admin or member.
  In a private chat the sender has no name and QQ offers no way to one: the
  documented author is only `user_openid`; the payloads' `username` and
  `union_openid` were empty in every private message seen; and every path
  that might describe a user (`/v2/users/{user_openid}`, with `/info`,
  `/bot_state` or `/profile`, and `/users/{user_openid}`) answers 404
  "不支持的调用" (11001, err_code 40011002). `union_openid` is filled only for
  a bot tied to a QQ 互联 application, applied for through the platform's
  staff; not tried.
- **@**: written in the body as `<@member_openid>`, and in `mentions`, where
  Max's entry has `is_you: true`.
- **Quotes**: the quoting message's `message_type` is 103; the quoted
  message is in `msg_elements` (its text, its quote index and its
  attachments, a picture with its file name; no author), and the quote index
  is also `ref_msg_idx` in `message_scene.ext`. When the quoted message
  itself quotes or holds a forward, `content` is a dump instead of its text
  (about one quote in nine): `=== 消息 1 ===`, its text after `[消息内容]`,
  `[消息类型] 引用消息`, its files on `[附件N] 类型:图片 文件名:… URL:…` lines,
  then what it quotes, indented, after `[关联消息]`. The adapter keeps the
  quoted message's own text, without mentions or faces, and its files'
  names; of a dump, only its own lines.
- **Finding what a quote quotes**: a message has two ids, the event's `id`
  (for retraction; `native_id`) and `msg_idx` (for quoting); for what Max
  sends, the send API returns `id` and `ext_info.ref_idx`. A quote's index
  is 96 bytes in 16-byte blocks: the last three are the group's, the second
  and third seem to follow the sender, and only the first is the message's,
  and that first block often differs from the one the message came with (in
  about half of picture quotes, at any delay and whoever quoted). So a quote
  is looked up first by the stored `msg_idx` (`messages.quote_id`, indexed)
  or a delivery's `ref_idx`; failing that, among the conversation's latest
  1,000 rows, newest first: by a picture's or file's name (`meta.name`, QQ's
  hash of the file), then by text, the first 16 characters of what is left
  once brackets, whitespace and `⏎` are removed, contained in a row's text.
  The text lookup picked the row the index named in 1,584 of 1,615 quotes,
  and an older row with the same text in 15; 99% of quotes go back fewer
  than 540 rows. When Max quotes, it uses the stored `ref_idx` or
  `msg_idx`.
- **Media**: pictures, voice messages and files are in `attachments`, with
  download URLs that need no authentication; voice messages also come as a
  converted wav with Tencent's transcription (tested: pictures carry width,
  height and size; files have `content_type` `file` and a file name, as do
  videos sent as files; native videos are `video/mp4` with width, height
  and size but no duration or cover; voice messages are `.amr`).
- **QQ emoticons** (tested): `<faceType=1,faceId="306",ext="<base64>">` in
  the body, whose `ext` decodes to `{"text":"牛气冲天"}`, so the name comes
  with it. `faceType=3` is a super emoticon; `6` is a saved sticker, with no
  name and its picture in `attachments`. The model sees `[face: name]`.
- **Merged forwards** (tested): `message_type = 102`; the body is a text
  transcript QQ assembles, each entry with its content and sender's
  nickname, and no structured sub-messages. Pictures, videos and files in
  it are written into the text with file name, dimensions, size and URL,
  and some files with no URL. A quote is the quoted text under
  `[关联消息]`; a forward inside it says `[消息类型] 合并转发消息`, with its
  messages under `[关联消息]` one level deeper, or with none at all (two
  of the six seen). Max's form of it is a line for the forward and one for
  each message, `名字: 内容`, a message's later lines and a nested
  forward's messages indented two spaces, a quote as `[reply: …]` before
  the text, and each picture, video and file a media node with QQ's URL,
  downloaded at once like any attachment, since QQ's URLs expire:

  ```text
  [forward: 群聊的聊天记录, 3 条]
  小明: 看这个 [image#9.0]
  小红: [reply: 看这个] 好家伙
  小明: [forward: 群聊的聊天记录, 1 条]
    小刚: 早
  ```
- **Cards** (tested): `message_type = 3`; `ark_data` holds the title, source
  and preview picture, and the body a text summary. Mini-program cards
  (Bilibili, Zhihu) don't carry the original link, so Max sees the title.
- The gateway doesn't push the bot's own messages, so there is no echo.

## Outbound

- **Every message is proactive**: no passive replies, as every group Max is
  in has "机器人主动发言" on.
- **Quotas**: proactive messages are limited to 60 a minute for the bot, and
  20 a minute and 1,000 a day per group. The sender queues per group and
  waits when over; nothing is dropped.
- **Format**: always native Markdown (`msg_type = 2`, in groups and private
  chats, no template needed), falling back to plain text when QQ rejects
  it. Tested: headings, bold, italic, strikethrough, inline code, nested and
  ordered lists, block quotes, code blocks (highlighted, with a copy button)
  and tables render, and `<` and `&` need no escaping. A single newline
  breaks the line; two trailing spaces add a blank line; a space after bold
  is swallowed. LaTeX `$…$`, `\(…\)`, `$$…$$` and `math` code blocks render;
  `\[…\]` doesn't, so outside code it is turned into `$$…$$`. Markdown
  links, bare links and URLs in plain text are all clickable. Pictures in
  Markdown show only from QQ's own domains. The length limit hasn't been
  tested.
- **Rejected or unknown**: a message counts as rejected, and is sent again
  as plain text, only when QQ answers with an error or no connection was
  made. If the request went out and then timed out, or the answer can't be
  parsed, QQ may have accepted it: the message is recorded `unknown`, the
  model sees `（可能没发出去）`, and a waiting tool is told it isn't known
  whether it went out. Never two copies.
- **@**: `<qqbot-at-user id="<member_openid>" />`, shown in Markdown as @
  and the group card.
- **Emoticons** can't be sent: `<faceType=…>` and `<emoji:id>` show
  literally (tested). See [How replies are written](ledger.md#how-replies-are-written).
- **Quotes**: `message_reference.message_id` is the quoted message's
  `msg_idx` or `ref_idx` (tested).
- **Retraction**: `DELETE /v2/groups/{group_openid}/messages/{id}`, or
  `/v2/users/{user_openid}/messages/{id}` in a private chat; 200 with no
  body. By the documentation: no message, whoever sent it, can be retracted
  more than 2 minutes after it was sent (40064004); as a group
  administrator the bot can retract its own messages and ordinary members'
  (by the event's `id`), otherwise only its own (40062003 "无操作权限");
  50065001 means try later; in a private chat only its own. Tested as an
  ordinary member: retracting a fresh message works, retracting it again
  also answers success, and a made-up id gives 40061001 "请求参数无效".
- **Media** is first uploaded for a `file_info`, then sent with
  `msg_type = 7`. Base64 can be uploaded directly, and a `file_info` lasts a
  day; `content` is a caption under the picture, in the same message, and
  may be left out, so the group sees only the picture, as with a member's
  sticker. GIFs are sent animated (134 frames and 1.9 MB tested). The
  upload's `raw_url` is empty, so a picture can't be put in Markdown. See
  [Sending images](media.md#sending-images),
  [Sending files](media.md#sending-files) and
  [Sending voice messages](media.md#sending-voice-messages).
- **Voice messages** (`file_type = 3`, tested 2026-11-18): MP3, WAV and Ogg
  were each uploaded without a `file_name`, and an MP3 sent to a group
  showed as a voice bar that played. QQ converts the audio itself: bytes
  that aren't audio answer 400 with 40093008 "音频转换失败". Its
  documentation names silk, mp3 and wav, and in one table silk alone. See
  [Sending voice messages](media.md#sending-voice-messages).
- **Files** (`file_type = 4`, tested): the upload needs `file_name`, which
  the group shows on a downloadable file. A group whose group files are full
  answers 50015014 "系统繁忙"; only `upload_prepare` gives the reason,
  40093003 "群文件超过上限".
- **Size**: a direct base64 upload of 6 MiB works and 8 MiB answers 850012,
  so past 5 MiB the sender uploads in parts, pictures and files alike:
  `upload_prepare` with `file_type`, `file_name`, `file_size`, `md5`, `sha1`
  and `md5_10m` (the MD5 of the first 10,002,432 bytes; 850012 if a digest is
  missing) returns an `upload_id`, a `block_size` and each part's `index`
  (from 1), presigned URL and `block_size`, all strings. Each part is PUT to
  its URL and reported with `upload_part_finish` (`upload_id`,
  `part_index`, `block_size`, the part's MD5); then `upload_id`,
  `file_type` and `file_name` go to `files`, which returns the `file_info`.
  Files go in 10 MiB parts, a picture as one. Uploading the same file again
  goes through the whole process again.
- **Moderation**: content QQ rejects (40034006) is a failed delivery. A
  banned bot "暂不支持解封".

## Group management

All paths under `/v2/groups/{group_openid}/`.

- **Without being an administrator** (tested): `info` (name, introduction
  `group_finger_memo`, category `group_class_text`, `group_tags`, member
  count `group_member_num`) and `bot_state` (maxx's `member_openid` here,
  when it joined, its role, whether proactive messages are on, whether it
  gets every message or only @s), 30 calls a minute each; the documentation
  says both are allowlist-only, yet both answer. A group takes its title from
  `info` (`qqbot`'s `Client::info`).
- **As an administrator**: muting, `POST restrict_chat_setting` with
  `members: [{op, member_openid, mute_expire_at}]`: `op` is add, update or
  del; the expiry is RFC3339, at most 30 days ahead; at most 20 people a
  call; add and update work only on ordinary members, and del with an empty
  expiry lifts a mute at once. `GET restrict_chat_setting` returns the
  group-wide rules and who is muted. Also the join requests
  (`join_request_list`, `approval_join_request/{member_openid}`, the event
  `GROUP_JOIN_REQUEST`) and `<qqbot-at-everyone />`, once per group a day.
  Without the role these answer 11703 "机器人不是群管理员" (err_code 40011030).
  Tested as an administrator on an ordinary member: an add 60 seconds ahead
  in `+08:00` answers 200 and `{}`, a `GET` shows the person (expiring a
  second earlier than given), a del with an empty string answers 200 and
  `{}`, and an add with an empty expiry answers 40103009; a del on someone
  not muted answers 200. Not tested: update, add on someone muted, the
  owner or an administrator, more than 30 days.
- **Allowlist-only** ("内邀接入中"): the member list `members`, a member
  `members/{member_openid}`, `batch_remove_members` and `member_blacklist`.
  They answer 11253 "应用无接口访问权限" (err_code 40012010), so Max can't
  learn the openids of people who haven't spoken.
- **Events**: `GROUP_MEMBER_ADD` and `GROUP_MEMBER_REMOVE` (intent
  `GROUP_MEMBER_EVENT`, `1<<24`), carrying only `member_openid`.
- **Not available**: reactions, nudges, edits, group cards, sending
  emoticons, and any event for someone else's retraction, so others'
  retractions don't show on the timeline.

## Max's tools for the group

What `recall_message` and `mute_member` check of their own, and how they
reach the adapter, is in [Group management](platforms.md#group-management).
QQ's adapter adds QQ's rules, which its notes tell the model:

- **Recalling**: only within 2 minutes of a message's time, and not the
  group owner's or administrators' messages (by the role their message
  carries). Whether Max is an administrator isn't asked: others' messages
  are tried, and QQ's refusal comes back in words. Success records sent,
  refusal failed, which projects as `[unsend#id]（没发出去）`.
- **Muting**: not the group owner or administrators (by their latest
  message's role), and at most 30 days ahead. Lifting is a del; otherwise
  a `GET` first tells whether to update or add, with the expiry in
  `+08:00`. Whether Max is an administrator isn't asked; QQ's refusal
  (40011030) is passed back. Muting twice does no harm, so a mute that may
  have failed is simply done again.
