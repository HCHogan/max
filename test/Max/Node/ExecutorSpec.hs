module Max.Node.ExecutorSpec (spec) where

import Control.Concurrent.Async (cancel, wait, withAsync)
import Control.Concurrent.STM
import Control.Monad (forM, forM_)
import Max.Node.Executor qualified as Node
import Max.Turn.Types (AgentTurnId (..))
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "single-segment node executor" $ do
  it "releases an async await and reacquires before returning its actual result" $ do
    node <- Node.newExecutor
    first <- atomically (Node.registerTask node (AgentTurnId 1) Node.NewRequest)
    second <- atomically (Node.registerTask node (AgentTurnId 2) Node.NewRequest)
    value <- newEmptyTMVarIO
    withAsync (Node.await first True retry (takeTMVar value)) $ \waiting -> do
      timeout 1000000 (Node.enter second) `shouldReturn` Just True
      atomically (putTMVar value (42 :: Int))
      timeout 20000 (wait waiting) `shouldReturn` Nothing
      atomically (Node.closeTask second)
      timeout 1000000 (wait waiting) `shouldReturn` Just (Just 42)

  it "orders guest steps, resumed tasks, requests and notices FIFO within each class" $ do
    node <- Node.newExecutor
    owner <- atomically (Node.registerTask node (AgentTurnId 1) Node.NewRequest)
    notice <- atomically (Node.registerTask node (AgentTurnId 2) Node.Notice)
    request <- atomically (Node.registerTask node (AgentTurnId 3) Node.NewRequest)
    resumed <- atomically (Node.registerTask node (AgentTurnId 4) Node.ResumedTask)
    guest1 <- atomically (Node.guestActor owner)
    guest2 <- atomically (Node.guestActor owner)
    atomically (Node.leave owner)
    forM_ [guest1, guest2, resumed, request, notice] $ \actor -> do
      timeout 1000000 (Node.enter actor) `shouldReturn` Just True
      atomically (Node.closeActor actor)

  it "holds short calls only until their shared deadline" $ do
    node <- Node.newExecutor
    first <- atomically (Node.registerTask node (AgentTurnId 1) Node.NewRequest)
    second <- atomically (Node.registerTask node (AgentTurnId 2) Node.NewRequest)
    value <- newEmptyTMVarIO
    expired <- newTVarIO False
    withAsync (Node.await first False (readTVar expired >>= check) (takeTMVar value)) $ \waiting -> do
      -- Observing that the second actor is blocked must not abandon its actor.
      withAsync (Node.enter second) $ \next -> do
        timeout 20000 (wait next) `shouldReturn` Nothing
        atomically (writeTVar expired True)
        timeout 1000000 (wait next) `shouldReturn` Just True
        atomically (putTMVar value (7 :: Int))
        atomically (Node.closeTask second)
        timeout 1000000 (wait waiting) `shouldReturn` Just (Just 7)

  it "keeps the permit when a short call settles before its deadline" $ do
    node <- Node.newExecutor
    first <- atomically (Node.registerTask node (AgentTurnId 1) Node.NewRequest)
    second <- atomically (Node.registerTask node (AgentTurnId 2) Node.NewRequest)
    Node.await first False retry (pure (7 :: Int)) `shouldReturn` Just 7
    withAsync (Node.enter second) $ \next -> do
      timeout 20000 (wait next) `shouldReturn` Nothing
      atomically (Node.leave first)
      wait next `shouldReturn` True

  it "wakes a closed task without waiting for or cancelling its future" $
    forM_ [False, True] $ \immediate -> do
      node <- Node.newExecutor
      actor <- atomically (Node.registerTask node (AgentTurnId 1) Node.NewRequest)
      future <- newEmptyTMVarIO
      withAsync (Node.await actor immediate retry (readTMVar future)) $ \waiting -> do
        atomically (Node.closeTask actor)
        timeout 1000000 (wait waiting) `shouldReturn` Just Nothing
        atomically (putTMVar future (3 :: Int))
        atomically (readTMVar future) `shouldReturn` 3

  it "cancelling a queued guest leaves the current owner intact" $ do
    node <- Node.newExecutor
    owner <- atomically (Node.registerTask node (AgentTurnId 1) Node.NewRequest)
    guest <- atomically (Node.guestActor owner)
    second <- atomically (Node.registerTask node (AgentTurnId 2) Node.NewRequest)
    withAsync (Node.enter guest) $ \queued -> do
      timeout 20000 (wait queued) `shouldReturn` Nothing
      cancel queued
    withAsync (Node.enter second) $ \queued -> do
      timeout 20000 (wait queued) `shouldReturn` Nothing
      atomically (Node.closeTask owner)
      wait queued `shouldReturn` True

  it "admits at most 32 open tasks while keeping further requests queued" $ do
    node <- Node.newExecutor
    actors@(first : _) <- forM [1 .. 33] $ \n -> atomically (Node.registerTask node (AgentTurnId n) Node.NewRequest)
    forM_ (take 32 actors) $ \actor -> do
      Node.enter actor `shouldReturn` True
      atomically (Node.leave actor)
    withAsync (Node.enter (last actors)) $ \queued -> do
      timeout 20000 (wait queued) `shouldReturn` Nothing
      atomically (Node.closeTask first)
      wait queued `shouldReturn` True
