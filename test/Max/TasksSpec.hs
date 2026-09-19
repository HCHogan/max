{-# LANGUAGE NumericUnderscores #-}

module Max.TasksSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Control.Monad (replicateM_)
import Data.Either (isLeft, isRight)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Set qualified as Set
import Max.Platform.Types (CanonicalMessageId (..))
import Max.Tasks
  ( TaskCancelled (..),
    TaskInfo (..),
    activateTurnRuntime,
    awaitTurnSilence,
    beginTurnRuntime,
    cancelAllTasks,
    cancelTask,
    checkTurnCancellation,
    finishTurnRuntime,
    inFlightTriggers,
    listTasks,
    newTaskRegistry,
    setTurnPhase,
    turnRuntimeTaskId,
  )
import Max.Turn.Types (AgentTurnId (..), AgentTurnRef (..), TurnOrdinal (..))
import OneBot.Types (GroupId (..), UserId (..))
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
  it "signals each killed task only once while its finalizer is still running" $ do
    registry <- newTaskRegistry
    turn <- beginTurnRuntime registry (reference 1) gid alice Nothing
    signals <- newIORef (0 :: Int)
    _ <- activateTurnRuntime turn "working" (modifyIORef' signals (+ 1))
    cancelAllTasks registry `shouldReturn` 1
    cancelAllTasks registry `shouldReturn` 1
    cancelTask registry (turnRuntimeTaskId turn) `shouldReturn` True
    readIORef signals `shouldReturn` 1

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
