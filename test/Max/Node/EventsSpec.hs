module Max.Node.EventsSpec (spec) where

import Control.Concurrent.Async (concurrently)
import Control.Concurrent.STM
import Control.Monad (replicateM, replicateM_)
import Data.Aeson (Value (String), encode)
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Max.Context.Projection qualified as Projection
import Max.LLM.Types (ChatMessage (MsgUser))
import Max.Node.Events
import Max.Node.Log qualified as Log
import Max.Task.Types (JobRun (..))
import Test.Hspec

spec :: Spec
spec = describe "node event delivery and observation" $ do
  it "records one immutable trigger and keeps its reference valid in a frozen snapshot after retirement" $ do
    task <- atomically (newNode >>= \node -> newTaskFrom node (Log.Said Nothing))
    Just reference <- atomically (taskTrigger task)
    snapshot <- atomically (readObservations task)
    Log.triggerAt reference snapshot `shouldBe` Just (Log.Said Nothing)
    atomically (startTask task (Log.Said Nothing)) `shouldReturn` Nothing
    atomically (observeAll task) `shouldReturn` []
    atomically (close task)
    atomically (taskTrigger task) `shouldReturn` Nothing
    retired <- atomically (readObservations task)
    Log.triggerAt reference retired `shouldBe` Nothing
    Log.triggerAt reference snapshot `shouldBe` Just (Log.Said Nothing)

  it "isolates tasks on one node while assigning a shared event order" $ do
    (first, second) <- atomically $ do
      node <- newNode
      (,) <$> newTask node <*> newTask node
    atomically (deliver first (Steered (String "first"))) `shouldReturn` True
    atomically (deliver second (Steered (String "second"))) `shouldReturn` True
    left <- atomically (observe first)
    right <- atomically (observe second)
    map (.body) left `shouldBe` [Steered (String "first")]
    map (.body) right `shouldBe` [Steered (String "second")]
    map (.sequence) left `shouldSatisfy` (< map (.sequence) right)
    atomically (observe first) `shouldReturn` []

  it "shares immutable observation snapshots and retires only the closing task without moving cursors" $ do
    (first, second) <- atomically $ do
      node <- newNode
      (,) <$> newTask node <*> newTask node
    Just firstTrigger <- atomically (startTask first (Log.Said Nothing))
    Just secondTrigger <- atomically (startTask second (Log.Said Nothing))
    let firstRecord = Projection.newTaskRecord firstTrigger (Projection.logCursor Projection.emptyLog) []
        secondRecord = Projection.newTaskRecord secondTrigger (Projection.logCursor Projection.emptyLog) []
        visible snapshot record = encode (Projection.project snapshot record (Projection.logCursor snapshot))
    _ <- atomically (appendObservation first [MsgUser "first private evidence"])
    _ <- atomically (appendObservation second [MsgUser "second private evidence"])
    snapshot <- atomically (readObservations first)
    sameSnapshot <- atomically (readObservations second)
    visible snapshot secondRecord `shouldBe` visible sameSnapshot secondRecord
    visible snapshot firstRecord `shouldBe` encode [MsgUser "first private evidence"]
    visible snapshot secondRecord `shouldBe` encode [MsgUser "second private evidence"]
    atomically (close first)
    retired <- atomically (readObservations second)
    Projection.logCursor retired `shouldBe` Projection.logCursor snapshot
    visible retired secondRecord `shouldBe` visible snapshot secondRecord
    visible retired firstRecord `shouldBe` encode ([] :: [ChatMessage])
    visible snapshot firstRecord `shouldBe` encode [MsgUser "first private evidence"]
    atomically (isNothing <$> appendObservation first [MsgUser "resurrection"]) `shouldReturn` True
    Just later <- atomically (appendObservation second [MsgUser "later second evidence"])
    Projection.logCursor later `shouldSatisfy` (> Projection.logCursor retired)
    visible later secondRecord `shouldBe` encode [MsgUser "second private evidence", MsgUser "later second evidence"]

  it "refuses new observations as soon as a terminal control revokes the task" $ do
    task <- atomically (newNode >>= newTask)
    _ <- atomically (appendObservation task [MsgUser "before cancellation"])
    atomically (deliver task Cancelled) `shouldReturn` True
    atomically (isNothing <$> appendObservation task [MsgUser "after cancellation"]) `shouldReturn` True

  it "acknowledges only frozen receipts while late steering still fences completion" $ do
    (task, other) <- atomically $ do
      node <- newNode
      (,) <$> newTask node <*> newTask node
    atomically (deliver task (ChildSaid (JobRun 7 1) "observed note" Normal)) `shouldReturn` True
    frozen <- atomically (peekAll task)
    atomically (deliver task (Steered (String "late correction"))) `shouldReturn` True
    atomically (deliver other (Steered (String "other task"))) `shouldReturn` True
    foreignEvents <- atomically (peekAll other)
    -- Even an unrelated receipt in the supplied cut cannot acknowledge it.
    observed <- atomically (observeAt task (Set.fromList (map (.sequence) (frozen <> foreignEvents))))
    observed `shouldBe` frozen
    atomically (hasInterrupt task noPending) `shouldReturn` True
    atomically (tryFinish task) `shouldReturn` False
    map (.body) <$> atomically (observe task) `shouldReturn` [Steered (String "late correction")]
    atomically (tryFinish task) `shouldReturn` True
    atomically (observe other) `shouldReturn` foreignEvents

  it "uses the same wake rule for messages, steering and selected completions" $ do
    let child = JobRun 7 1
        awaiting = Pending (Set.singleton "r1") (Set.singleton child)
    wakes awaiting (Steered (String "stop")) `shouldBe` True
    wakes awaiting (ChildSaid child "question" Urgent) `shouldBe` True
    wakes awaiting (ChildSaid child "note" Normal) `shouldBe` False
    wakes awaiting (ChildDone child (String "report")) `shouldBe` True
    wakes noPending (ChildDone child (String "report")) `shouldBe` False
    wakes awaiting (Settled "r1" (String "done") []) `shouldBe` True
    wakes awaiting (Settled "r2" (String "unrelated") []) `shouldBe` False
    wakes awaiting (Replaced "new goal") `shouldBe` True
    wakes awaiting Cancelled `shouldBe` True

  it "never accepts an interrupt on the far side of a successful final answer" $ do
    replicateM_ 200 $ do
      task <- atomically (newNode >>= newTask)
      (accepted, finished) <- concurrently (atomically (deliver task (Steered (String "race")))) (atomically (tryFinish task))
      (accepted, finished) `shouldSatisfy` (`elem` [(True, False), (False, True)])
      if accepted
        then do
          atomically (tryFinish task) `shouldReturn` False
          _ <- atomically (observe task)
          atomically (tryFinish task) `shouldReturn` True
        else atomically (observe task) `shouldReturn` []
      atomically (deliver task (Steered (String "late"))) `shouldReturn` False

  it "bounds each task to 256 buffered events and observes at most 200 per poll" $ do
    (task, other) <- atomically $ do
      node <- newNode
      (,) <$> newTask node <*> newTask node
    atomically (replicateM 255 (deliver task (Steered (String "input")))) `shouldReturn` replicate 255 True
    atomically (deliver task (Steered (String "overflow"))) `shouldReturn` False
    atomically (deliver other (Steered (String "other"))) `shouldReturn` True
    length <$> atomically (observe task) `shouldReturn` 200
    atomically (tryFinish task) `shouldReturn` False
    length <$> atomically (observe task) `shouldReturn` 55
    atomically (tryFinish task) `shouldReturn` True
    length <$> atomically (observe other) `shouldReturn` 1

  it "accepts one terminal control even with a full data buffer and permanently fences finish" $ do
    task <- atomically (newNode >>= newTask)
    atomically (replicateM 255 (deliver task (Steered (String "queued")))) `shouldReturn` replicate 255 True
    atomically (deliver task (Replaced "new goal")) `shouldReturn` True
    atomically (isOpen task) `shouldReturn` False
    atomically (deliver task Cancelled) `shouldReturn` False
    atomically (deliver task (Steered (String "late"))) `shouldReturn` False
    events <- atomically (observeAll task)
    length events `shouldBe` 256
    map (.body) (drop 255 events) `shouldBe` [Replaced "new goal"]
    atomically (tryFinish task) `shouldReturn` False

  it "revokes a finished task while refusing controls after its log is retired" $ do
    task <- atomically (newNode >>= newTask)
    atomically (tryFinish task) `shouldReturn` True
    atomically (deliver task Cancelled) `shouldReturn` True
    atomically (hasInterrupt task noPending) `shouldReturn` True
    atomically (close task)
    atomically (deliver task Cancelled) `shouldReturn` False

  it "buffers non-urgent messages without interrupting a final answer" $ do
    task <- atomically (newNode >>= newTask)
    atomically (deliver task (ChildSaid (JobRun 7 1) "status note" Normal)) `shouldReturn` True
    atomically (hasInterrupt task noPending) `shouldReturn` False
    atomically (tryFinish task) `shouldReturn` True
    length <$> atomically (observe task) `shouldReturn` 1

  it "retiring one task does not discard another task's events" $ do
    (task, other) <- atomically $ do
      node <- newNode
      (,) <$> newTask node <*> newTask node
    _ <- atomically (deliver task Cancelled >> deliver other (Steered (String "keep")))
    atomically (close task)
    atomically (isOpen task) `shouldReturn` False
    atomically (observe task) `shouldReturn` []
    length <$> atomically (observe other) `shouldReturn` 1
