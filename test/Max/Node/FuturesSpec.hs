module Max.Node.FuturesSpec (spec) where

import Control.Concurrent.STM
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Max.Node.Futures qualified as Futures
import System.Timeout (timeout)
import Test.Hspec

newFutures :: IO (Futures.Futures Int Int Text)
newFutures = atomically Futures.newFutures

spec :: Spec
spec = describe "owned node futures" $ do
  it "keeps a completed admission reservation until its call attaches exactly once" $ do
    futures <- newFutures
    atomically (Futures.reserve futures 1 7 (pure True))
    atomically (Futures.publish futures 7 "actual result") `shouldReturn` True
    Just ticket <- atomically (Futures.claim futures 1 7)
    atomically (isNothing <$> Futures.claim futures 1 7) `shouldReturn` True
    atomically (Futures.await ticket) `shouldReturn` Just ["actual result"]
    atomically (Futures.release ticket) `shouldReturn` Set.singleton 7
    atomically (Futures.retainedKeys futures) `shouldReturn` Set.empty

  it "transfers a ready reservation into a join without losing its result" $ do
    futures <- newFutures
    atomically (Futures.reserve futures 1 7 (pure True))
    _ <- atomically (Futures.publish futures 7 "ready before join")
    ticket <- atomically (Futures.subscribe futures 1 (Set.fromList [7, 8]) Map.empty (pure True))
    atomically (isNothing <$> Futures.claim futures 1 7) `shouldReturn` True
    timeout 20000 (atomically (Futures.await ticket)) `shouldReturn` Nothing
    _ <- atomically (Futures.publish futures 8 "second result")
    atomically (Futures.await ticket) `shouldReturn` Just ["ready before join", "second result"]

  it "does not let a stale release remove a new subscription for the same owner and producer" $ do
    futures <- newFutures
    old <- atomically (Futures.subscribe futures 1 (Set.singleton 7) Map.empty (pure True))
    _ <- atomically (Futures.release old)
    current <- atomically (Futures.subscribe futures 1 (Set.singleton 7) Map.empty (pure True))
    _ <- atomically (Futures.release old)
    atomically (Futures.publish futures 7 "new subscription") `shouldReturn` True
    atomically (Futures.await current) `shouldReturn` Just ["new subscription"]

  it "invalidates only the replaced producer in a partially settled join" $ do
    futures <- newFutures
    ticket <- atomically (Futures.subscribe futures 1 (Set.fromList [7, 8]) Map.empty (pure True))
    _ <- atomically (Futures.publish futures 7 "old generation")
    atomically (Futures.invalidate futures 7)
    _ <- atomically (Futures.publish futures 8 "sibling")
    timeout 20000 (atomically (Futures.await ticket)) `shouldReturn` Nothing
    _ <- atomically (Futures.publish futures 7 "replacement")
    atomically (Futures.await ticket) `shouldReturn` Just ["replacement", "sibling"]

  it "releases invalid owners while preserving another subscriber's actual result" $ do
    futures <- newFutures
    valid <- newTVarIO True
    ended <- atomically (Futures.subscribe futures 1 (Set.singleton 7) Map.empty (readTVar valid))
    active <- atomically (Futures.subscribe futures 2 (Set.singleton 7) Map.empty (pure True))
    atomically (writeTVar valid False)
    atomically (Futures.publish futures 7 "kept") `shouldReturn` True
    atomically (Futures.await ended) `shouldReturn` Nothing
    atomically (Futures.await active) `shouldReturn` Just ["kept"]
    _ <- atomically (Futures.release active)
    atomically (Futures.hasSubscribers futures 7) `shouldReturn` False
