-- |
-- Two things worth pinning down: that steering a turn is scoped to
-- whoever started it, and that a dispatch counts as in-flight from
-- entry rather than from 'registerTask'.  Both are load-bearing for
-- the A-then-B case (two people asking before either gets an answer)
-- and neither is visible in a type.
module Max.TasksSpec (spec) where

import Control.Concurrent (threadDelay)
import Data.Set qualified as Set
import Max.Tasks
  ( beginDispatch,
    drainBtwInbox,
    endDispatch,
    inFlightTriggers,
    listTasks,
    newTaskRegistry,
    pushBtwToOwnTask,
    registerTask,
  )
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))
import Test.Hspec

gid :: GroupId
gid = GroupId 100

alice, bob :: UserId
alice = UserId 1
bob = UserId 2

spec :: Spec
spec = describe "Max.Tasks" $ do
  describe "pushBtwToOwnTask" $ do
    it "steers your own running turn" $ do
      reg <- newTaskRegistry
      h <- registerTask reg gid alice "llm" (pure ())
      ok <- pushBtwToOwnTask reg gid alice "追加要求"
      notes <- drainBtwInbox h
      (ok, notes) `shouldBe` (True, ["追加要求"])

    -- The whole point of owner scoping: Bob's words must not end up
    -- steering a turn whose reply is threaded at Alice's message.
    it "refuses somebody else's turn even though the group is busy" $ do
      reg <- newTaskRegistry
      h <- registerTask reg gid alice "llm" (pure ())
      ok <- pushBtwToOwnTask reg gid bob "我也问一句"
      notes <- drainBtwInbox h
      (ok, notes) `shouldBe` (False, [])

    it "refuses when the group is idle" $ do
      reg <- newTaskRegistry
      ok <- pushBtwToOwnTask reg gid alice "喂"
      ok `shouldBe` False

    it "picks your latest turn when you have more than one" $ do
      reg <- newTaskRegistry
      h1 <- registerTask reg gid alice "llm" (pure ())
      -- Ordering is by start time, so the two must not share a
      -- timestamp; a real pair of dispatches never would.
      threadDelay 2000
      h2 <- registerTask reg gid alice "llm" (pure ())
      _ <- pushBtwToOwnTask reg gid alice "给第二个"
      n1 <- drainBtwInbox h1
      n2 <- drainBtwInbox h2
      (n1, n2) `shouldBe` ([], ["给第二个"])

    it "ignores a task of yours in another group" $ do
      reg <- newTaskRegistry
      h <- registerTask reg (GroupId 999) alice "llm" (pure ())
      ok <- pushBtwToOwnTask reg gid alice "喂"
      notes <- drainBtwInbox h
      (ok, notes) `shouldBe` (False, [])

  describe "dispatch tracking" $ do
    it "reports a trigger from entry until release" $ do
      reg <- newTaskRegistry
      atStart <- inFlightTriggers reg gid
      beginDispatch reg gid (MessageId 7001)
      during <- inFlightTriggers reg gid
      endDispatch reg gid (MessageId 7001)
      atEnd <- inFlightTriggers reg gid
      (atStart, during, atEnd)
        `shouldBe` (Set.empty, Set.fromList [7001], Set.empty)

    -- Why this can't just read the task map: buildContext runs long
    -- before registerTask, and that gap is exactly when the second
    -- person asks.
    it "reports a trigger that has no task registered yet" $ do
      reg <- newTaskRegistry
      beginDispatch reg gid (MessageId 7001)
      tasks <- listTasks reg (Just gid)
      inflight <- inFlightTriggers reg gid
      (length tasks, inflight) `shouldBe` (0, Set.fromList [7001])

    it "tracks concurrent triggers independently" $ do
      reg <- newTaskRegistry
      beginDispatch reg gid (MessageId 7001)
      beginDispatch reg gid (MessageId 7002)
      endDispatch reg gid (MessageId 7001)
      inflight <- inFlightTriggers reg gid
      inflight `shouldBe` Set.fromList [7002]

    it "keeps groups apart" $ do
      reg <- newTaskRegistry
      beginDispatch reg gid (MessageId 7001)
      elsewhere <- inFlightTriggers reg (GroupId 999)
      elsewhere `shouldBe` Set.empty
