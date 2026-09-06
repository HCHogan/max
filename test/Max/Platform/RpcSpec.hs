module Max.Platform.RpcSpec (spec) where

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
import Max.Platform.Failure (PlatformFailure (..))
import Max.Platform.Rpc (callQQActionOnGeneration, withPendingCall)
import OneBot.Action (Action (GetGroupInfo), Response)
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: Spec
spec = do
  describe "platform RPC pending calls" $ do
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

  describe "generation-fenced QQ calls" $ do
    it "fails without touching a client from another websocket generation" $ do
      clientRef <- newTVarIO (Just (2, error "stale client must not be forced"))
      result <- callQQActionOnGeneration clientRef 1 (GetGroupInfo (GroupId 7)) 10
      case result of
        Left err -> err `shouldBe` PlatformGenerationChanged
        Right _ -> expectationFailure "stale generation unexpectedly issued an action"
