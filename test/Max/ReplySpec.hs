module Max.ReplySpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Max.Reply
  ( Chunk (..),
    ReplyPiece (..),
    chunkSource,
    latexToUnicode,
    maxReplyChunks,
    parseReplyTokens,
    planReply,
  )
import Test.Hspec

-- | Most tests only care about the split, not the Text/Table tag.
planTexts :: Text -> [Text]
planTexts = map chunkSource . planReply

spec :: Spec
spec = do
  describe "planReply / paragraph split" $ do
    it "keeps a single paragraph as one message" $
      planTexts "就一句话" `shouldBe` ["就一句话"]

    it "splits on blank lines" $
      planTexts "第一段\n\n第二段\n还是第二段\n\n第三段"
        `shouldBe` ["第一段", "第二段\n还是第二段", "第三段"]

    it "treats whitespace-only lines as blank" $
      planTexts "a\n   \nb" `shouldBe` ["a", "b"]

    it "collapses runs of blank lines into one break" $
      planTexts "a\n\n\n\nb" `shouldBe` ["a", "b"]

    it "does not split inside code fences" $
      planTexts "看这段:\n\n```python\nx = 1\n\ny = 2\n```\n\n就这样"
        `shouldBe` ["看这段:", "```python\nx = 1\n\ny = 2\n```", "就这样"]

    it "caps chunk count, folding overflow into the last message" $ do
      let paras = [T.pack ("p" <> show i) | i <- [1 .. 9 :: Int]]
          out = planTexts (T.intercalate "\n\n" paras)
      length out `shouldBe` maxReplyChunks
      last out `shouldBe` T.intercalate "\n\n" (drop (maxReplyChunks - 1) paras)

    it "strips leading/trailing blank paragraphs" $
      planTexts "\n\nhello\n\n" `shouldBe` ["hello"]

    it "empty input yields one empty chunk (caller's concern)" $
      planTexts "" `shouldBe` [("" :: Text)]

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

    it "returns no reply and one text piece for plain text" $
      parseReplyTokens "就一句话" `shouldBe` (Nothing, [PieceText "就一句话"])

    it "splits an inline [表情包#id] out of the surrounding text" $
      parseReplyTokens "哈哈 [表情包#42] 绝了"
        `shouldBe` (Nothing, [PieceText "哈哈 ", PieceSticker 42, PieceText " 绝了"])

    it "accepts the captioned [表情包#id: …] form and ignores the caption" $
      parseReplyTokens "[表情包#42: 猫猫震惊]"
        `shouldBe` (Nothing, [PieceSticker 42])

    it "splits an inline [image#id] resend token out of the text" $
      parseReplyTokens "看这张 [image#123] 笑死"
        `shouldBe` (Nothing, [PieceText "看这张 ", PieceImage 123, PieceText " 笑死"])

    it "does not treat a bare [image] as a resend token" $
      parseReplyTokens "这是 [image] 标记"
        `shouldBe` (Nothing, [PieceText "这是 [image] 标记"])

    it "keeps the first reply id when several appear" $
      parseReplyTokens "[↩#1] a [↩#2] b"
        `shouldBe` (Just 1, [PieceText " a  b"])

    it "combines a quote and a sticker in one chunk" $
      parseReplyTokens "[↩#9] 看这个 [表情包#3]"
        `shouldBe` (Just 9, [PieceText " 看这个 ", PieceSticker 3])

    it "leaves a malformed token as literal text" $ do
      parseReplyTokens "[表情包#]" `shouldBe` (Nothing, [PieceText "[表情包#]"])
      parseReplyTokens "[↩#abc]" `shouldBe` (Nothing, [PieceText "[↩#abc]"])
      parseReplyTokens "[image#]" `shouldBe` (Nothing, [PieceText "[image#]"])

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
