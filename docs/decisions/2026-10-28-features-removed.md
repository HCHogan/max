# Features deliberately removed

## Features deliberately removed

- iMessage.
- The WeChat hook.
- NapCat and OneBot (removed 2026-10-28): QQ now uses the official bot API; see [The official QQ bot](../design/qq.md#the-official-qq-bot-1).
- Reactions and nudges (removed 2026-10-28): the official API does not offer them. This covers the emoji attached while processing and on failure, replying with an emoji through `[silence:表情名]` ("emoji name"), and receiving other people's reactions and nudges.
- Rendering tables and code blocks as images (typst, codesnap; removed 2026-10-29): QQ's native Markdown displays code blocks, tables and formulas.
- Max sending QQ face emoticons (removed 2026-10-29): the official API cannot send them. Received ones are still shown to the model; see [How replies are written](../design/ledger.md#how-replies-are-written). Stickers and images were removed on the same day, but the owner promptly restored them: they are sent as images; see [Sending images](../design/media.md#sending-images).
- Matrix and mirroring (decided 2026-10-29; deferred): see [Matrix](2026-10-29-matrix-deferred.md#matrix). Mirroring connected QQ groups with Matrix rooms, so it is shelved together with Matrix.
- `/uncompact` (removed 2026-10-28): summarisation is automatic, so a part restored by hand would sooner or later be compacted again; the semantics are awkward.
- The historian, summaries, `/compact` and `/historian` (removed 2026-10-30; restored that evening as a per-group switch; removed again 2026-11-02): see [Summaries](../design/context.md#summaries).
- Inbound message hooks: not implemented for now (2026-10-27). If they are built later, they cannot run in the VM, because they would run on every message. The candidate is declarative rules: Rust's `regex` runs in linear time, so untrusted regular expressions pose no risk.

The discussion on 2026-10-26 decided only to keep QQ and Matrix, the two platforms in use; on 2026-10-29 Matrix was deferred as well. The remaining removals are **to be completed**.
