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
import Max.ReplySend (SendBudget (..), canStream, capTo, freshBudget)
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

    -- Tables become a rendered PNG, so half a table is not a cosmetic
    -- problem — it is two images of nonsense.  Safe by construction:
    -- 'takeTable' reads a table as a run of consecutive pipe rows, so a
    -- blank line inside one would already have ended it, and a blank
    -- line is the only place 'readyPrefix' cuts.
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
    -- a dropped tail would read as the bot trailing off.  Correct for a
    -- call that sends a whole reply — and the exact hole 'canStream'
    -- closes for a reply that arrives as many calls.
    it "still sends one merged message on an exhausted budget" $ do
      let cs = map (TextChunk . T.pack . show) [1 :: Int .. 3]
      capTo 0 cs `shouldBe` [TextChunk "1\n\n2\n\n3"]

  -- Production found this within two minutes of the deploy: a
  -- 12-paragraph answer went out as 12 messages against a cap of 10,
  -- with the over-budget fold landing in the middle of the reply
  -- instead of at its end.  Each streamed paragraph is its own call to
  -- 'sendAndPersistReply', and "always send at least one" per call adds
  -- up to no ceiling at all.
  describe "canStream" $ do
    it "lets a sink spend while there is room to spare" $
      canStream freshBudget {sbChunksLeft = 2} `shouldBe` True

    -- The last slot belongs to the final send, which is where the fold
    -- has to happen for the merged message to land at the end.
    it "reserves the last slot for the final send" $
      canStream freshBudget {sbChunksLeft = 1} `shouldBe` False

    it "stays refused once spent" $
      canStream freshBudget {sbChunksLeft = 0} `shouldBe` False

    -- The property that was actually violated: however a reply is cut
    -- up, it costs the same number of messages as sending it whole.
    it "makes a streamed reply cost the same as an unstreamed one" $ do
      let paras = [T.pack ("段落 " <> show i) | i <- [1 :: Int .. 14]]
          -- Walk the paragraphs the way the sink does: spend while
          -- allowed, then hand everything left to the final send.
          step (budget, sent) p
            | canStream budget =
                let planned = capTo budget.sbChunksLeft (planReply p)
                 in ( budget {sbChunksLeft = budget.sbChunksLeft - length planned},
                      sent <> planned
                    )
            | otherwise = (budget, sent)
          (leftover, streamed) = foldl step (freshBudget, []) paras
          heldBack = drop (length streamed) paras
          final = capTo leftover.sbChunksLeft (planReply (T.intercalate "\n\n" heldBack))
      length (streamed <> final) `shouldBe` maxChunks
      length (planReply (T.intercalate "\n\n" paras)) `shouldBe` maxChunks
      -- and nothing the model wrote was dropped on the way
      let saidAll = T.concat (map chunkSource (streamed <> final))
      mapM_ (\p -> saidAll `shouldSatisfy` T.isInfixOf p) paras
