-- |
-- Four things worth pinning down, none of them visible in a type:
-- that anyone may feed a running turn (the owner gate is gone), that
-- @!feedback@ can aim at a specific turn via its trigger, that a
-- dispatch counts as in-flight from entry rather than from the moment
-- its agent loop starts, and that a message swallowed as a supplement
-- stays counted as answered for as long as the turn that swallowed it
-- runs.  The last one is what stops the A-then-B case (two people
-- asking before either gets an answer) from answering one of them
-- twice.
module Max.TasksSpec (spec) where

import Control.Concurrent (threadDelay)
import Data.Set qualified as Set
import Max.Tasks
  ( Note (..),
    TaskCancelled (..),
    TaskHandle (..),
    TaskInfo (..),
    TurnCompletion (..),
    activateTurnRuntime,
    absorbedTriggers,
    attachTask,
    beginDispatch,
    beginDurableTurnRuntime,
    beginTurnRuntime,
    checkTurnCancellation,
    drainTurnInbox,
    drainInbox,
    endDispatch,
    cancelTask,
    finishTurnRuntime,
    inFlightTriggers,
    listTasks,
    newTaskRegistry,
    pushToLatest,
    pushToAgentTurn,
    pushToTrigger,
    requeueInbox,
    setTurnPhase,
    turnRuntimeTaskId,
  )
import Max.Platform.Types (CanonicalMessageId (..))
import Max.Turn.Types (AgentTurnId (..), AgentTurnRef (..), TurnOrdinal (..))
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec

gid :: GroupId
gid = GroupId 100

alice, bob :: UserId
alice = UserId 1
bob = UserId 2

spec :: Spec
spec = describe "Max.Tasks" $ do
  describe "explicit TurnRuntime" $ do
    it "owns visibility, phase, feedback and finalization without trigger lookup" $ do
      reg <- newTaskRegistry
      turn <- beginTurnRuntime reg gid alice (Just (CanonicalMessageId 7001))
      starting <- listTasks reg (Just gid)
      map tiKind starting `shouldBe` ["starting"]
      preKilled <- activateTurnRuntime turn "llm" (pure ())
      preKilled `shouldBe` False
      setTurnPhase turn "tools"
      running <- listTasks reg (Just gid)
      map tiKind running `shouldBe` ["tools"]
      _ <- pushToLatest reg gid Nothing (Just 7002) (Note "改成 B" Nothing)
      notes <- drainTurnInbox turn
      map (.noteLine) notes `shouldBe` ["改成 B"]
      completion <- finishTurnRuntime reg turn
      completion.tcAbsorbedTriggers `shouldBe` Set.singleton 7002
      map (.noteLine) completion.tcUnservedNotes `shouldBe` []
      (null <$> listTasks reg (Just gid)) `shouldReturn` True

    it "carries a pre-activation kill and exposes a cancellation checkpoint" $ do
      reg <- newTaskRegistry
      turn <- beginTurnRuntime reg gid alice (Just (CanonicalMessageId 7001))
      accepted <- cancelTask reg (turnRuntimeTaskId turn)
      preKilled <- activateTurnRuntime turn "llm" (pure ())
      (accepted, preKilled) `shouldBe` (True, True)
      checkTurnCancellation turn `shouldThrow` (\TaskCancelled -> True)
      completion <- finishTurnRuntime reg turn
      map (.noteLine) completion.tcUnservedNotes `shouldBe` []

  describe "pushToLatest" $ do
    it "lets anyone feed a running turn, not just whoever started it" $ do
      reg <- newTaskRegistry
      _ <- beginDispatch reg gid alice (Just (CanonicalMessageId 7001))
      h <- attachTask reg gid alice (Just (CanonicalMessageId 7001)) "llm" (pure ())
      landed <- pushToLatest reg gid Nothing Nothing (Note "我也问一句" Nothing)
      notes <- drainInbox h
      (landed, map (.noteLine) notes) `shouldBe` (Just h.thId, ["我也问一句"])

    it "returns Nothing when the group has nothing running" $ do
      reg <- newTaskRegistry
      landed <- pushToLatest reg gid Nothing Nothing (Note "喂" Nothing)
      landed `shouldBe` Nothing

    it "picks the newest turn when several are running" $ do
      reg <- newTaskRegistry
      _ <- beginDispatch reg gid alice (Just (CanonicalMessageId 7001))
      h1 <- attachTask reg gid alice (Just (CanonicalMessageId 7001)) "llm" (pure ())
      -- Ordering is by start time, so the two must not share a
      -- timestamp; a real pair of dispatches never would.
      threadDelay 2000
      _ <- beginDispatch reg gid bob (Just (CanonicalMessageId 7002))
      h2 <- attachTask reg gid bob (Just (CanonicalMessageId 7002)) "llm" (pure ())
      _ <- pushToLatest reg gid Nothing Nothing (Note "给第二个" Nothing)
      n1 <- drainInbox h1
      n2 <- drainInbox h2
      (map (.noteLine) n1, map (.noteLine) n2) `shouldBe` ([], ["给第二个"])

    -- A dispatch asking "is anybody else working?" registered itself on
    -- the way in.  Without the exclusion it would inject into its own
    -- inbox and then drop the note when it exits.
    it "skips the caller's own entry" $ do
      reg <- newTaskRegistry
      mine <- beginDispatch reg gid alice (Just (CanonicalMessageId 7001))
      landed <- pushToLatest reg gid (Just mine) Nothing (Note "别给我自己" Nothing)
      landed `shouldBe` Nothing

    it "keeps groups apart" $ do
      reg <- newTaskRegistry
      _ <- beginDispatch reg (GroupId 999) alice (Just (CanonicalMessageId 7001))
      landed <- pushToLatest reg gid Nothing Nothing (Note "喂" Nothing)
      landed `shouldBe` Nothing

  describe "pushToTrigger" $ do
    it "aims at the replied-to turn rather than the newest" $ do
      reg <- newTaskRegistry
      _ <- beginDispatch reg gid alice (Just (CanonicalMessageId 7001))
      h1 <- attachTask reg gid alice (Just (CanonicalMessageId 7001)) "llm" (pure ())
      threadDelay 2000
      _ <- beginDispatch reg gid bob (Just (CanonicalMessageId 7002))
      h2 <- attachTask reg gid bob (Just (CanonicalMessageId 7002)) "llm" (pure ())
      landed <- pushToTrigger reg gid Nothing Nothing 7001 (Note "给第一个" Nothing)
      n1 <- drainInbox h1
      n2 <- drainInbox h2
      (landed, map (.noteLine) n1, map (.noteLine) n2) `shouldBe` (Just h1.thId, ["给第一个"], [])

    -- Replying to your own message after it got swallowed as a
    -- supplement should still reach the turn now carrying it.
    it "matches a message the turn absorbed" $ do
      reg <- newTaskRegistry
      _ <- beginDispatch reg gid alice (Just (CanonicalMessageId 7001))
      h <- attachTask reg gid alice (Just (CanonicalMessageId 7001)) "llm" (pure ())
      _ <- pushToLatest reg gid Nothing (Just 7002) (Note "[#7002] bob: 顺便" Nothing)
      _ <- drainInbox h
      landed <- pushToTrigger reg gid Nothing Nothing 7002 (Note "再补一句" Nothing)
      notes <- drainInbox h
      (landed, map (.noteLine) notes) `shouldBe` (Just h.thId, ["再补一句"])

    -- A !feedback message records as chat (verb stripped), so it is a
    -- visible question whose answer is threaded at somebody else's
    -- message.  Marking it absorbed is what stops a concurrent dispatch
    -- from answering it a second time.
    it "marks the note's own message absorbed by the turn that took it" $ do
      reg <- newTaskRegistry
      _ <- beginDispatch reg gid alice (Just (CanonicalMessageId 7001))
      _ <- attachTask reg gid alice (Just (CanonicalMessageId 7001)) "llm" (pure ())
      landed <- pushToTrigger reg gid Nothing (Just 7050) 7001 (Note "改成 B 方案" Nothing)
      inflight <- inFlightTriggers reg gid
      landed `shouldSatisfy` (/= Nothing)
      inflight `shouldBe` Set.fromList [7001, 7050]

    -- Callers fall back to pushToLatest rather than reporting an
    -- error: a note that refuses to land ends up in nobody's context.
    it "returns Nothing for a message no live turn owns" $ do
      reg <- newTaskRegistry
      _ <- beginDispatch reg gid alice (Just (CanonicalMessageId 7001))
      _ <- attachTask reg gid alice (Just (CanonicalMessageId 7001)) "llm" (pure ())
      landed <- pushToTrigger reg gid Nothing Nothing 9999 (Note "点错了" Nothing)
      landed `shouldBe` Nothing

  describe "pushToAgentTurn" $ do
    it "steers the exact durable producer instead of the newest runtime" $ do
      reg <- newTaskRegistry
      let first = AgentTurnRef (AgentTurnId 41) (TurnOrdinal 4)
          second = AgentTurnRef (AgentTurnId 42) (TurnOrdinal 5)
      firstRuntime <- beginDurableTurnRuntime reg first gid alice (Just (CanonicalMessageId 7001))
      threadDelay 2000
      secondRuntime <- beginDurableTurnRuntime reg second gid bob (Just (CanonicalMessageId 7002))
      landed <- pushToAgentTurn reg gid Nothing (Just 7050) first (Note "续第一项" Nothing)
      firstNotes <- drainTurnInbox firstRuntime
      secondNotes <- drainTurnInbox secondRuntime
      inflight <- inFlightTriggers reg gid
      (landed, map (.noteLine) firstNotes, map (.noteLine) secondNotes)
        `shouldBe` (Just (turnRuntimeTaskId firstRuntime), ["续第一项"], [])
      inflight `shouldBe` Set.fromList [7001, 7002, 7050]

    it "does not cross groups even when handed the same durable ref" $ do
      reg <- newTaskRegistry
      let durable = AgentTurnRef (AgentTurnId 41) (TurnOrdinal 4)
      _ <- beginDurableTurnRuntime reg durable (GroupId 999) alice (Just (CanonicalMessageId 7001))
      pushToAgentTurn reg gid Nothing Nothing durable (Note "wrong scope" Nothing)
        `shouldReturn` Nothing

  describe "dispatch tracking" $ do
    it "reports a trigger from entry until release" $ do
      reg <- newTaskRegistry
      atStart <- inFlightTriggers reg gid
      tid <- beginDispatch reg gid alice (Just (CanonicalMessageId 7001))
      during <- inFlightTriggers reg gid
      _ <- endDispatch reg tid
      atEnd <- inFlightTriggers reg gid
      (atStart, during, atEnd)
        `shouldBe` (Set.empty, Set.fromList [7001], Set.empty)

    -- Why the entry is opened at dispatch entry and not by the agent
    -- loop: buildContext runs long before the loop exists, and that gap
    -- is exactly when the second person asks — and when someone runs
    -- !ps wondering why nothing is happening.
    it "is visible to !ps before its agent loop starts" $ do
      reg <- newTaskRegistry
      _ <- beginDispatch reg gid alice (Just (CanonicalMessageId 7001))
      tasks <- listTasks reg (Just gid)
      map tiKind tasks `shouldBe` ["starting"]

    it "tracks concurrent triggers independently" $ do
      reg <- newTaskRegistry
      t1 <- beginDispatch reg gid alice (Just (CanonicalMessageId 7001))
      _ <- beginDispatch reg gid bob (Just (CanonicalMessageId 7002))
      _ <- endDispatch reg t1
      inflight <- inFlightTriggers reg gid
      inflight `shouldBe` Set.fromList [7002]

    it "keeps groups apart" $ do
      reg <- newTaskRegistry
      _ <- beginDispatch reg gid alice (Just (CanonicalMessageId 7001))
      elsewhere <- inFlightTriggers reg (GroupId 999)
      elsewhere `shouldBe` Set.empty

    -- Every poke shares MessageId 0 as its "no trigger" sentinel, so
    -- treating it as a real id would make two of them indistinguishable
    -- and mark a message id nobody has as answered.
    it "treats a poke's sentinel message id as no trigger" $ do
      reg <- newTaskRegistry
      _ <- beginDispatch reg gid alice (Just (CanonicalMessageId 0))
      inflight <- inFlightTriggers reg gid
      inflight `shouldBe` Set.empty

    -- The regression the split was for: the dispatch that got absorbed
    -- ends immediately, but its question is still being answered by
    -- somebody else's turn.  If it stopped counting as in-flight here,
    -- the next dispatch would answer it a second time.
    -- The dispatch epilogue reads this to take the 托腮 reaction back
    -- off every note the turn swallowed — so it must list exactly the
    -- absorbed mids, and only while the entry still exists.
    it "lists a turn's absorbed messages until the turn ends" $ do
      reg <- newTaskRegistry
      tid <- beginDispatch reg gid alice (Just (CanonicalMessageId 7001))
      _ <- pushToLatest reg gid Nothing (Just 7002) (Note "[#7002] bob: 顺便" Nothing)
      beforeMids <- absorbedTriggers reg tid
      _ <- endDispatch reg tid
      afterMids <- absorbedTriggers reg tid
      (beforeMids, afterMids) `shouldBe` ([7002], [])

    it "keeps an absorbed message in flight after its own entry ends" $ do
      reg <- newTaskRegistry
      _ <- beginDispatch reg gid alice (Just (CanonicalMessageId 7001))
      _ <- attachTask reg gid alice (Just (CanonicalMessageId 7001)) "llm" (pure ())
      absorbed <- beginDispatch reg gid bob (Just (CanonicalMessageId 7002))
      _ <- pushToLatest reg gid (Just absorbed) (Just 7002) (Note "[#7002] bob: 顺便" Nothing)
      _ <- endDispatch reg absorbed
      inflight <- inFlightTriggers reg gid
      inflight `shouldBe` Set.fromList [7001, 7002]

  -- The invariant behind the unserved-note recovery: a note leaves
  -- the inbox only by entering the conversation; what stays behind
  -- surfaces exactly once, at endDispatch — unless the turn was
  -- killed, in which case the notes die with it by contract.
  describe "unserved notes" $ do
    it "endDispatch returns what nobody drained" $ do
      reg <- newTaskRegistry
      tid <- beginDispatch reg gid alice (Just (CanonicalMessageId 7001))
      _ <- pushToLatest reg gid Nothing Nothing (Note "改成 B" Nothing)
      notes <- endDispatch reg tid
      map (.noteLine) notes `shouldBe` ["改成 B"]

    it "returns nothing when the loop drained everything" $ do
      reg <- newTaskRegistry
      tid <- beginDispatch reg gid alice (Just (CanonicalMessageId 7001))
      h <- attachTask reg gid alice (Just (CanonicalMessageId 7001)) "llm" (pure ())
      _ <- pushToLatest reg gid Nothing Nothing (Note "改成 B" Nothing)
      _ <- drainInbox h
      notes <- endDispatch reg tid
      map (.noteLine) notes `shouldBe` []

    it "a killed turn takes its notes with it" $ do
      reg <- newTaskRegistry
      tid <- beginDispatch reg gid alice (Just (CanonicalMessageId 7001))
      _ <- attachTask reg gid alice (Just (CanonicalMessageId 7001)) "llm" (pure ())
      _ <- pushToLatest reg gid Nothing Nothing (Note "改成 B" Nothing)
      _ <- cancelTask reg tid
      notes <- endDispatch reg tid
      map (.noteLine) notes `shouldBe` []

    it "requeued notes keep their order, ahead of later arrivals" $ do
      reg <- newTaskRegistry
      _ <- beginDispatch reg gid alice (Just (CanonicalMessageId 7001))
      h <- attachTask reg gid alice (Just (CanonicalMessageId 7001)) "llm" (pure ())
      _ <- pushToLatest reg gid Nothing Nothing (Note "一" Nothing)
      _ <- pushToLatest reg gid Nothing Nothing (Note "二" Nothing)
      drained <- drainInbox h
      _ <- pushToLatest reg gid Nothing Nothing (Note "三" Nothing)
      requeueInbox h drained
      notes <- drainInbox h
      map (.noteLine) notes `shouldBe` ["一", "二", "三"]

  describe "attachTask" $ do
    it "adopts the entry beginDispatch opened instead of adding one" $ do
      reg <- newTaskRegistry
      tid <- beginDispatch reg gid alice (Just (CanonicalMessageId 7001))
      h <- attachTask reg gid alice (Just (CanonicalMessageId 7001)) "llm" (pure ())
      tasks <- listTasks reg (Just gid)
      (h.thId, h.thOwned, length tasks, map tiKind tasks)
        `shouldBe` (tid, False, 1, ["llm"])

    -- Notes can arrive during the prologue, before there is a loop to
    -- read them.  They go into the entry's inbox and the loop, having
    -- adopted that same entry, picks them up on its first round.
    it "inherits notes pushed before the loop existed" $ do
      reg <- newTaskRegistry
      _ <- beginDispatch reg gid alice (Just (CanonicalMessageId 7001))
      _ <- pushToLatest reg gid Nothing Nothing (Note "等一下，改成 B" Nothing)
      h <- attachTask reg gid alice (Just (CanonicalMessageId 7001)) "llm" (pure ())
      notes <- drainInbox h
      map (.noteLine) notes `shouldBe` ["等一下，改成 B"]

    -- !kill during the prologue has no thread to interrupt yet.  The
    -- registry accepts it (telling the user the truth) and hands it to
    -- the loop, which dies before doing a turn's worth of work.
    it "carries a kill that landed before the loop started" $ do
      reg <- newTaskRegistry
      tid <- beginDispatch reg gid alice (Just (CanonicalMessageId 7001))
      accepted <- cancelTask reg tid
      h <- attachTask reg gid alice (Just (CanonicalMessageId 7001)) "llm" (pure ())
      (accepted, h.thPreKilled) `shouldBe` (True, True)

    it "creates its own entry when no dispatch opened one" $ do
      reg <- newTaskRegistry
      h <- attachTask reg gid alice (Just (CanonicalMessageId 7001)) "llm" (pure ())
      tasks <- listTasks reg (Just gid)
      (h.thOwned, length tasks) `shouldBe` (True, 1)
