# Features deliberately removed

What the Haskell version had and this one leaves out on purpose.

- **iMessage and the WeChat hook.** Only the platforms in use are kept.
- **NapCat and OneBot.** QQ uses the official bot API; see [The official QQ bot](../design/qq.md).
- **Reactions and nudges.** The official API does not offer them. This covers the emoji attached while processing and on failure, replying with an emoji through `[silence:表情名]` ("emoji name"), and receiving other people's reactions and nudges.
- **Rendering tables and code blocks as images** (typst, codesnap). QQ's native Markdown displays code blocks, tables and formulas.
- **Sending QQ face emoticons.** The official API cannot send them. Received ones are still shown to the model; see [How replies are written](../design/ledger.md#how-replies-are-written). Stickers and images are sent, as images; see [Sending images](../design/media.md#sending-images).
- **Matrix and mirroring.** Deferred; see [Matrix](matrix-deferred.md). Mirroring connected QQ groups with Matrix rooms, so it is shelved together with Matrix.
- **The historian, summaries, `/compact`, `/uncompact` and `/historian`.** See [Summaries](no-summaries.md).
- **Inbound message hooks.** Not implemented. If they are built later, they cannot run in the VM, because they would run on every message. The candidate is declarative rules: Rust's `regex` runs in linear time, so untrusted regular expressions pose no risk.

This list is not complete.
