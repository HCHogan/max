module Max.Effects.PlatformApiSpec (spec) where

import Control.Concurrent (forkFinally, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
  ( TMVar,
    newEmptyTMVarIO,
    newTVarIO,
    readTVarIO,
  )
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Max.Effects.PlatformApi (withPendingCall)
import OneBot.Action (Response)
import Test.Hspec

spec :: Spec
spec = describe "PlatformApi pending calls" $ do
  it "removes a registered call when the waiter is cancelled" $ do
    pendingCalls <- newTVarIO Map.empty
    response <- newEmptyTMVarIO :: IO (TMVar (Either Text Response))
    ready <- newEmptyMVar
    blocked <- newEmptyMVar
    done <- newEmptyMVar
    tid <-
      forkFinally
        ( withPendingCall pendingCalls "echo-1" response $ do
            putMVar ready ()
            takeMVar blocked
        )
        (putMVar done)
    takeMVar ready
    registered <- readTVarIO pendingCalls
    Map.member "echo-1" registered `shouldBe` True
    killThread tid
    _ <- takeMVar done
    remaining <- readTVarIO pendingCalls
    Map.null remaining `shouldBe` True
