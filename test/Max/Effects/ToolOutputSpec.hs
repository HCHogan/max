module Max.Effects.ToolOutputSpec (spec) where

import Control.Concurrent.Async (replicateConcurrently)
import Effectful (runEff)
import Max.Effects.ToolOutput (InlineMedia (..), drainInlineMedia, newToolOutputQueue, queueInlineMedia, runToolOutput, runToolOutputRead)
import Test.Hspec

spec :: Spec
spec = describe "ToolOutput" $ do
  it "drains queued media without resetting the turn-wide budget" $ do
    let first = InlineMedia "first" "data:image/png;base64,AA=="
        second = InlineMedia "second" "data:image/png;base64,BB=="
    (accepted, rejected, drained, empty, rejectedAfterDrain) <-
      runEff $ do
        queue <- newToolOutputQueue 1
        runToolOutputRead queue . runToolOutput queue $ do
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

  it "shares one atomic budget across concurrent producers and a separate consumer" $ do
    queue <- runEff (newToolOutputQueue 4)
    let media = InlineMedia "parallel" "data:image/png;base64,AA=="
    accepted <- replicateConcurrently 32 (runEff . runToolOutput queue $ queueInlineMedia media)
    length (filter id accepted) `shouldBe` 4
    drained <- runEff . runToolOutputRead queue $ drainInlineMedia
    length drained `shouldBe` 4
    runEff (runToolOutput queue (queueInlineMedia media)) `shouldReturn` False
    runEff (runToolOutputRead queue drainInlineMedia) `shouldReturn` []

  it "starts each interpreter with a fresh queue and budget" $ do
    let media = InlineMedia "fresh" "data:image/png;base64,AA=="
        runOnce = runEff $ do
          queue <- newToolOutputQueue 1
          runToolOutput queue (queueInlineMedia media)
    runOnce `shouldReturn` True
    runOnce `shouldReturn` True
