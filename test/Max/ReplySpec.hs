module Max.ReplySpec (spec) where

import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Max.Reply
  ( Chunk (..),
    ReplyPiece (..),
    chunkSource,
    dedupeImagePieces,
    latexToUnicode,
    parseReplyTokens,
    planReply,
    readyPrefix,
    stripHallucinatedTokens,
  )
import Test.Hspec

-- | Most tests only care about the split, not the Text/Table tag.
planTexts :: Text -> [Text]
planTexts = map chunkSource . planReply

spec :: Spec
spec = do
  describe "planReply / blank-line + [split] split" $ do
    it "keeps a reply without boundaries as one message" $
      planTexts "就一句话" `shouldBe` ["就一句话"]

    it "splits on blank lines" $
      planTexts "第一段\n\n第二段\n还是第二段\n\n第三段"
        `shouldBe` ["第一段", "第二段\n还是第二段", "第三段"]

    it "treats whitespace-only lines as blank and collapses runs" $ do
      planTexts "a\n   \nb" `shouldBe` ["a", "b"]
      planTexts "a\n\n\n\nb" `shouldBe` ["a", "b"]

    it "does not split on blank lines inside code fences" $
      planTexts "看这段:\n\n```python\nx = 1\n\ny = 2\n```\n\n就这样"
        `shouldBe` ["看这段:", "```python\nx = 1\n\ny = 2\n```", "就这样"]

    it "splits on [split] on its own line" $
      planTexts "第一条\n[split]\n第二条\n还是第二条\n[split]\n第三条"
        `shouldBe` ["第一条", "第二条\n还是第二条", "第三条"]

    it "splits on an inline [split]" $
      planTexts "先说这个 [split] 再说那个"
        `shouldBe` ["先说这个", "再说那个"]

    -- The production leak shape: a narration ending in a marker went
    -- out with "\n\n[split]" as literal text, because the narration
    -- sender skipped planReply entirely.  The planner itself must eat
    -- a trailing marker without producing an empty chunk.
    it "drops a trailing [split] with nothing after it" $
      planTexts "手写完你们等到明年。\n\n[split]"
        `shouldBe` ["手写完你们等到明年。"]

  -- A reply becomes one QQ message per chunk, paced ~2s apart, so an
  -- unbounded split is also an unbounded amount of time spent talking
  -- over the group.  Production once turned one generation into 26
  -- messages across 54 seconds.
  describe "planReply / chunk ceiling" $ do
    let paras k = T.intercalate "\n\n" ["第" <> T.pack (show i) <> "段" | i <- [1 .. k :: Int]]

    it "leaves a reply at the ceiling untouched" $
      length (planTexts (paras 10)) `shouldBe` 10

    it "caps a runaway split" $
      length (planTexts (paras 26)) `shouldBe` 10

    it "merges the overflow into the last message instead of dropping it" $ do
      let out = planTexts (paras 13)
      length out `shouldBe` 10
      take 3 out `shouldBe` ["第1段", "第2段", "第3段"]
      last out `shouldBe` "第10段\n\n第11段\n\n第12段\n\n第13段"

    it "keeps every word — nothing is truncated away" $ do
      let out = planTexts (paras 30)
      T.concat out `shouldSatisfy` \t ->
        all (\i -> ("第" <> T.pack (show i) <> "段") `T.isInfixOf` t) [1 .. 30 :: Int]

    -- The ceiling bounds outbound messages; it is not a formatting
    -- rule.  A model spraying [split] costs the group exactly what one
    -- spraying blank lines costs, so it is capped the same way.
    it "caps explicit [split] markers too" $ do
      let ps = [T.pack ("p" <> show i) | i <- [1 .. 26 :: Int]]
      length (planTexts (T.intercalate " [split] " ps)) `shouldBe` 10

    it "does not split inside code fences" $
      planTexts "看这段:\n[split]\n```python\nx = 1\n[split]\ny = 2\n```\n[split]\n就这样"
        `shouldBe` ["看这段:", "```python\nx = 1\n[split]\ny = 2\n```", "就这样"]

    it "honours explicit [split] markers up to the ceiling" $ do
      let ps = [T.pack ("p" <> show i) | i <- [1 .. 8 :: Int]]
      planTexts (T.intercalate " [split] " ps) `shouldBe` ps

    it "drops empty chunks from leading/trailing/doubled markers" $
      planTexts "[split]hello[split][split]world[split]"
        `shouldBe` ["hello", "world"]

    it "strips surrounding whitespace per chunk" $
      planTexts "  a  [split]\n\n b \n\n" `shouldBe` ["a", "b"]

    it "plans nothing out of nothing" $ do
      planTexts "" `shouldBe` []
      planTexts "  \n\n " `shouldBe` []

    -- The v0.9.1 leak, one layer down.  Streaming releases up to the
    -- last blank line, so "…\n\n[split]" hands the final send exactly
    -- "[split]" — and the planner's old empty-plan fallback handed that
    -- body straight back as a chunk, which went out as a message
    -- reading "[split]" and nothing else (production, 7 of them).
    it "plans a body of nothing but markers to nothing" $ do
      planTexts "[split]" `shouldBe` []
      planTexts "\n\n[split]" `shouldBe` []
      planTexts "[split][split]" `shouldBe` []

    -- What streaming actually hands the two senders, in order.
    it "drops the marker whichever side of the stream boundary it lands on" $ do
      let (safe, held) = readyPrefix "手写完你们等到明年。\n\n[split]"
      planTexts safe `shouldBe` ["手写完你们等到明年。"]
      planTexts held `shouldBe` []

  describe "planReply / table carving" $ do
    it "carves a GFM table into its own TableChunk" $
      planReply "对比如下\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n完事"
        `shouldBe` [ TextChunk "对比如下",
                     TableChunk "| a | b |\n|---|---|\n| 1 | 2 |",
                     TextChunk "完事"
                   ]

    it "carves a table even without surrounding blank lines" $
      planReply "对比如下\n| a | b |\n| --- | :-: |\n| 1 | 2 |\n完事"
        `shouldBe` [ TextChunk "对比如下",
                     TableChunk "| a | b |\n| --- | :-: |\n| 1 | 2 |",
                     TextChunk "完事"
                   ]

    it "a lone pipe line without a separator row stays text" $
      planReply "| not a table |"
        `shouldBe` [TextChunk "| not a table |"]

    it "table syntax inside a code fence stays code" $
      planReply "```\n| a | b |\n|---|---|\n```"
        `shouldBe` [TextChunk "```\n| a | b |\n|---|---|\n```"]

    it "reply that is only a table yields just the TableChunk" $
      planReply "| a |\n|---|\n| 1 |"
        `shouldBe` [TableChunk "| a |\n|---|\n| 1 |"]

  describe "parseReplyTokens" $ do
    it "hoists a leading [↩#id] and strips it from the text" $
      parseReplyTokens "[↩#8472] 说得对"
        `shouldBe` (Just 8472, [PieceText " 说得对"])

    it "still accepts a pre-ADR-004 negative handle rather than leaking it" $ do
      -- Canonical ids are positive.  A model echoing a line the reproject
      -- has not rewritten yet must not put the raw token in the group; it
      -- simply resolves to nothing.
      parseReplyTokens "[↩#-1000000000790] 说得对"
        `shouldBe` (Just (-1000000000790), [PieceText " 说得对"])
      parseReplyTokens "看这张 [image#-1000000000790]"
        `shouldBe` (Nothing, [PieceText "看这张 ", PieceImage (-1000000000790) Nothing])

    it "keeps QQ-native ids positive-only" $ do
      parseReplyTokens "[face#-66]" `shouldBe` (Nothing, [PieceText "[face#-66]"])
      parseReplyTokens "[sticker#-42]" `shouldBe` (Nothing, [PieceText "[sticker#-42]"])

    it "returns no reply and one text piece for plain text" $
      parseReplyTokens "就一句话" `shouldBe` (Nothing, [PieceText "就一句话"])

    it "splits an inline [sticker#id] out of the surrounding text" $
      parseReplyTokens "哈哈 [sticker#42] 绝了"
        `shouldBe` (Nothing, [PieceText "哈哈 ", PieceSticker 42, PieceText " 绝了"])

    it "accepts the captioned [sticker#id: …] form and ignores the caption" $
      parseReplyTokens "[sticker#42: 猫猫震惊]"
        `shouldBe` (Nothing, [PieceSticker 42])

    it "accepts the pre-rename [表情包#id] forms (old rows echo them)" $ do
      parseReplyTokens "哈哈 [表情包#42] 绝了"
        `shouldBe` (Nothing, [PieceText "哈哈 ", PieceSticker 42, PieceText " 绝了"])
      parseReplyTokens "[表情包#42: 猫猫震惊]"
        `shouldBe` (Nothing, [PieceSticker 42])

    it "splits an inline [image#id] resend token out of the text" $
      parseReplyTokens "看这张 [image#123] 笑死"
        `shouldBe` (Nothing, [PieceText "看这张 ", PieceImage 123 Nothing, PieceText " 笑死"])

    it "reads the seg_index half of a media handle" $ do
      parseReplyTokens "看这张 [image#123.2] 笑死"
        `shouldBe` (Nothing, [PieceText "看这张 ", PieceImage 123 (Just 2), PieceText " 笑死"])
      parseReplyTokens "[image#123.0: 示波器截图]"
        `shouldBe` (Nothing, [PieceImage 123 (Just 0)])

    it "does not read a trailing dot with no index as a segment" $
      parseReplyTokens "看 [image#123.] 这个"
        `shouldBe` (Nothing, [PieceText "看 [image#123.] 这个"])

    it "does not treat a bare [image] as a resend token" $
      parseReplyTokens "这是 [image] 标记"
        `shouldBe` (Nothing, [PieceText "这是 [image] 标记"])

    it "keeps the first reply id when several appear" $
      parseReplyTokens "[↩#1] a [↩#2] b"
        `shouldBe` (Just 1, [PieceText " a  b"])

    it "combines a quote and a sticker in one chunk" $
      parseReplyTokens "[↩#9] 看这个 [sticker#3]"
        `shouldBe` (Just 9, [PieceText " 看这个 ", PieceSticker 3])

    it "splits an inline [face#id] token out of the text" $
      parseReplyTokens "无语 [face#178]"
        `shouldBe` (Nothing, [PieceText "无语 ", PieceFace 178])

    it "accepts the named [face#id: 名字] form and ignores the name" $
      parseReplyTokens "[face#14: 惊讶]"
        `shouldBe` (Nothing, [PieceFace 14])

    it "does not treat a bare [face] as a send token" $
      parseReplyTokens "这是 [face] 标记"
        `shouldBe` (Nothing, [PieceText "这是 [face] 标记"])

    it "consumes a trailing attribute group when echoing a decorated token" $ do
      parseReplyTokens "[image#7405: 示波器截图](1.2MB) 笑死"
        `shouldBe` (Nothing, [PieceImage 7405 Nothing, PieceText " 笑死"])
      parseReplyTokens "[sticker#42: 柴犬瘫地](旧图)"
        `shouldBe` (Nothing, [PieceSticker 42])
      parseReplyTokens "[↩#9: 引文](x) 对"
        `shouldBe` (Just 9, [PieceText " 对"])

    it "does not eat an unrelated paren after a bare token" $
      parseReplyTokens "[sticker#42]（笑）"
        `shouldBe` (Nothing, [PieceSticker 42, PieceText "（笑）"])

    -- The model sometimes copies the caption instead of the number
    -- out of the display form ([sticker#42: 柴犬瘫地] → [sticker#柴犬
    -- 瘫地]); that must read as a caption reference for the send layer
    -- to resolve, never go out as literal text.
    it "accepts a caption in the sticker id slot" $ do
      parseReplyTokens "[sticker#柴犬瘫地]"
        `shouldBe` (Nothing, [PieceStickerDesc "柴犬瘫地"])
      parseReplyTokens "哈哈 [表情包#猫猫震惊] 绝了"
        `shouldBe` (Nothing, [PieceText "哈哈 ", PieceStickerDesc "猫猫震惊", PieceText " 绝了"])
      -- digits keep their fast path; captions are the fallback read
      parseReplyTokens "[sticker#42]" `shouldBe` (Nothing, [PieceSticker 42])

    it "keeps an overlong or nested caption slot literal" $ do
      let long = T.replicate 61 "喵"
      parseReplyTokens ("[sticker#" <> long <> "]")
        `shouldBe` (Nothing, [PieceText ("[sticker#" <> long <> "]")])
      parseReplyTokens "[sticker#[嵌套]]"
        `shouldBe` (Nothing, [PieceText "[sticker#[嵌套]]"])

    it "leaves a malformed token as literal text" $ do
      parseReplyTokens "[sticker#]" `shouldBe` (Nothing, [PieceText "[sticker#]"])
      parseReplyTokens "[↩#abc]" `shouldBe` (Nothing, [PieceText "[↩#abc]"])
      parseReplyTokens "[image#]" `shouldBe` (Nothing, [PieceText "[image#]"])
      parseReplyTokens "[face#]" `shouldBe` (Nothing, [PieceText "[face#]"])

  describe "stripHallucinatedTokens" $ do
    it "drops a tool-call-looking bracket span" $
      stripHallucinatedTokens "无语 [find_stickers query=\"钓鱼\"] 真是"
        `shouldBe` "无语  真是"

    it "keeps grammar tokens and plain bracketed prose" $ do
      stripHallucinatedTokens "[↩#9] 看 [sticker#42]" `shouldBe` "[↩#9] 看 [sticker#42]"
      stripHallucinatedTokens "这是 [重点] 内容" `shouldBe` "这是 [重点] 内容"

    it "leaves code fences untouched" $
      stripHallucinatedTokens "```\nx = a[i * n]  -- [q = \"hi\"]\n```"
        `shouldBe` "```\nx = a[i * n]  -- [q = \"hi\"]\n```"

  describe "dedupeImagePieces" $ do
    it "keeps the first [image#id] and drops later duplicates" $
      dedupeImagePieces Set.empty [PieceImage 7 Nothing, PieceText " x ", PieceImage 7 Nothing]
        `shouldBe` (Set.fromList [(7, Nothing)], [PieceImage 7 Nothing, PieceText " x "])

    it "keeps distinct ids" $
      dedupeImagePieces Set.empty [PieceImage 7 Nothing, PieceImage 8 Nothing]
        `shouldBe` (Set.fromList [(7, Nothing), (8, Nothing)], [PieceImage 7 Nothing, PieceImage 8 Nothing])

    it "keeps distinct pictures of one message" $
      dedupeImagePieces Set.empty [PieceImage 7 (Just 0), PieceImage 7 (Just 1)]
        `shouldBe` ( Set.fromList [(7, Just 0), (7, Just 1)],
                     [PieceImage 7 (Just 0), PieceImage 7 (Just 1)]
                   )

    it "treats a whole-message resend as subsuming its individual pictures" $
      -- [image#7] already sent every picture on message 7; naming one of
      -- them afterwards would send it twice.
      dedupeImagePieces Set.empty [PieceImage 7 Nothing, PieceImage 7 (Just 1)]
        `shouldBe` (Set.fromList [(7, Nothing)], [PieceImage 7 Nothing])

    it "drops ids already sent by an earlier chunk" $
      dedupeImagePieces (Set.fromList [(7, Nothing)]) [PieceImage 7 Nothing, PieceText "好"]
        `shouldBe` (Set.fromList [(7, Nothing)], [PieceText "好"])

    it "leaves stickers and faces alone" $
      dedupeImagePieces Set.empty [PieceSticker 3, PieceFace 178, PieceSticker 3]
        `shouldBe` (Set.empty, [PieceSticker 3, PieceFace 178, PieceSticker 3])

  describe "latexToUnicode" $ do
    it "converts inline \\(..\\) math" $
      latexToUnicode "光速 \\(c \\approx 3 \\times 10^{8}\\) m/s"
        `shouldBe` "光速 c ≈ 3 × 10⁸ m/s"

    it "converts display \\[..\\] math" $
      latexToUnicode "\\[E = mc^2\\]" `shouldBe` "E = mc²"

    it "converts $$..$$ math" $
      latexToUnicode "$$\\sum_{i} x_i$$" `shouldBe` "Σᵢ xᵢ"

    it "converts single-dollar math that smells like TeX" $
      latexToUnicode "$\\alpha + \\beta$" `shouldBe` "α + β"

    it "leaves dollar amounts alone" $
      latexToUnicode "$5 and $10" `shouldBe` "$5 and $10"

    it "leaves plain $..$ without TeX hints alone" $
      latexToUnicode "$abc$" `shouldBe` "$abc$"

    it "renders \\frac with parens only when needed" $ do
      latexToUnicode "\\(\\frac{a}{b}\\)" `shouldBe` "a/b"
      latexToUnicode "\\(\\frac{a+1}{b}\\)" `shouldBe` "(a+1)/b"

    it "renders \\sqrt" $
      latexToUnicode "\\(\\sqrt{x+1}\\)" `shouldBe` "√(x+1)"

    it "maps subscripts and falls back when unmappable" $ do
      latexToUnicode "\\(x_{12}\\)" `shouldBe` "x₁₂"
      latexToUnicode "\\(x_{yz}\\)" `shouldBe` "x_(yz)"

    it "handles \\left \\right and \\text" $
      latexToUnicode "\\(\\left( \\text{速度} \\right)\\)"
        `shouldBe` "( 速度 )"

    it "greek + relations end-to-end" $
      latexToUnicode "\\(\\Delta v \\geq \\frac{\\pi}{2} \\cdot \\omega\\)"
        `shouldBe` "Δ v ≥ π/2 · ω"

    it "does not touch inline code spans" $
      latexToUnicode "用 `$HOME` 变量和 `\\(x\\)` 字面量"
        `shouldBe` "用 `$HOME` 变量和 `\\(x\\)` 字面量"

    it "does not touch code fences" $
      latexToUnicode "```\n\\alpha $x^2$\n```"
        `shouldBe` "```\n\\alpha $x^2$\n```"

    it "leaves unbalanced delimiters untouched" $
      latexToUnicode "half open \\(x + y" `shouldBe` "half open \\(x + y"

    it "unknown commands lose only the backslash" $
      latexToUnicode "\\(\\weird{x}\\)" `shouldBe` "weirdx"

  -- Streaming sends a paragraph as soon as it can't change any more.
  -- Every case here is really the same question: could a later byte
  -- alter where this splits?  If yes, hold — a sent fragment can't be
  -- recalled.
  describe "readyPrefix" $ do
    let roundTrips t = let (a, b) = readyPrefix t in a <> b `shouldBe` t

    it "reassembles exactly, whatever it decides" $
      mapM_
        roundTrips
        [ "",
          "一段",
          "一段\n\n二段",
          "一段\n\n二段\n\n",
          "```\ncode\n\nmore\n```\n\n尾巴"
        ]

    -- The common case, and the reason single-paragraph replies get no
    -- benefit from streaming at all: nothing is safe until a second
    -- paragraph starts.
    it "holds a lone paragraph" $
      readyPrefix "还在写这一段" `shouldBe` ("", "还在写这一段")

    it "releases every paragraph but the last" $
      readyPrefix "第一段\n\n第二段\n\n第三段还没写完"
        `shouldBe` ("第一段\n\n第二段\n\n", "第三段还没写完")

    -- [silence] is a whole reply, never more than one paragraph — so
    -- the rule above is also what stops it being sent as text.
    it "never releases a bare [silence]" $ do
      readyPrefix "[silence]" `shouldBe` ("", "[silence]")
      readyPrefix "[silence:吃瓜]" `shouldBe` ("", "[silence:吃瓜]")

    -- A blank line inside a fence is not a chunk boundary, and while
    -- the fence is open we cannot know the line we are looking at is
    -- outside it.
    it "holds everything while a code fence is open" $
      readyPrefix "看这个\n\n```haskell\nfoo = 1\n\nbar = 2"
        `shouldBe` ("", "看这个\n\n```haskell\nfoo = 1\n\nbar = 2")

    it "releases again once the fence closes" $ do
      let (safe, held) = readyPrefix "```\nfoo\n\nbar\n```\n\n然后呢"
      safe `shouldBe` "```\nfoo\n\nbar\n```\n\n"
      held `shouldBe` "然后呢"

    -- A table ends at the blank line after it like any other block, so
    -- it needs no special case — but it must not go out half-written.
    it "holds a half-written table" $
      readyPrefix "对比：\n\n| a | b |\n| - | - |\n| 1 |"
        `shouldBe` ("对比：\n\n", "| a | b |\n| - | - |\n| 1 |")

    -- What is released must split the same way whether it is planned
    -- alone or as part of the finished reply; otherwise the streamed
    -- prefix and the final remainder disagree about chunk boundaries.
    it "splits the same as planReply does on the whole text" $ do
      let whole = "第一段\n\n第二段\n\n第三段"
          (safe, held) = readyPrefix whole
      map chunkSource (planReply safe <> planReply held)
        `shouldBe` map chunkSource (planReply whole)
