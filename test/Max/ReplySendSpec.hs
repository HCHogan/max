-- |
-- Streaming splits one reply across two senders, and the design rests
-- on a claim that is easy to state and easy to break: cutting the text
-- at a 'readyPrefix' boundary produces the same messages as never
-- cutting it at all.  These pin that claim, and the two per-reply
-- guarantees ('maxChunks', image dedupe) that stopped being free once
-- the reply could arrive in pieces.
module Max.ReplySendSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Max.Reply (Chunk (..), chunkSource, maxChunks, planReply, readyPrefix)
import Max.ReplySend (capTo)
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
    -- The load-bearing claim.  'readyPrefix' only ever cuts after a
    -- blank line, which is the same place 'planReply' breaks, so the
    -- two halves plan into the same chunks the whole would have.
    it "produces the same messages as sending the whole text at once" $ do
      let body = "第一段。\n\n第二段，长一点。\n\n第三段收尾。"
          (a, b) = split body
      (a <> b) `shouldBe` sources (planReply body)

    it "holds when the last paragraph is still growing" $ do
      let body = "结论在这。\n\n理由是这样的，还没写完"
          (a, b) = split body
      (a <> b) `shouldBe` sources (planReply body)
      -- and the unfinished paragraph is on the remainder side, unsent
      a `shouldBe` ["结论在这。"]

    -- A single paragraph releases nothing, so the split is a no-op.
    -- This is the honest limit of what streaming buys: most replies
    -- are one paragraph and gain nothing.
    it "sends a one-paragraph reply entirely at the end" $ do
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

    it "keeps a quote token with the paragraph that wrote it" $ do
      let body = "[↩#7405] 上升沿圆角是探头没补偿\n\n另外你那个 1X 档也要换"
          (a, b) = split body
      take 1 a `shouldBe` ["[↩#7405] 上升沿圆角是探头没补偿"]
      (a <> b) `shouldBe` sources (planReply body)

  describe "capTo" $ do
    it "leaves a reply within budget untouched" $ do
      let cs = map (TextChunk . T.pack . show) [1 :: Int .. 3]
      capTo maxChunks cs `shouldBe` cs

    -- The ceiling is per reply, not per call.  A streamed half that
    -- spent 8 leaves 2, and the remainder must respect that or one
    -- reply becomes twice the cap of messages.
    it "folds the tail together once the remaining budget runs out" $ do
      let cs = map (TextChunk . T.pack . show) [1 :: Int .. 5]
      capTo 2 cs `shouldBe` [TextChunk "1", TextChunk "2\n\n3\n\n4\n\n5"]

    -- Bounded, but never silently truncated: what the model wrote is
    -- still said, and still recorded as the bot's own words.
    it "keeps every word when it folds" $ do
      let cs = map (TextChunk . T.pack . show) [1 :: Int .. 5]
          folded = T.concat (map chunkSource (capTo 2 cs))
      mapM_ (\c -> folded `shouldSatisfy` T.isInfixOf (chunkSource c)) cs

    -- An exhausted budget still says the rest rather than dropping it;
    -- a dropped tail would read as the bot trailing off.
    it "still sends one merged message on an exhausted budget" $ do
      let cs = map (TextChunk . T.pack . show) [1 :: Int .. 3]
      capTo 0 cs `shouldBe` [TextChunk "1\n\n2\n\n3"]
