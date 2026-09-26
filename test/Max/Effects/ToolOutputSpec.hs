module Max.Effects.ToolOutputSpec (spec) where

import Control.Concurrent.Async (replicateConcurrently)
import Effectful (runEff)
import Max.Effects.ToolOutput (InlineMedia (..), drainInlineMedia, forkToolOutputQueue, newToolOutputQueue, queueInlineMedia, queueInlineMediaOnce, runToolOutput, runToolOutputRead)
import Test.Hspec

spec :: Spec
spec = describe "ToolOutput" $ do
  it "isolates invocation attachments while retaining the turn quota and once-only keys" $ do
    root <- runEff (newToolOutputQueue 2)
    first <- runEff (forkToolOutputQueue root)
    second <- runEff (forkToolOutputQueue root)
    let image = InlineMedia "first" "data:image/png;base64,AA==" Nothing
        video = InlineMedia "second" "data:video/mp4;base64,BB==" (Just 128)
    runEff (runToolOutput first (queueInlineMediaOnce "browser" image)) `shouldReturn` True
    runEff (runToolOutput second (queueInlineMediaOnce "browser" video)) `shouldReturn` False
    runEff (runToolOutput second (queueInlineMedia video)) `shouldReturn` True
    runEff (runToolOutputRead root drainInlineMedia) `shouldReturn` []
    runEff (runToolOutputRead second drainInlineMedia) `shouldReturn` [video]
    runEff (runToolOutputRead first drainInlineMedia) `shouldReturn` [image]
    third <- runEff (forkToolOutputQueue root)
    runEff (runToolOutput third (queueInlineMedia image)) `shouldReturn` False

  it "drains queued media without resetting the turn-wide budget" $ do
    let first = InlineMedia "first" "data:image/png;base64,AA==" Nothing
        second = InlineMedia "second" "data:image/png;base64,BB==" Nothing
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
    let media = InlineMedia "parallel" "data:image/png;base64,AA==" Nothing
    accepted <- replicateConcurrently 32 (runEff . runToolOutput queue $ queueInlineMedia media)
    length (filter id accepted) `shouldBe` 4
    drained <- runEff . runToolOutputRead queue $ drainInlineMedia
    length drained `shouldBe` 4
    runEff (runToolOutput queue (queueInlineMedia media)) `shouldReturn` False
    runEff (runToolOutputRead queue drainInlineMedia) `shouldReturn` []

  it "starts each interpreter with a fresh queue and budget" $ do
    let media = InlineMedia "fresh" "data:image/png;base64,AA==" Nothing
        runOnce = runEff $ do
          queue <- newToolOutputQueue 1
          runToolOutput queue (queueInlineMedia media)
    runOnce `shouldReturn` True
    runOnce `shouldReturn` True
