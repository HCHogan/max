module Max.Effects.ToolOutputSpec (spec) where

import Effectful (runEff)
import Max.Effects.ToolOutput (InlineMedia (..), drainInlineMedia, queueInlineMedia, runToolOutput)
import Test.Hspec

spec :: Spec
spec = describe "ToolOutput" $ do
  it "drains queued media without resetting the turn-wide budget" $ do
    let first = InlineMedia "first" "data:image/png;base64,AA=="
        second = InlineMedia "second" "data:image/png;base64,BB=="
    (accepted, rejected, drained, empty, rejectedAfterDrain) <-
      runEff . runToolOutput 1 $ do
        accepted <- queueInlineMedia first
        rejected <- queueInlineMedia second
        drained <- drainInlineMedia
        empty <- drainInlineMedia
        rejectedAfterDrain <- queueInlineMedia second
        pure (accepted, rejected, drained, empty, rejectedAfterDrain)
    accepted `shouldBe` True
    rejected `shouldBe` False
    drained `shouldBe` [first]
    empty `shouldBe` []
    rejectedAfterDrain `shouldBe` False

  it "starts each interpreter with a fresh queue and budget" $ do
    let media = InlineMedia "fresh" "data:image/png;base64,AA=="
        runOnce = runEff . runToolOutput 1 $ queueInlineMedia media
    runOnce `shouldReturn` True
    runOnce `shouldReturn` True
