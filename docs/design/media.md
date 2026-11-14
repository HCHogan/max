# Media

Pictures, stickers, videos, voice messages and files: how they are
stored, described, shown to the model, sent and read back. The Haskell
version's lessons are noted with the commits that taught them.

## Storing

- **Nodes and handles**: inbound, a QQ attachment's download URL is written
  into its node, `Media { media: Some(Remote(url)) }`. The ledger is
  append-only, so a download's result is recorded in `message_media`
  (message, index, sha256). The index is the item's position in the
  message, from 0, and the model's handle is `image#<message id>.<index>`,
  likewise `video#`, `audio#` and `file#`. (In the Haskell version
  `[image#id]` once named the message, which could hold 20 items.)
- **The content store**: `<media dir>/objects/<first two of sha256>/<sha256>`,
  read-only, written to a temporary file and renamed; an existing object
  isn't written again. The Haskell version's layout, so its files moved
  across as they were. No GC.
- **Download** (`media/download.rs`): a derived-data worker (see
  [The three roles](../architecture.md#the-three-roles)), fed by ledger
  notifications, 4 at a time, each within the HTTP client's 10-second
  connect and 60-second overall timeouts; an item over `KEPT_FILE_BYTES`
  (64 MiB) keeps only its metadata. Retries after 1 and 4 seconds, then a
  log line and no failure table. Its scans look back only an hour, since QQ
  URLs expire (the Haskell version retried hundreds of dead links on every
  restart, 9f27fa7). Everything is downloaded, files included, for
  [Reading files](#reading-files). What its first 16 bytes show to be a
  picture (PNG, JPEG, GIF, WebP) is read whole, to get its dimensions and
  make the model's version; anything else is hashed and written to a
  temporary file as it arrives, so a video of tens of MiB is never held in
  memory.
- **The model's version** is made once, at download, and its sha256
  recorded in `media`: a picture over 1568 pixels on its long edge or over
  1 MiB becomes a JPEG 1568 on its long edge, a GIF its first frame, and
  others stay as they are (`media/prepare.rs`). The Haskell version first
  sent multi-MB originals as base64 (0a2addb).

## Captions

`[llm] caption` picks the model, which must see pictures; without one,
nothing is captioned. Captions are in `media_captions`, since `media` is the
download worker's (`media/caption.rs`).

- The download worker hands over each picture it stored with a model's
  version; the startup scan fills in pictures first seen in the last 14 days
  without a caption. One caption per sha256, so a sticker sent again isn't
  captioned again (975eb59).
- 2 minutes a call, 2 at a time, usage recorded as `caption`. A caption is
  one or two sentences in Chinese; for a screenshot it says what it shows
  and quotes the key text; at most 300 characters are stored. After a
  second failure an empty caption is written and the picture isn't tried
  again.
- Stickers get their own prompt: what the sticker is and when it fits, such
  as "翻白眼的猫，表示无语". Anything that doesn't look like a sticker (a
  private photo, a screenshot) is judged SKIP and stays out of the sticker
  library. Each sha256 is captioned once, with the prompt of the kind it
  was first seen as.
- Videos and files get no caption; voice messages use Tencent's
  transcription.

## What the model sees

- **The tail is text**: `[image#123.0: caption]`, or `[image#123.0]` before
  the caption arrives. Pictures in the history aren't sent as pictures,
  since they compete for attention (0ec5752). A caption arriving changes
  its line, and that one cache miss is accepted (see
  [Rules for a stable prefix](context.md#rules-for-a-stable-prefix)).
- **Attached pictures**: pictures and stickers in the first inputs and in
  the messages they quote go into the volatile block as real images, those
  in follow-up input into its `[新消息]` block. Each follows its message's
  line, after its handle; one whose line isn't found goes at the end of the
  block. A picture a trigger quotes is attached even when its message is in
  the tail, at the end of the volatile block; likewise a row fed to a
  running core that quotes a message from before the core started brings
  that message's pictures after its block (so "这是什么" about a picture
  from a few minutes ago sees the picture, not only its caption). Every
  picture seen in a turn is kept, with no cap: the request grows only at
  the end, so its front keeps hitting the cache, and the next turn's tail
  has them as captions. Each is estimated at 1,200 tokens until the
  provider's usage says otherwise.
- **Every model Max uses must see pictures**: there is no text-only
  fallback. Intent reads only text and isn't affected.
- **In the request**, entries store references (principle 7): a `User`
  entry's `images` names which item of which message, not a sha256, since a
  message is shown as soon as it is entered, usually before its picture has
  downloaded. Before each model call `max` looks up `message_media` and
  `media` for the model's version, reads it from the content store and
  hands it to `max-llm`, which encodes it as a base64 data URL straight into
  the request body, keeping no other copy: `input_image` for Responses,
  `image_url` for Chat, each after a text part with its handle. A picture
  entered less than 10 seconds ago and still downloading is waited for,
  within the model call's task; older ones, and those that can't be
  downloaded or read, are left out with a warning, their handle staying in
  the text. QQ's URLs are never passed on: they expire, and the provider may
  not reach them.
- To look at a picture from the records, a program copies it out with
  `tools.file` and shows it with `tools.show`; see
  [Multimodal results](tools.md#multimodal-results).

## Sending images

Every picture Max sends takes the outbound path (see
[Outbound](ledger.md#outbound)): entered as a message of Max's whose node is
media in the content store (`Blob(sha256)`), with its `message_media`, then
handed to the sender. So Max's pictures have handles on the timeline too,
and can be quoted and sent again like anyone's. How QQ uploads and sends
them is in [The official QQ bot](qq.md#outbound).

- **Handles in replies**: a `[sticker#123.0]` or `[image#123.0]` the model
  writes sends that picture. This is how stickers are mostly sent: a sticker
  is part of what is said, its place has to line up with the text, and it
  saves a tool call. The segmenter cuts the handle into a message of its
  own, the text before and after becoming messages of their own in order,
  and drops a `: description` copied from the display form. Entering it,
  the actor looks the handle up in `message_media`, as it checks
  `[reply#id]` (see [Resolution and sending](identity.md#resolution-and-sending)):
  this conversation's pictures and stickers can all be sent, other
  conversations' stickers only, since pictures don't leave their
  conversation; the kind is the node's in that message. A handle not found,
  not downloaded or not allowed is dropped, with a warning.
- **`send_image({ path, caption? })`** sends a picture made or fetched in
  the VM: a chart, a screenshot, a download. It is read on the host from
  the group's `/work` without following symlinks (see
  [Reading files](#reading-files)), PNG, JPEG or GIF by their header, WebP
  turned into PNG, at most 10 MiB (`PICTURE_BYTES`). It is stored, written
  to `media`, entered with a `Post`, and once the sender reports back, its
  handle is returned. `caption` is text under the picture, in the same
  message.
- **`find_stickers({ query, limit? })`** searches the sticker library by
  meaning and sends nothing: `{ stickers: { handle, description }[] }`,
  `limit` 1 to 10, 5 by default; the model picks one and writes its handle.
  The library is every sticker seen in any conversation (node kind sticker),
  by sha256, its handle the latest message where it appeared as a sticker.
  Stickers captioned SKIP or empty are left out, as are those captioned with
  the picture prompt (first seen as a picture).
  - The embedding model is bge-m3 (1024 dimensions), served by Ollama on
    h610. `[embedding]` has `base_url` (OpenAI-compatible, ending in
    `/v1`), `model` and an optional `api_key_file`; without it there is no
    embedding worker and `find_stickers` answers `unavailable`. The
    dimension is the table's, not an option: a vector of another length is
    an error.
  - The vectors are in `caption_embeddings`, one per file with its model,
    and searches compare the current model's only.
  - **The embedding worker** (`media/stickers.rs`) gets each sticker
    caption the caption worker writes (not SKIP, not empty), and at startup
    and hourly sweeps for captions without a vector from the current model,
    so a change of model recomputes everything. A file is a unit, 2 at a
    time, 30 seconds a request, retried after 10 and 60 seconds, then left
    for the next sweep. Its usage isn't recorded.
  - A query becomes a vector and the nearest stickers by cosine distance
    come back; a failure answers `unavailable`, without retry. There is no
    distance threshold: relevant and irrelevant results overlap (relevant
    ones mostly at 0.31 to 0.45, while the nearest for "今天天气怎么样" was at
    0.44), so the model chooses by reading the descriptions.
- **The sender** uploads for a `file_info` (base64 up to 5 MiB, in parts
  past it) and sends `msg_type = 7`; only `send_image` carries `content`.
  `file_info` is cached in memory by (endpoint, sha256, file name) until an
  hour before it expires, so a sticker sent again within a day isn't
  uploaded again; a restart loses the cache. `qqbot` reads the file from the
  content store as it uploads: digests a MiB at a time, then each part as it
  is put, so a file of hundreds of MiB is never held whole. A chat has one
  queue, so what Max says after a big file waits for it; other groups don't.
  A failed upload is a failed delivery. Each picture counts as one proactive
  message against the group's quota.
- **The prompt**: stickers are occasional, at most one an answer; when
  nothing fitting is in the records, `find_stickers` finds one.

## Sending files

- **`send_file({ path, name? })`** sends a file from the VM: a document, a
  spreadsheet, a PDF, an archive. Read like `send_image`'s, from `/work`
  without following symlinks; empty files aren't sent; at most
  `SENT_FILE_BYTES` (200 MiB), copied into the content store a MiB at a time.
  An upload of that size takes a minute or two, longer than a call's 60
  seconds, so the tool doesn't wait for QQ: the file is entered with a
  `Post` of `Act::Queue` as a message of Max's whose node is named file media
  (`DraftNode::File`), `file#id.0` is returned as soon as it is entered, and
  the sender uploads it in its turn; if it doesn't go out, the records mark
  it `（没发出去）` like any message. `name` is the name shown in the group,
  the path's by default, trimmed, without `/`, `\` or control characters, at
  most 100 characters.
- The sender uploads it by name as `file_type = 4`, with no `content`.
- A file in the records can't be sent again by writing its handle, since
  the segmenter knows only picture and sticker handles: Max copies it into
  `/work` with `file` and sends it with `send_file`.
- Files go to private chats too.

## Reading files

Programs copy media from the records into `/work` on demand; nothing of
the content store is mounted in the VM (a writable hard-linked view would
let the guest, root on virtiofs as `maxx`, chmod and rewrite the store's own
inodes).

- **`file({ handle })`** (`service/chat_file.rs`; `tools.file` in a
  program, `maxx file` in a command): the host looks up the handle in
  `message_media`. It takes `file#123.0`, the display form
  `[file#123.0: name]`, and handles of pictures, stickers, videos and voice
  messages. Only this conversation's media that has been downloaded (up to
  64 MiB) is accepted; it is copied to `/work/chat/` and
  `{ path, name, size }` returned.
  - A file with a name is `<message id>.<index>-<name>`, the name (chosen by
    a group member) with `/`, `\` and control characters replaced by `_` and
    cut to 150 bytes.
  - Others are `<message id>.<index>.<extension>`, the extension from the
    MIME type (`image/jpeg` gives `jpg`, short subtypes are used as they
    are, otherwise none).
- **All host access to `/work` goes through one place**, `max::service::work`:
  it reads, writes and makes directories one path component at a time,
  following a link at no component, so a link the guest places can't send
  the host outside `/work`. It writes a temporary file and renames it into
  place; a `chat` that is a link, or a target that is a directory, is
  `bad_path`; a link at the target is itself replaced. The full output of
  `run_code` and `shell` (`.max/out`), the memory file and the dreamer go
  through it too, and full output is written only to new files: if anything
  already has that name, a link included, nothing is written.
- No cleanup: `/work/chat` holds ordinary files, which programs delete
  themselves.
