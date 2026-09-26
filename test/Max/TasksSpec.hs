{-# LANGUAGE NumericUnderscores #-}

module Max.TasksSpec (spec) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.Async (cancel, race, wait, waitCatch, waitCatchSTM, withAsync)
import Control.Concurrent.STM (atomically, check)
import Control.Monad (forM, forM_, replicateM_, void)
import Data.Either (isLeft, isRight)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (addUTCTime, getCurrentTime)
import Max.Node.Events qualified as Events
import Max.Node.Executor qualified as Node
import Max.Node.Render (renderOpenTasks)
import Max.Platform.Types (CanonicalMessageId (..))
import Max.Tasks
  ( OpenTask (..),
    TaskCancelled (..),
    TaskInfo (..),
    activateTurnRuntime,
    authorizeTurnOutput,
    awaitTurnSilence,
    beginTurnRuntime,
    bindTurnDeadline,
    bindTurnEvents,
    cancelAllTasks,
    cancelTask,
    checkTurnCancellation,
    finishTurnCall,
    finishTurnRuntime,
    inFlightTriggers,
    listTasks,
    newTaskRegistry,
    otherOpenTasks,
    retainTurnWork,
    setTurnExecutor,
    setTurnPhase,
    startTurnCall,
    turnAcceptsWork,
    turnEvents,
    turnIsLive,
    turnRuntimeTaskId,
    turnWasCancelled,
  )
import Max.Turn.Types (AgentTurnId (..), AgentTurnRef (..), ExecutionOrdinal (..), TurnOrdinal (..))
import OneBot.Types (GroupId (..), UserId (..))
import System.Timeout (timeout)
import Test.Hspec

gid :: GroupId
gid = GroupId 100

alice, bob :: UserId
alice = UserId 1
bob = UserId 2

reference :: Int -> AgentTurnRef
reference n = AgentTurnRef (AgentTurnId (fromIntegral n)) (TurnOrdinal (fromIntegral n))

spec :: Spec
spec = describe "Max.Tasks" $ do
  it "shows at most sixteen other open node tasks without exposing private child nodes or ended work" $ do
    registry <- newTaskRegistry
    node <- atomically Events.newNode
    let attach n group = do
          runtime <- beginTurnRuntime registry (reference n) group alice (Just (CanonicalMessageId (fromIntegral n)))
          atomically $ do
            events <- Events.newTask node
            bindTurnEvents registry (AgentTurnId (fromIntegral n)) events >>= check
          pure runtime
    current <- attach 1 gid
    sibling <- attach 2 gid
    _privateChild <- beginTurnRuntime registry (reference 3) gid alice Nothing
    _otherGroup <- attach 4 (GroupId 101)
    ended <- attach 5 gid
    finishTurnRuntime registry ended
    cancelled <- attach 6 gid
    cancelTask registry (turnRuntimeTaskId cancelled) `shouldReturn` True
    queued <- attach 27 gid
    executor <- Node.newExecutor
    queuedActor <- atomically $ do
      _ <- Node.registerTask executor (AgentTurnId 99) Node.NewRequest
      Node.registerTask executor (AgentTurnId 27) Node.NewRequest
    setTurnExecutor queued queuedActor
    setTurnPhase sibling "tools"
    startTurnCall sibling (ExecutionOrdinal 1) "web_search"
    startTurnCall sibling (ExecutionOrdinal 2) "agent"
    [view] <- otherOpenTasks registry current
    view.turn `shouldBe` reference 2
    view.trigger `shouldBe` Just 2
    view.phase `shouldBe` "tools"
    view.pending `shouldBe` [(ExecutionOrdinal 1, "web_search"), (ExecutionOrdinal 2, "agent")]
    view.ageSeconds `shouldSatisfy` (>= 0)
    finishTurnCall sibling (ExecutionOrdinal 1)
    [settled] <- otherOpenTasks registry current
    settled.pending `shouldBe` [(ExecutionOrdinal 2, "agent")]
    rest <- forM [7 .. 26] (`attach` gid)
    views <- otherOpenTasks registry current
    length views `shouldBe` 16
    [rendered] <- pure (renderOpenTasks views)
    length (T.lines rendered) `shouldBe` 17
    rendered `shouldSatisfy` T.isInfixOf "t#2:r2"
    forM_ (sibling : rest) (finishTurnRuntime registry)
    otherOpenTasks registry current >>= (`shouldSatisfy` null)

  it "cancels retained calls at the original deadline after the model task ends" $ do
    registry <- newTaskRegistry
    turn <- beginTurnRuntime registry (reference 1) gid alice Nothing
    now <- getCurrentTime
    atomically (bindTurnDeadline registry (AgentTurnId 1) (addUTCTime 0.05 now)) `shouldReturn` True
    atomically (bindTurnDeadline registry (AgentTurnId 1) (addUTCTime 3600 now)) `shouldReturn` True
    never <- newEmptyMVar
    withAsync (takeMVar never :: IO ()) $ \worker -> do
      retainTurnWork turn (cancel worker) (cancel worker) (void (waitCatchSTM worker))
      timeout 1000000 (finishTurnRuntime registry turn) `shouldReturn` Just ()
      waitCatch worker >>= (`shouldSatisfy` isLeft)
    atomically (turnWasCancelled turn) `shouldReturn` False
    atomically (turnIsLive registry (AgentTurnId 1)) `shouldReturn` False

  it "does not revoke already-settled results when cleanup runs after the deadline" $ do
    registry <- newTaskRegistry
    turn <- beginTurnRuntime registry (reference 1) gid alice Nothing
    now <- getCurrentTime
    atomically (bindTurnDeadline registry (AgentTurnId 1) (addUTCTime (-1) now)) `shouldReturn` True
    withAsync (pure ()) $ \worker -> do
      wait worker
      retainTurnWork turn (cancel worker) (cancel worker) (void (waitCatchSTM worker))
      finishTurnRuntime registry turn
    atomically (turnWasCancelled turn) `shouldReturn` False

  it "retains completed outcomes under delivery backpressure beyond the call deadline" $ do
    registry <- newTaskRegistry
    turn <- beginTurnRuntime registry (reference 1) gid alice Nothing
    now <- getCurrentTime
    atomically (bindTurnDeadline registry (AgentTurnId 1) (addUTCTime (-1) now)) `shouldReturn` True
    release <- newEmptyMVar
    withAsync (pure ()) $ \call ->
      withAsync (takeMVar release :: IO ()) $ \delivery -> do
        wait call
        retainTurnWork turn (cancel delivery) (cancel call) (void (waitCatchSTM delivery))
        withAsync (finishTurnRuntime registry turn) $ \closing -> do
          timeout 20000 (wait closing) `shouldReturn` Nothing
          atomically (turnWasCancelled turn) `shouldReturn` False
          putMVar release ()
          timeout 1000000 (wait closing) `shouldReturn` Just ()
          waitCatch delivery >>= (`shouldSatisfy` isRight)

  it "retains detached work while releasing model admission and public output" $ do
    registry <- newTaskRegistry
    turn <- beginTurnRuntime registry (reference 1) gid alice (Just (CanonicalMessageId 7001))
    node <- Node.newExecutor
    owner <- atomically (Node.registerTask node (AgentTurnId 1) Node.NewRequest)
    setTurnExecutor turn owner
    next <- atomically (Node.registerTask node (AgentTurnId 2) Node.NewRequest)
    release <- newEmptyMVar
    withAsync (takeMVar release) $ \worker -> do
      retainTurnWork turn (cancel worker) (cancel worker) (void (waitCatchSTM worker))
      withAsync (finishTurnRuntime registry turn) $ \closing -> do
        timeout 1000000 (atomically (turnAcceptsWork registry (AgentTurnId 1) >>= check . not)) `shouldReturn` Just ()
        atomically (turnIsLive registry (AgentTurnId 1)) `shouldReturn` True
        timeout 1000000 (Node.enter next) `shouldReturn` Just True
        authorizeTurnOutput registry gid (AgentTurnId 1) `shouldReturn` False
        inFlightTriggers registry gid `shouldReturn` Set.empty
        timeout 20000 (wait closing) `shouldReturn` Nothing
        putMVar release ()
        timeout 1000000 (wait closing) `shouldReturn` Just ()
    atomically (turnIsLive registry (AgentTurnId 1)) `shouldReturn` False
    listTasks registry Nothing >>= (`shouldSatisfy` null)

  it "kills retained calls after the model segment has ended" $ do
    registry <- newTaskRegistry
    turn <- beginTurnRuntime registry (reference 1) gid alice Nothing
    never <- newEmptyMVar
    withAsync (takeMVar never :: IO ()) $ \worker -> do
      retainTurnWork turn (cancel worker) (cancel worker) (void (waitCatchSTM worker))
      withAsync (finishTurnRuntime registry turn) $ \closing -> do
        timeout 1000000 (atomically (turnAcceptsWork registry (AgentTurnId 1) >>= check . not)) `shouldReturn` Just ()
        cancelTask registry (turnRuntimeTaskId turn) `shouldReturn` True
        waitCatch worker >>= (`shouldSatisfy` isLeft)
        timeout 1000000 (wait closing) `shouldReturn` Just ()

  it "signals each killed task only once while its finalizer is still running" $ do
    registry <- newTaskRegistry
    turn <- beginTurnRuntime registry (reference 1) gid alice Nothing
    signals <- newIORef (0 :: Int)
    _ <- activateTurnRuntime turn "working" (modifyIORef' signals (+ 1))
    cancelAllTasks registry `shouldReturn` 1
    cancelAllTasks registry `shouldReturn` 1
    cancelTask registry (turnRuntimeTaskId turn) `shouldReturn` True
    readIORef signals `shouldReturn` 1

  it "records a pre-activation kill and refuses to rebind its revoked runtime" $ do
    registry <- newTaskRegistry
    turn <- beginTurnRuntime registry (reference 1) gid alice Nothing
    events <- atomically (turnEvents turn)
    cancelTask registry (turnRuntimeTaskId turn) `shouldReturn` True
    map (.body) <$> atomically (Events.peekAll events) `shouldReturn` [Events.Cancelled]
    fresh <- atomically (Events.newNode >>= Events.newTask)
    atomically (bindTurnEvents registry (AgentTurnId 1) fresh) `shouldReturn` False
    atomically ((== events) <$> turnEvents turn) `shouldReturn` True
    activateTurnRuntime turn "late worker" (pure ()) `shouldReturn` True
    atomically (turnAcceptsWork registry (AgentTurnId 1)) `shouldReturn` False

  describe "explicit TurnRuntime" $ do
    it "owns visibility, phase and finalization without trigger lookup" $ do
      reg <- newTaskRegistry
      turn <- beginTurnRuntime reg (reference 1) gid alice (Just (CanonicalMessageId 7001))
      starting <- listTasks reg (Just gid)
      map tiKind starting `shouldBe` ["starting"]
      preKilled <- activateTurnRuntime turn "llm" (pure ())
      preKilled `shouldBe` False
      setTurnPhase turn "tools"
      running <- listTasks reg (Just gid)
      map tiKind running `shouldBe` ["tools"]
      finishTurnRuntime reg turn
      (null <$> listTasks reg (Just gid)) `shouldReturn` True

    it "stamps a heartbeat on every phase change, and only on a phase change" $ do
      reg <- newTaskRegistry
      turn <- beginTurnRuntime reg (reference 1) gid alice (Just (CanonicalMessageId 7001))
      [begun] <- listTasks reg (Just gid)
      tiProgressAt begun `shouldBe` tiStartedAt begun
      threadDelay 2000
      _ <- activateTurnRuntime turn "llm" (pure ())
      [activated] <- listTasks reg (Just gid)
      tiProgressAt activated `shouldSatisfy` (> tiStartedAt activated)
      threadDelay 2000
      setTurnPhase turn "tools"
      [moved] <- listTasks reg (Just gid)
      tiProgressAt moved `shouldSatisfy` (> tiProgressAt activated)
      [reread] <- listTasks reg (Just gid)
      tiProgressAt reread `shouldBe` tiProgressAt moved
      _ <- finishTurnRuntime reg turn
      pure ()

    -- Wide margins tolerate scheduler jitter.
    it "waits out silence without firing on a turn that keeps moving" $ do
      reg <- newTaskRegistry
      turn <- beginTurnRuntime reg (reference 1) gid alice (Just (CanonicalMessageId 7001))
      working <-
        race
          (awaitTurnSilence turn 200_000)
          (replicateM_ 20 (threadDelay 20_000 >> setTurnPhase turn "tools"))
      working `shouldSatisfy` isRight
      stalled <- race (awaitTurnSilence turn 50_000) (threadDelay 3_000_000)
      stalled `shouldSatisfy` isLeft
      _ <- finishTurnRuntime reg turn
      pure ()

    it "carries a pre-activation kill and exposes a cancellation checkpoint" $ do
      reg <- newTaskRegistry
      turn <- beginTurnRuntime reg (reference 1) gid alice (Just (CanonicalMessageId 7001))
      accepted <- cancelTask reg (turnRuntimeTaskId turn)
      preKilled <- activateTurnRuntime turn "llm" (pure ())
      (accepted, preKilled) `shouldBe` (True, True)
      checkTurnCancellation turn `shouldThrow` (\TaskCancelled -> True)
      finishTurnRuntime reg turn

  describe "dispatch tracking" $ do
    it "reports a trigger from entry until release" $ do
      reg <- newTaskRegistry
      atStart <- inFlightTriggers reg gid
      tid <- beginTurnRuntime reg (reference 1) gid alice (Just (CanonicalMessageId 7001))
      during <- inFlightTriggers reg gid
      _ <- finishTurnRuntime reg tid
      atEnd <- inFlightTriggers reg gid
      (atStart, during, atEnd)
        `shouldBe` (Set.empty, Set.fromList [7001], Set.empty)

    it "tracks concurrent triggers independently and keeps groups apart" $ do
      reg <- newTaskRegistry
      t1 <- beginTurnRuntime reg (reference 1) gid alice (Just (CanonicalMessageId 7001))
      _ <- beginTurnRuntime reg (reference 2) gid bob (Just (CanonicalMessageId 7002))
      _ <- finishTurnRuntime reg t1
      inflight <- inFlightTriggers reg gid
      inflight `shouldBe` Set.fromList [7002]
      inFlightTriggers reg (GroupId 999) `shouldReturn` Set.empty

    it "treats a poke's sentinel message id as no trigger" $ do
      reg <- newTaskRegistry
      _ <- beginTurnRuntime reg (reference 1) gid alice (Just (CanonicalMessageId 0))
      inflight <- inFlightTriggers reg gid
      inflight `shouldBe` Set.empty
