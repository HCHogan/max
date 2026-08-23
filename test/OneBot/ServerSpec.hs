module OneBot.ServerSpec (spec) where

import Control.Concurrent.STM (atomically, newTQueueIO, newTVarIO, readTQueue, readTVar)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import OneBot.Event (Event (EvConnectionReady))
import OneBot.Server (clearClientGeneration, publishClientGeneration)
import Test.Hspec

spec :: Spec
spec = describe "OneBot client publication" $ do
  it "lets an owner clear its own generation" $
    clearClientGeneration 1 (Just (1, "old" :: String))
      `shouldBe` Nothing

  it "does not let a stale connection clear its replacement" $
    clearClientGeneration 1 (Just (2, "new" :: String))
      `shouldBe` Just (2, "new")

  it "publishes a generation together with its queue barrier" $ do
    eventQueue <- newTQueueIO
    clientRef <- newTVarIO Nothing
    let connectedAt = posixSecondsToUTCTime 100
    publishClientGeneration 7 connectedAt (error "client must not be forced") eventQueue clientRef
    (event, slot) <- atomically ((,) <$> readTQueue eventQueue <*> readTVar clientRef)
    case (event, slot) of
      (EvConnectionReady 7 observedAt, Just (7, _)) -> observedAt `shouldBe` connectedAt
      other -> expectationFailure ("barrier and client generation diverged: " <> showBarrier other)
  where
    showBarrier (event, slot) =
      show event <> ", slot=" <> case slot of
        Nothing -> "empty"
        Just (generation, _) -> show generation
