module Max.Node.EventsSpec (spec) where

import Control.Concurrent.Async (concurrently)
import Control.Concurrent.STM
import Control.Monad (replicateM, replicateM_)
import Data.Aeson (Value (String))
import Data.Set qualified as Set
import Max.Node.Events
import Max.Task.Types (JobRun (..))
import Test.Hspec

spec :: Spec
spec = describe "node event delivery and observation" $ do
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

  it "uses the same wake rule for messages, steering and selected completions" $ do
    let child = JobRun 7 1
        awaiting = Pending (Set.singleton "r1") (Set.singleton child)
    wakes awaiting (Steered (String "stop")) `shouldBe` True
    wakes awaiting (ChildSaid child "question" Urgent) `shouldBe` True
    wakes awaiting (ChildSaid child "note" Normal) `shouldBe` False
    wakes awaiting (ChildDone child (String "report")) `shouldBe` True
    wakes noPending (ChildDone child (String "report")) `shouldBe` False
    wakes awaiting (Settled "r1" (String "done")) `shouldBe` True
    wakes awaiting (Settled "r2" (String "unrelated")) `shouldBe` False
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
    atomically (replicateM 256 (deliver task (Steered (String "input")))) `shouldReturn` replicate 256 True
    atomically (deliver task (Steered (String "overflow"))) `shouldReturn` False
    atomically (deliver other (Steered (String "other"))) `shouldReturn` True
    length <$> atomically (observe task) `shouldReturn` 200
    atomically (tryFinish task) `shouldReturn` False
    length <$> atomically (observe task) `shouldReturn` 56
    atomically (tryFinish task) `shouldReturn` True
    length <$> atomically (observe other) `shouldReturn` 1

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
