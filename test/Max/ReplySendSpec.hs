-- | Streaming and final publication preserve paragraph, code and table boundaries.
module Max.ReplySendSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Max.Reply (Chunk (..), chunkSource, planReply, readyPrefix)
import Test.Hspec

-- | What the group ends up seeing, as plain text per message.
sources :: [Chunk] -> [Text]
sources = map chunkSource

-- | Send @body@ the way streaming would: release everything
-- 'readyPrefix' allows, then send the remainder.  One release is
-- enough to model the split — the boundary is what matters, not how
-- many times we stopped at one.
split :: Text -> ([Text], [Text])
split body =
  let (ready, _) = readyPrefix body
      remainder = T.drop (T.length ready) body
   in (sources (planReply ready), sources (planReply remainder))

spec :: Spec
spec = do
  describe "the streamed/remainder split" $ do
    it "keeps every paragraph beyond ten across the streamed/final boundary" $ do
      let paragraphs = ["段落 " <> T.pack (show i) | i <- [1 :: Int .. 26]]
          body = T.intercalate "\n\n" paragraphs
          (a, b) = split body
      (a <> b) `shouldBe` paragraphs
      (a <> b) `shouldBe` sources (planReply body)

    it "holds when the last paragraph is still growing" $ do
      let body = "结论在这。\n\n理由是这样的，还没写完"
          (a, b) = split body
      (a <> b) `shouldBe` sources (planReply body)
      -- and the unfinished paragraph is on the remainder side, unsent
      a `shouldBe` ["结论在这。"]

    it "holds a short one-paragraph reply until the end" $ do
      let body = "就一句话。"
          (ready, _) = readyPrefix body
      ready `shouldBe` ""
      sources (planReply body) `shouldBe` ["就一句话。"]

    -- The blank line inside an unterminated fence is not a paragraph
    -- boundary: releasing there would send an unclosed code block and
    -- strand its other half in the next message.
    it "holds everything while a code fence is still open" $ do
      let body = "看这段：\n\n```haskell\nfoo :: Int\n\n"
          (ready, _) = readyPrefix body
      ready `shouldBe` ""

    -- Once the fence closes it may go, and it goes whole — 'planReply'
    -- does not treat the blank line inside it as a break either.
    it "releases a closed fence as one message" $ do
      let body = "看这段：\n\n```haskell\nfoo :: Int\n\nbar = 1\n```\n\n就是这样"
          (a, b) = split body
      a `shouldBe` ["看这段：", "```haskell\nfoo :: Int\n\nbar = 1\n```"]
      (a <> b) `shouldBe` sources (planReply body)

    it "never cuts a table in half" $ do
      let body = "对比一下：\n\n| 档位 | 上升沿 |\n|---|---|\n| 1X | 圆 |\n| 10X | 陡 |\n\n所以用 10X"
          (a, b) = split body
      a `shouldBe` ["对比一下：", "| 档位 | 上升沿 |\n|---|---|\n| 1X | 圆 |\n| 10X | 陡 |"]
      (a <> b) `shouldBe` sources (planReply body)

    -- The rows are still arriving, so the table is the trailing
    -- paragraph and is held whole rather than rendered a row at a time.
    it "holds a table that is still growing" $ do
      let body = "对比一下：\n\n| 档位 | 上升沿 |\n|---|---|\n| 1X | 圆 |"
          (ready, _) = readyPrefix body
      ready `shouldBe` "对比一下：\n\n"

    -- Pipe rows inside a fence are code, not data: they must come out
    -- as text, never as a rendered PNG.
    it "treats pipe rows inside a fence as code, not a table" $ do
      let body = "像这样：\n\n```\n| a | b |\n|---|---|\n```\n\n就是这样"
          (a, b) = split body
      a `shouldBe` ["像这样：", "```\n| a | b |\n|---|---|\n```"]
      (a <> b) `shouldBe` sources (planReply body)

    -- An open fence blocks the paragraphs /before/ it too, because
    -- 'readyPrefix' only knows the last blank line and so releases all
    -- or nothing.  More conservative than it strictly needs to be —
    -- worth pinning, since the safe direction is the one that costs
    -- nothing but a little latency.
    it "holds earlier paragraphs too while a fence is open" $ do
      let body = "像这样：\n\n```\n| a | b |\n|---|---|\n\n| c | d |\n"
      fst (readyPrefix body) `shouldBe` ""

    it "keeps a quote token with the paragraph that wrote it" $ do
      let body = "[reply#7405] 上升沿圆角是探头没补偿\n\n另外你那个 1X 档也要换"
          (a, b) = split body
      take 1 a `shouldBe` ["[reply#7405] 上升沿圆角是探头没补偿"]
      (a <> b) `shouldBe` sources (planReply body)
