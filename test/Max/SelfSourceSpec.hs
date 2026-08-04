module Max.SelfSourceSpec (spec) where

import Data.Text qualified as T
import Max.SelfSource
import Test.Hspec

spec :: Spec
spec = describe "deployed self-source snapshot" $ do
  it "contains implementation, tests, migrations, docs, and ADRs" $ do
    (paths, truncated) <- requireRight (sourcePaths "" 1000)
    truncated `shouldBe` False
    paths `shouldContain` ["src/Max/Historian.hs"]
    paths `shouldContain` ["test/Max/HistorianSpec.hs"]
    paths `shouldContain` ["migrations/000_baseline.sql"]
    paths `shouldContain` ["docs/adr/001-context-memory-foundations.md"]
    paths `shouldContain` ["docs/adr/002-partial-plans-adaptive-elaboration.md"]
    paths `shouldContain` [".env.example"]

  it "searches literal source with path and line provenance" $ do
    matches <- requireRight (searchSource "historianRetryDelaySeconds" (Just "src/") 10)
    matches `shouldSatisfy` any (\match -> match.smPath == "src/Max/Historian.hs" && match.smLine > 0)

  it "reads bounded numbered lines from the embedded ADR" $ do
    slice <- requireRight (readSource "docs/adr/001-context-memory-foundations.md" 1 12)
    slice.ssStartLine `shouldBe` 1
    slice.ssEndLine `shouldBe` 12
    slice.ssContent `shouldSatisfy` T.isInfixOf "1 | # ADR 001"
    slice.ssContent `shouldSatisfy` T.isInfixOf "Context and Memory Foundations"

  it "rejects host paths and excludes runtime/developer files" $ do
    readSource "../max.yaml" 1 10 `shouldSatisfy` isLeft
    readSource "/var/lib/max-bot/max.yaml" 1 10 `shouldSatisfy` isLeft
    sourcePaths ".env" 10 `shouldBe` Right ([], False)
    sourcePaths "AGENTS.md" 10 `shouldBe` Right ([], False)

  it "publishes a deterministic snapshot identity" $ do
    T.length sourceBundleHash `shouldBe` 64
    sourceFileCount `shouldSatisfy` (> 200)
    sourceByteCount `shouldSatisfy` (> 1000000)

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

requireRight :: Either T.Text a -> IO a
requireRight = either (\err -> expectationFailure (T.unpack err) >> fail "unreachable") pure
