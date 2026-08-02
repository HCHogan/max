module Max.RecallSpec (spec) where

import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Max.Recall
import Test.Hspec

spec :: Spec
spec = describe "Max.Recall" $ do
  it "protects memory and episode candidates from a higher-scoring raw corpus" $ do
    let messages = [candidate "message" ("message:" <> key) (1 - fromIntegral n / 100) | (n, key) <- zip [0 :: Int ..] (map (fromString . show) [1 .. 10 :: Int])]
        memories = [candidate "memory" "memory:1" 0.8, candidate "memory" "memory:2" 0.79]
        episodes = [candidate "episode" "episode:1" 0.7, candidate "episode" "episode:2" 0.69]
        hits = selectRecallHits now 6 (messages <> memories <> episodes)
    sort (map (.rhSource) hits)
      `shouldBe` ["episode", "episode", "memory", "memory", "message", "message"]

  it "deduplicates raw, pin, and caption forms while preserving their best signals" $ do
    let raw = (candidate "message" "message:7" 0.9) {rcSnippet = "raw"}
        pinned = (candidate "pin" "message:7" 0.7) {rcSnippet = "pin", rcSemanticScore = Just 0.8, rcPinned = True}
        caption = (candidate "caption" "message:7" 1) {rcSnippet = "caption"}
        hits = selectRecallHits now 10 [raw, pinned, caption]
    hits `shouldSatisfy` \case
      [hit] ->
        hit.rhSource == "caption"
          && hit.rhSnippet == "caption"
          && hit.rhPinned
          && hit.rhLexicalScore == Just 1
          && hit.rhSemanticScore == Just 0.8
      _ -> False

  it "fills unused quota from an otherwise single-source result set deterministically" $ do
    let candidates = [candidate "message" ("message:" <> fromString (show n)) (1 - fromIntegral n / 100) | n <- [1 .. 10 :: Int]]
        first = selectRecallHits now 5 candidates
    length first `shouldBe` 5
    first `shouldBe` selectRecallHits now 5 candidates

candidate :: Text -> Text -> Double -> RecallCandidate
candidate source key lexical =
  RecallCandidate
    { rcSource = source,
      rcDedupKey = key,
      rcSnippet = key,
      rcOccurredAt = now,
      rcPrincipalId = Nothing,
      rcMessageId = Nothing,
      rcEpisodeHandle = Nothing,
      rcMemoryId = Nothing,
      rcImportance = 0,
      rcLexicalScore = Just lexical,
      rcSemanticScore = Nothing,
      rcPinned = False,
      rcPermanent = False
    }

now :: UTCTime
now = read "2026-08-02 12:00:00 UTC"

fromString :: String -> Text
fromString = T.pack
