module Max.JobsSpec (Max.JobsSpec.spec) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async (cancel, concurrently, mapConcurrently, poll, wait, waitCatch, waitCatchSTM, withAsync)
import Control.Concurrent.STM (STM, atomically, check, retry)
import Control.Monad (foldM, forM_, replicateM, replicateM_, void)
import Data.Aeson (Value (..), object, (.=))
import Data.ByteString qualified as BS
import Data.Either (isLeft, isRight)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, isJust, isNothing)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (addUTCTime, getCurrentTime)
import Max.Execution.Types (Admission (..), ExecutionStep (..), StepReservation (..))
import Max.Jobs
import Max.Jobs qualified as Jobs
import Max.LLM.Types (CallCost (..), TokenUsage (..))
import Max.Monitor.Types (MonitorFireId (..), MonitorId (..))
import Max.Node.Events qualified as Events
import Max.Node.Log qualified as NodeLog
import Max.Node.Render (renderEvents)
import Max.Node.Router qualified as Router
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..), noAdvertisedCaps)
import Max.Task.Delegation (parseJobResult)
import Max.Task.Policy (treeModelRounds, treeToolCalls)
import Max.Task.State
import Max.Task.Types (JobMonitor (..), JobUsage (..), TaskProfile (..), jobReportText, jobUsageLine)
import Max.Tasks
import Max.ToolContext qualified as TC
import Max.Turn.Types
import NodeWorkFixture qualified
import OneBot.Types (GroupId (..), UserId (..))
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "process-owned Jobs" $ do
  it "drains router receipts without first claiming queued launches" $ do
    (_, jobs, request) <- fixture
    Right queued <- admitJob jobs Nothing 1 request
    Right reported <- admitJob jobs Nothing 2 request
    completeJob jobs reported.run Succeeded (JobResult "report ready" Nothing)
    Just (Router.JobReport relay) <- timeout 1000000 (NodeWorkFixture.takeDelivery jobs)
    relay.job.run `shouldBe` reported.run
    lookupJob jobs request.group 1 `shouldReturn` Just queued
    claimed <- atomically (Jobs.claimReadyJob jobs)
    claimed.run `shouldBe` queued.run
    atomically (Router.releaseReport jobs.resultRouter relay)

  it "launches unrelated work while a monitor receipt is claimed and blocks its next occurrence until acknowledgement" $ do
    (_, jobs, request) <- fixture
    let monitor fire = request {monitor = Just (JobMonitor (MonitorId 10) (MonitorFireId fire))}
    Right first <- admitJob jobs Nothing 1 (monitor 1)
    completeJob jobs first.run Succeeded (JobResult "waiting on storage" Nothing)
    Just (Router.MonitorCompleted receipt) <- timeout 1000000 (NodeWorkFixture.takeDelivery jobs)
    Right _ <- admitJob jobs Nothing 2 (monitor 2)
    Right unrelated <- admitJob jobs Nothing 3 request
    claimed <- atomically (Jobs.claimReadyJob jobs)
    claimed.run `shouldBe` unrelated.run
    timeout 20000 (atomically (Jobs.claimReadyJob jobs)) `shouldReturn` Nothing
    atomically (Router.releaseMonitorResult jobs.resultRouter receipt)
    next <- atomically (Jobs.claimReadyJob jobs)
    next.run.jobId `shouldBe` 2

  it "binds a fired occurrence and queued steering to the actual root runtime" $ do
    (tasks, jobs, request) <- fixture
    let frozen = request {objective = "saved goal", inputs = object ["goal" .= ("untrusted replacement" :: T.Text)], monitor = Just (JobMonitor (MonitorId 10) (MonitorFireId 1))}
    Right _ <- admitJob jobs Nothing 1 frozen
    Left job <- takeWork jobs
    steerJob jobs request.group request.principal Nothing 1 "queued correction" `shouldReturn` Right ()
    runtime <- beginTurnRuntime tasks (reference 1) request.group (UserId 7) Nothing
    target <- atomically (Events.newNode >>= Events.newTask)
    atomically (attachAutomationTurn jobs job.run (reference 1) target) `shouldReturn` True
    -- Dispatch binds this same conversation log after acquiring its root slot.
    atomically (bindTurnEvents tasks (AgentTurnId 1) target) `shouldReturn` True
    Just trigger <- atomically (Events.taskTrigger target)
    triggerLog <- atomically (Events.readObservations target)
    NodeLog.triggerAt trigger triggerLog `shouldBe` Just (NodeLog.Fired job.run job.spec)
    events <- atomically (turnEvents runtime >>= Router.observeEvents jobs.resultRouter)
    [occurrence] <- pure [occurrence | Events.Event {body = Events.Fired occurrence} <- events]
    occurrence.consumer `shouldBe` job.spec
    occurrence.run `shouldBe` job.run
    Events.wakes Events.noPending (Events.Fired occurrence) `shouldBe` False
    T.pack (show (renderEvents events)) `shouldSatisfy` T.isInfixOf "saved goal"
    T.pack (show (renderEvents events)) `shouldSatisfy` T.isInfixOf "queued correction"
    atomically (Events.observe target) `shouldReturn` []
    authorizeJobPublication jobs (AgentTurnId 1) `shouldReturn` True
    authorizeJobStep jobs (AgentTurnId 1) (ExecutionWork ReserveCall) `shouldReturn` True
    steerJob jobs request.group request.principal Nothing 1 "live correction" `shouldReturn` Right ()
    atomically (Events.hasInterrupt target Events.noPending) `shouldReturn` True
    cancelJob jobs request.group request.principal False 1 "cancel root automation" `shouldReturn` Right ()
    atomically (turnWasCancelled runtime) `shouldReturn` True
    authorizeJobPublication jobs (AgentTurnId 1) `shouldReturn` False
    authorizeJobStep jobs (AgentTurnId 1) (ExecutionWork ReserveCall) `shouldReturn` False

  it "rolls back a full root log handoff and never duplicates its Fired event on retry" $ do
    (tasks, jobs, request) <- fixture
    Right _ <- admitJob jobs Nothing 1 request {monitor = Just (JobMonitor (MonitorId 10) (MonitorFireId 1))}
    Left job <- takeWork jobs
    _ <- beginTurnRuntime tasks (reference 1) request.group (UserId 7) Nothing
    target <- atomically (Events.newNode >>= Events.newTask)
    atomically (replicateM_ 255 (Events.deliver target (Events.Steered Null)))
    steerJob jobs request.group request.principal Nothing 1 "preserved correction" `shouldReturn` Right ()
    atomically (attachAutomationTurn jobs job.run (reference 1) target) `shouldReturn` False
    atomically (Events.taskTrigger target) `shouldReturn` Nothing
    jobForTurn jobs (AgentTurnId 1) `shouldReturn` Nothing
    _ <- atomically (Events.observeAll target)
    atomically (attachAutomationTurn jobs job.run (reference 1) target) `shouldReturn` True
    atomically (attachAutomationTurn jobs job.run (reference 1) target) `shouldReturn` False
    events <- atomically (Events.observeAll target)
    length [() | Events.Event {body = Events.Fired _} <- events] `shouldBe` 1
    length events `shouldBe` 2
    T.pack (show (renderEvents events)) `shouldSatisfy` T.isInfixOf "preserved correction"

  it "rejects an automation handoff into a task created by a different trigger" $ do
    (tasks, jobs, request) <- fixture
    Right _ <- admitJob jobs Nothing 1 request {monitor = Just (JobMonitor (MonitorId 10) (MonitorFireId 1))}
    Left job <- takeWork jobs
    _ <- beginTurnRuntime tasks (reference 1) request.group (UserId 7) Nothing
    target <- atomically (Events.newNode >>= \node -> Events.newTaskFrom node (NodeLog.Said (Just request.source)))
    atomically (attachAutomationTurn jobs job.run (reference 1) target) `shouldReturn` False
    jobForTurn jobs (AgentTurnId 1) `shouldReturn` Nothing
    atomically (Events.observeAll target) `shouldReturn` []

  it "keeps each background generation's frozen admission trigger" $ do
    (tasks, jobs, request) <- fixture
    (original, oldRuntime) <- launch tasks jobs 1 request
    oldEvents <- atomically (turnEvents oldRuntime)
    Just oldRef <- atomically (Events.taskTrigger oldEvents)
    oldLog <- atomically (Events.readObservations oldEvents)
    replaceJob jobs request.group request.principal False 1 "replacement objective" `shouldReturn` Right ()
    finishTurnRuntime tasks oldRuntime
    detachJobTurn jobs original.run
    Left replacement <- takeWork jobs
    fresh <- beginTurnRuntime tasks (reference 2) request.group (UserId 7) Nothing
    attachJobTurn jobs replacement.run (reference 2) `shouldReturn` True
    target <- atomically (turnEvents fresh)
    Just currentRef <- atomically (Events.taskTrigger target)
    currentLog <- atomically (Events.readObservations target)
    NodeLog.triggerAt oldRef oldLog `shouldBe` Just (NodeLog.Spawned original.run original.spec)
    NodeLog.triggerAt currentRef currentLog `shouldBe` Just (NodeLog.Spawned replacement.run replacement.spec)
    replacement.spec.objective `shouldBe` "replacement objective"

  it "relays a child report delivered before its parent closes but not yet observed" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    (child, _) <- launch tasks jobs 2 (request {parent = Just root.run})
    let report = JobResult "child proof" (Just (object ["answer" .= (42 :: Int)]))
    completeJob jobs child.run Succeeded report
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing
    completeJob jobs root.run Succeeded (JobResult "parent finished" Nothing)
    Right (Router.JobReport childRelay) <- takeWork jobs
    Right (Router.JobReport parentRelay) <- takeWork jobs
    childRelay.job.run `shouldBe` child.run
    childRelay.job.result `shouldBe` Just report
    parentRelay.job.run `shouldBe` root.run
    atomically (Router.releaseReport jobs.resultRouter childRelay >> Router.releaseReport jobs.resultRouter parentRelay)
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing

  it "routes a root agent report to its starting frontend task until that task ends" $ do
    forM_ [False, True] $ \observed -> do
      (tasks, jobs, request) <- fixture
      caller <- beginTurnRuntime tasks (reference 99) request.group (UserId 7) Nothing
      target <- atomically (turnEvents caller)
      Right child <- admitJob jobs (Just (AgentTurnId 99)) 1 request
      Left _ <- takeWork jobs
      completeJob jobs child.run Succeeded (JobResult "frontend-owned report" Nothing)
      timeout 20000 (takeWork jobs) `shouldReturn` Nothing
      if observed
        then do
          events <- atomically (Router.observeEvents jobs.resultRouter target)
          map (\event -> case event.body of Events.ChildDone run _ -> Just run; _ -> Nothing) events `shouldBe` [Just child.run]
        else pure ()
      finishTurnRuntime tasks caller
      if observed
        then timeout 20000 (takeWork jobs) `shouldReturn` Nothing
        else do
          Right (Router.JobReport relay) <- takeWork jobs
          relay.job.run `shouldBe` child.run

  it "retains both reports when parent closure races child completion" $ do
    replicateM_ 20 $ do
      (tasks, jobs, request) <- fixture
      (root, _) <- launch tasks jobs 1 request
      (child, _) <- launch tasks jobs 2 (request {parent = Just root.run})
      _ <- concurrently (completeJob jobs child.run Succeeded (JobResult "child" Nothing)) (completeJob jobs root.run Succeeded (JobResult "parent" Nothing))
      Right (Router.JobReport first) <- takeWork jobs
      Right (Router.JobReport second) <- takeWork jobs
      Set.fromList [first.job.run, second.job.run] `shouldBe` Set.fromList [root.run, child.run]
      atomically (Router.releaseReport jobs.resultRouter first >> Router.releaseReport jobs.resultRouter second)
      timeout 1000 (takeWork jobs) `shouldReturn` Nothing

  it "does not relay a child report the parent already observed" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    (child, _) <- launch tasks jobs 2 (request {parent = Just root.run})
    completeJob jobs child.run Succeeded (JobResult "observed proof" Nothing)
    notes <- observeJobEvents jobs (AgentTurnId 1)
    length notes `shouldBe` 1
    completeJob jobs root.run Succeeded (JobResult "done" Nothing)
    Right (Router.JobReport relay) <- takeWork jobs
    relay.job.run `shouldBe` root.run
    atomically (Router.releaseReport jobs.resultRouter relay)
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing

  it "retains a report refused by the parent event buffer and relays it after closure" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    (child, _) <- launch tasks jobs 2 (request {parent = Just root.run})
    Just target <- atomically (jobEventTask jobs (AgentTurnId 1))
    atomically (replicateM_ 255 (Events.deliver target (Events.Steered Null)))
    timeout 1000000 (completeJob jobs child.run Succeeded (JobResult "backpressured proof" Nothing)) `shouldReturn` Just ()
    completeJob jobs root.run Succeeded (JobResult "done" Nothing)
    Right (Router.JobReport first) <- takeWork jobs
    Right (Router.JobReport second) <- takeWork jobs
    Set.fromList [first.job.run, second.job.run] `shouldBe` Set.fromList [root.run, child.run]
    atomically (Router.releaseReport jobs.resultRouter first >> Router.releaseReport jobs.resultRouter second)
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing

  it "keeps report source ownership while native results fill the shared router" $ do
    (tasks, jobs, request) <- fixture
    (root, runtime) <- launch tasks jobs 1 request
    (child, _) <- launch tasks jobs 2 (request {parent = Just root.run})
    let callContext =
          TC.mkToolContext
            (TC.TurnIdentity request.group request.source (UserId 7) (UserId 99) request.principal Nothing Nothing)
            (TC.TurnCapabilities False False False noAdvertisedCaps False Map.empty Nothing False)
    origin <- resultOrigin jobs runtime callContext
    atomically (Router.closeTask jobs.resultRouter origin.target)
    forM_ [1 .. 1024 :: Int] $ \n -> atomically (Router.deliverResult jobs.resultRouter origin (T.pack (show n)) Null [])
    timeout 1000000 (completeJob jobs child.run Succeeded (JobResult "retained child" Nothing)) `shouldReturn` Just ()
    timeout 1000000 (completeJob jobs root.run Succeeded (JobResult "retained parent" Nothing)) `shouldReturn` Just ()
    replicateM_ 1024 $ do
      Right (Router.NativeResult relay) <- takeWork jobs
      atomically (Router.releaseRelay jobs.resultRouter relay)
    Right (Router.JobReport first) <- takeWork jobs
    Right (Router.JobReport second) <- takeWork jobs
    Set.fromList [first.job.run, second.job.run] `shouldBe` Set.fromList [root.run, child.run]
    atomically (Router.releaseReport jobs.resultRouter first >> Router.releaseReport jobs.resultRouter second)
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing

  it "fences an accepted child report on replacement before parent observation" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    (child, runtime) <- launch tasks jobs 2 (request {parent = Just root.run})
    completeJob jobs child.run Succeeded (JobResult "obsolete proof" Nothing)
    finishTurnRuntime tasks runtime
    detachJobTurn jobs child.run
    replaceJob jobs request.group request.principal False 2 "new work" `shouldReturn` Right ()
    atomically (Router.referencedOwners jobs.resultRouter) `shouldReturn` Set.empty
    observeJobEvents jobs (AgentTurnId 1) `shouldReturn` []
    Left fresh <- takeWork jobs
    fresh.run `shouldBe` JobRun 2 2

  it "reserves an awaited child's report before its worker can finish and before the wait registers" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    Right child <- admitJob jobs (Just (AgentTurnId 1)) 2 (request {parent = Just root.run, awaited = True})
    Left _ <- takeWork jobs
    completeJob jobs child.run Succeeded (JobResult "immediate child" Nothing)
    observeJobEvents jobs (AgentTurnId 1) `shouldReturn` []
    completeJob jobs root.run Succeeded (JobResult "parent done" Nothing)
    Right (Router.JobReport parentRelay) <- takeWork jobs
    parentRelay.job.run `shouldBe` root.run
    Right (ChildrenFinished [result]) <- waitForChildren jobs (AgentTurnId 1) [2]
    result.result `shouldBe` Just (JobResult "immediate child" Nothing)
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing

  it "collects folded late notes with an already-settled future without changing its report payload" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    Right child <- admitJob jobs (Just (AgentTurnId 1)) 2 request {parent = Just root.run, awaited = True}
    Left _ <- takeWork jobs
    childRuntime <- beginTurnRuntime tasks (reference 2) request.group (UserId 7) Nothing
    attachJobTurn jobs child.run (reference 2) `shouldReturn` True
    tellParent jobs (AgentTurnId 2) "unobserved note" False `shouldReturn` Right ()
    let report = JobResult "report" (Just (object ["proof" .= (7 :: Int)]))
    completeJob jobs child.run Succeeded report
    completeJob jobs root.run Succeeded (JobResult "parent ended" Nothing)
    Right (ChildrenFinished [collected]) <- waitForChildren jobs (AgentTurnId 1) [2]
    collected.messages `shouldBe` ["unobserved note"]
    collected.result `shouldBe` Just report
    finishTurnRuntime tasks childRuntime

  it "relays a ready awaited root report when its caller ends without entering the wait" $ do
    (tasks, jobs, request) <- fixture
    caller <- beginTurnRuntime tasks (reference 99) request.group (UserId 7) Nothing
    Right child <- admitJob jobs (Just (AgentTurnId 99)) 1 (request {awaited = True})
    Left _ <- takeWork jobs
    completeJob jobs child.run Succeeded (JobResult "unclaimed" Nothing)
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing
    finishTurnRuntime tasks caller
    Just (Right (Router.JobReport relay)) <- timeout 1000000 (takeWork jobs)
    relay.job.run `shouldBe` child.run
    reportText relay `shouldBe` "unclaimed"

  it "binds report relay publication to its exact attempt and original generation" $ do
    (tasks, jobs, request) <- fixture
    (root, runtime) <- launch tasks jobs 1 request
    completeJob jobs root.run Succeeded (JobResult "proof" Nothing)
    finishTurnRuntime tasks runtime
    detachJobTurn jobs root.run
    Right (Router.JobReport first) <- takeWork jobs
    atomically (Router.requeueReport jobs.resultRouter first)
    Right (Router.JobReport second) <- takeWork jobs
    second.attempt `shouldBe` first.attempt + 1
    atomically (Router.releaseReport jobs.resultRouter first >> Router.requeueReport jobs.resultRouter first)
    bindReportRelay jobs (AgentTurnId 10) second
    authorizeJobPublication jobs (AgentTurnId 10) `shouldReturn` True
    replaceJob jobs request.group request.principal False 1 "replacement" `shouldReturn` Right ()
    authorizeJobPublication jobs (AgentTurnId 10) `shouldReturn` False
    detachJobNotice jobs (AgentTurnId 10)

  it "lets admitted calls and descendants finish after a parent's final answer while fencing new parent work" $ do
    (tasks, jobs, request) <- fixture
    (root, runtime) <- launch tasks jobs 1 request
    (child, _) <- launch tasks jobs 2 (request {parent = Just root.run})
    completeJob jobs root.run Succeeded (JobResult "children will report later" Nothing)
    authorizeJobStep jobs (AgentTurnId 1) (ExecutionWork CheckOnly) `shouldReturn` True
    forM_ [ExecutionCheckpoint, ExecutionWork ReserveCall, ExecutionWork ReserveRound] $ \step ->
      authorizeJobStep jobs (AgentTurnId 1) step `shouldReturn` False
    authorizeJobStep jobs (AgentTurnId 2) (ExecutionWork ReserveCall) `shouldReturn` True
    admitJob jobs Nothing 3 (request {parent = Just root.run}) `shouldReturnSatisfying` isLeft
    (grandchild, _) <- launch tasks jobs 3 (request {parent = Just child.run})
    finishTurnRuntime tasks runtime
    detachJobTurn jobs root.run
    authorizeJobStep jobs (AgentTurnId 1) (ExecutionWork CheckOnly) `shouldReturn` False
    authorizeJobStep jobs (AgentTurnId 3) (ExecutionWork ReserveRound) `shouldReturn` True
    cancelJob jobs request.group request.principal False root.run.jobId "stop remaining work" `shouldReturn` Right ()
    forM_ [child, grandchild] $ \job -> do
      fmap (fmap (.status)) (lookupJob jobs request.group job.run.jobId) `shouldReturn` Just Cancelled
      authorizeJobStep jobs (AgentTurnId job.run.jobId) (ExecutionWork CheckOnly) `shouldReturn` False

  it "relays a child's late report after its parent has ended" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    (child, _) <- launch tasks jobs 2 (request {parent = Just root.run})
    completeJob jobs root.run Succeeded (JobResult "parent done" Nothing)
    Right (Router.JobReport notice) <- takeWork jobs
    reportText notice `shouldBe` "parent done"
    atomically (Router.releaseReport jobs.resultRouter notice)
    completeJob jobs child.run Succeeded (JobResult "late child result" Nothing)
    Just (Right (Router.JobReport relay)) <- timeout 1000000 (takeWork jobs)
    let result = relay.job
        body = reportText relay
    result.run `shouldBe` child.run
    body `shouldBe` "late child result"

  it "returns a retained child wait after the parent ends without also publishing the report" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    (child, _) <- launch tasks jobs 2 (request {parent = Just root.run})
    withAsync (waitForChildren jobs (AgentTurnId 1) [2]) $ \joining -> do
      timeout 20000 (wait joining) `shouldReturn` Nothing
      completeJob jobs root.run Succeeded (JobResult "parent done" Nothing)
      Right (Router.JobReport otherNotice) <- takeWork jobs
      atomically (Router.releaseReport jobs.resultRouter otherNotice)
      completeJob jobs child.run Succeeded (JobResult "awaited result" Nothing)
      Just (Right (ChildrenFinished [result])) <- timeout 1000000 (wait joining)
      result.result `shouldBe` Just (JobResult "awaited result" Nothing)
      timeout 20000 (takeWork jobs) `shouldReturn` Nothing

  it "keeps ended ancestors and their shared budget while live descendants survive registry pruning" $ do
    (tasks, jobs, request) <- fixture
    (root, runtime) <- launch tasks jobs 1 request
    _ <- launch tasks jobs 2 (request {parent = Just root.run})
    authorizeJobStep jobs (AgentTurnId 2) (ExecutionWork ReserveCall) `shouldReturn` True
    completeJob jobs root.run Succeeded (JobResult "parent done" Nothing)
    finishTurnRuntime tasks runtime
    detachJobTurn jobs root.run
    Right (Router.JobReport notice) <- takeWork jobs
    atomically (Router.releaseReport jobs.resultRouter notice)
    forM_ [3 .. 270] $ \identifier -> do
      Right other <- admitJob jobs Nothing identifier request
      completeJob jobs other.run Succeeded (JobResult "done" Nothing)
      Right (Router.JobReport otherNotice) <- takeWork jobs
      atomically (Router.releaseReport jobs.resultRouter otherNotice)
    Just retained <- lookupJob jobs request.group root.run.jobId
    retained.calls `shouldBe` 1
    authorizeJobStep jobs (AgentTurnId 2) (ExecutionWork ReserveCall) `shouldReturn` True
    fmap (fmap (.calls)) (lookupJob jobs request.group root.run.jobId) `shouldReturn` Just 2

  it "fences a completed parent's retained call and descendants when its objective is replaced" $ do
    (tasks, jobs, request) <- fixture
    (root, runtime) <- launch tasks jobs 1 request
    _ <- launch tasks jobs 2 (request {parent = Just root.run})
    completeJob jobs root.run Succeeded (JobResult "parent done" Nothing)
    replaceJob jobs request.group request.principal False 1 "new objective" `shouldReturn` Right ()
    forM_ [1, 2] $ \identifier -> authorizeJobStep jobs (AgentTurnId identifier) (ExecutionWork CheckOnly) `shouldReturn` False
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing
    finishTurnRuntime tasks runtime
    detachJobTurn jobs root.run
    Left replacement <- takeWork jobs
    replacement.run.generation `shouldBe` 2

  it "keeps another concurrent child wait owned when one waiter is cancelled" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    (child, _) <- launch tasks jobs 2 (request {parent = Just root.run})
    withAsync (waitForChildren jobs (AgentTurnId 1) [2]) $ \first ->
      withAsync (waitForChildren jobs (AgentTurnId 1) [2]) $ \second -> do
        timeout 20000 (wait first) `shouldReturn` Nothing
        timeout 20000 (wait second) `shouldReturn` Nothing
        completeJob jobs root.run Succeeded (JobResult "parent done" Nothing)
        Right (Router.JobReport completedNotice) <- takeWork jobs
        atomically (Router.releaseReport jobs.resultRouter completedNotice)
        cancel first
        completeJob jobs child.run Succeeded (JobResult "awaited result" Nothing)
        Just (Right (ChildrenFinished [result])) <- timeout 1000000 (wait second)
        result.result `shouldBe` Just (JobResult "awaited result" Nothing)
        timeout 20000 (takeWork jobs) `shouldReturn` Nothing

  it "retains a settled sibling until a multi-child wait can collect the whole batch" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    (first, firstRuntime) <- launch tasks jobs 2 (request {parent = Just root.run})
    (second, _) <- launch tasks jobs 3 (request {parent = Just root.run})
    withAsync (waitForChildren jobs (AgentTurnId 1) [2, 3]) $ \joining -> do
      timeout 20000 (wait joining) `shouldReturn` Nothing
      completeJob jobs root.run Succeeded (JobResult "parent done" Nothing)
      Right (Router.JobReport otherNotice) <- takeWork jobs
      atomically (Router.releaseReport jobs.resultRouter otherNotice)
      completeJob jobs first.run Succeeded (JobResult "first result" Nothing)
      finishTurnRuntime tasks firstRuntime
      detachJobTurn jobs first.run
      forM_ [4 .. 270] $ \identifier -> do
        Right other <- admitJob jobs Nothing identifier request
        completeJob jobs other.run Succeeded (JobResult "done" Nothing)
        Right (Router.JobReport completedNotice) <- takeWork jobs
        atomically (Router.releaseReport jobs.resultRouter completedNotice)
      completeJob jobs second.run Succeeded (JobResult "second result" Nothing)
      Just (Right (ChildrenFinished results)) <- timeout 1000000 (wait joining)
      map (.result) results `shouldBe` map (Just . (`JobResult` Nothing)) ["first result", "second result"]
      timeout 20000 (takeWork jobs) `shouldReturn` Nothing

  it "replaces a partially collected child outcome without acknowledging the new generation early" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    (first, oldRuntime) <- launch tasks jobs 2 (request {parent = Just root.run})
    (second, _) <- launch tasks jobs 3 (request {parent = Just root.run})
    withAsync (waitForChildren jobs (AgentTurnId 1) [2, 3]) $ \joining -> do
      timeout 20000 (wait joining) `shouldReturn` Nothing
      completeJob jobs first.run Succeeded (JobResult "obsolete partial result" Nothing)
      finishTurnRuntime tasks oldRuntime
      detachJobTurn jobs first.run
      replaceJob jobs request.group request.principal False 2 "replacement child" `shouldReturn` Right ()
      Left replacement <- takeWork jobs
      replacement.run `shouldBe` JobRun 2 2
      completeJob jobs second.run Succeeded (JobResult "sibling result" Nothing)
      timeout 20000 (wait joining) `shouldReturn` Nothing
      completeJob jobs replacement.run Succeeded (JobResult "replacement result" Nothing)
      Just (Right (ChildrenFinished results)) <- timeout 1000000 (wait joining)
      map (.result) results `shouldBe` map (Just . (`JobResult` Nothing)) ["replacement result", "sibling result"]
      observeJobEvents jobs (AgentTurnId 1) `shouldReturn` []

  it "replaces a cached partial success with cancellation before a join collects the batch" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    (first, _) <- launch tasks jobs 2 (request {parent = Just root.run})
    (second, _) <- launch tasks jobs 3 (request {parent = Just root.run})
    withAsync (waitForChildren jobs (AgentTurnId 1) [2, 3]) $ \joining -> do
      timeout 20000 (wait joining) `shouldReturn` Nothing
      completeJob jobs first.run Succeeded (JobResult "revoked success" Nothing)
      cancelJob jobs request.group request.principal False 2 "cancel cached result" `shouldReturn` Right ()
      completeJob jobs second.run Succeeded (JobResult "sibling result" Nothing)
      Just (Right (ChildrenFinished results)) <- timeout 1000000 (wait joining)
      map (.status) results `shouldBe` [Cancelled, Succeeded]
      observeJobEvents jobs (AgentTurnId 1) `shouldReturn` []

  it "expires an unclaimed admission reservation when its root is replaced" $ do
    (tasks, jobs, request) <- fixture
    caller <- beginTurnRuntime tasks (reference 99) request.group (UserId 7) Nothing
    Right original <- admitJob jobs (Just (AgentTurnId 99)) 1 request {awaited = True}
    replaceJob jobs request.group request.principal False 1 "replacement root" `shouldReturn` Right ()
    Left replacement <- takeWork jobs
    atomically (turnEvents caller >>= Events.close)
    completeJob jobs replacement.run Succeeded (JobResult "new root report" Nothing)
    Right (Router.JobReport relay) <- takeWork jobs
    relay.job.run `shouldBe` replacement.run
    awaitJob jobs (AgentTurnId 99) original.run `shouldReturnSatisfying` isLeft

  it "rejects guests immediately at the tree/global limits and releases slots once" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    _ <- launch tasks jobs 2 (request {parent = Just root.run})
    tree <- replicateM 16 (acquireGuestSlot jobs (AgentTurnId 1))
    all isJust tree `shouldBe` True
    isNothing <$> acquireGuestSlot jobs (AgentTurnId 2) `shouldReturn` True
    others <- traverse (acquireGuestSlot jobs . AgentTurnId) [100 .. 115]
    all isJust others `shouldBe` True
    isNothing <$> acquireGuestSlot jobs (AgentTurnId 200) `shouldReturn` True
    first : _ <- pure (catMaybes tree)
    first >> first
    Just release <- acquireGuestSlot jobs (AgentTurnId 2)
    isNothing <$> acquireGuestSlot jobs (AgentTurnId 2) `shouldReturn` True
    release
    sequence_ (catMaybes (tree <> others))
    isJust <$> acquireGuestSlot jobs (AgentTurnId 2) `shouldReturn` True

  it "counts a foreground guest and its awaited children against the same tree" $ do
    (tasks, jobs, request) <- fixture
    _ <- beginTurnRuntime tasks (reference 99) request.group (UserId 7) Nothing
    Right child <- admitJob jobs (Just (AgentTurnId 99)) 1 (request {awaited = True})
    _ <- takeWork jobs
    _ <- beginTurnRuntime tasks (reference 1) request.group (UserId 7) Nothing
    attachJobTurn jobs child.run (reference 1) `shouldReturn` True
    slots <- replicateM 16 (acquireGuestSlot jobs (AgentTurnId 99))
    isNothing <$> acquireGuestSlot jobs (AgentTurnId 1) `shouldReturn` True
    sequence_ (catMaybes slots)

  it "fences new work and returns one shutdown notice per interrupted root" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    _ <- launch tasks jobs 2 (request {parent = Just root.run})
    _ <- admitJob jobs Nothing 3 request
    notices <- closeJobs jobs
    map (.run.jobId) notices `shouldBe` [1, 3]
    map (.status) notices `shouldBe` [Cancelled, Cancelled]
    map (.spec.source) notices `shouldBe` replicate 2 request.source
    authorizeJobStep jobs (AgentTurnId 1) ExecutionCheckpoint `shouldReturn` False
    authorizeJobStep jobs (AgentTurnId 2) ExecutionCheckpoint `shouldReturn` False
    admitJob jobs Nothing 4 request >>= (`shouldSatisfy` isLeft)
    timeout 20_000 (takeWork jobs) `shouldReturn` Nothing
    closeJobs jobs `shouldReturn` []

  it "cancels retained foreground and completed-job work at shutdown without replacing the final report" $ do
    (tasks, jobs, request) <- fixture
    (job, background) <- launch tasks jobs 1 request
    foreground <- beginTurnRuntime tasks (reference 99) request.group (UserId 7) Nothing
    completeJob jobs job.run Succeeded (JobResult "already finished" Nothing)
    let retained runtime action = do
          never <- newEmptyMVar
          withAsync (takeMVar never :: IO ()) $ \call -> do
            retainTurnWork runtime (cancel call) (cancel call) (void (waitCatchSTM call))
            withAsync (finishTurnRuntime tasks runtime) $ \closing -> do
              timeout 1000000 (atomically (turnAcceptsWork tasks (turnRuntimeAgentTurn runtime).atrTurnId >>= check . not)) `shouldReturn` Just ()
              action
              timeout 1000000 (wait closing) `shouldReturn` Just ()
              waitCatch call >>= (`shouldSatisfy` isLeft)
              atomically (turnWasCancelled runtime) `shouldReturn` True
    retained background . retained foreground $ do
      notices <- closeJobs jobs
      map (.status) notices `shouldBe` [Succeeded]
      map (.result) notices `shouldBe` [Just (JobResult "already finished" Nothing)]
      closeJobs jobs `shouldReturn` []

  it "leaves active foreground owners unsignalled and cancels calls retained after shutdown begins" $ do
    (tasks, jobs, request) <- fixture
    foreground <- beginTurnRuntime tasks (reference 99) request.group (UserId 7) Nothing
    closeJobs jobs `shouldReturn` []
    atomically (turnAcceptsWork tasks (AgentTurnId 99)) `shouldReturn` True
    atomically (turnWasCancelled foreground) `shouldReturn` False
    never <- newEmptyMVar
    withAsync (takeMVar never :: IO ()) $ \call -> do
      retainTurnWork foreground (cancel call) (cancel call) (void (waitCatchSTM call))
      timeout 1000000 (finishTurnRuntime tasks foreground) `shouldReturn` Just ()
      waitCatch call >>= (`shouldSatisfy` isLeft)
      atomically (turnWasCancelled foreground) `shouldReturn` True
    listTasks tasks Nothing >>= (`shouldSatisfy` null)

  it "includes an unclaimed final result but does not replay a notice already publishing" $ do
    (tasks, jobs, request) <- fixture
    (first, _) <- launch tasks jobs 1 request
    (second, _) <- launch tasks jobs 2 request
    completeJob jobs first.run Succeeded (JobResult "first result" Nothing)
    Right (Router.JobReport relay) <- takeWork jobs
    bindReportRelay jobs (AgentTurnId 10) relay
    completeJob jobs second.run Succeeded (JobResult "second result" Nothing)
    notices <- closeJobs jobs
    map (.run.jobId) notices `shouldBe` [2]
    map (.result) notices `shouldBe` [Just (JobResult "second result" Nothing)]
    authorizeJobPublication jobs (AgentTurnId 10) `shouldReturn` True

  it "takes over a final notice claimed just before shutdown admission closes" $ do
    (tasks, jobs, request) <- fixture
    (job, _) <- launch tasks jobs 1 request
    completeJob jobs job.run Succeeded (JobResult "result" Nothing)
    Right (Router.JobReport relay) <- takeWork jobs
    notices <- closeJobs jobs
    map (.run.jobId) notices `shouldBe` [1]
    bindReportRelay jobs (AgentTurnId 10) relay
    authorizeJobPublication jobs (AgentTurnId 10) `shouldReturn` False

  it "keeps detached jobs after their initiating reply and binds status to a conversation" $ do
    (tasks, jobs, request) <- fixture
    source <- beginTurnRuntime tasks (reference 99) request.group (UserId 7) Nothing
    Right job <- admitJob jobs (Just (AgentTurnId 99)) 1 request
    finishTurnRuntime tasks source
    lookupJob jobs request.group 1 `shouldReturn` Just job
    lookupJob jobs (GroupId 9) 1 `shouldReturn` Nothing
    listJobs jobs (GroupId 9) `shouldReturn` []
    admitJob jobs (Just (AgentTurnId 99)) 2 request >>= (`shouldSatisfy` isLeft)

  it "reserves one shared tool budget across concurrent children, separately from rounds" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    (_, _) <- launch tasks jobs 2 (request {parent = Just root.run})
    (_, _) <- launch tasks jobs 3 (request {parent = Just root.run})
    reserved <- mapConcurrently (\n -> decideJobStep jobs (AgentTurnId (if even n then 2 else 3)) (ExecutionWork ReserveCall)) [1 .. treeToolCalls + 60]
    length (filter (== Admitted) reserved) `shouldBe` treeToolCalls
    -- Spent budget refuses the call but leaves the agent running.
    length (filter (== OverBudget) reserved) `shouldBe` 60
    Just budget <- lookupJob jobs request.group 1
    budget.calls `shouldBe` treeToolCalls
    rounds <- replicateM treeModelRounds (authorizeJobStep jobs (AgentTurnId 1) (ExecutionWork ReserveRound))
    and rounds `shouldBe` True
    decideJobStep jobs (AgentTurnId 1) (ExecutionWork ReserveRound) `shouldReturn` OverBudget
    authorizeJobStep jobs (AgentTurnId 1) ExecutionCheckpoint `shouldReturn` True
    completeJob jobs budget.run Failed (JobResult "budget spent" Nothing)
    fmap (fmap (.status)) (lookupJob jobs request.group 1) `shouldReturn` Just BudgetExhausted

  it "books model spend on the calling job and its ancestors, and times the job" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    (child, _) <- launch tasks jobs 2 (request {parent = Just root.run})
    (_, _) <- launch tasks jobs 3 (request {parent = Just child.run})
    recordJobUsage jobs (AgentTurnId 3) (TokenUsage 120000 800 (Just 100000) (Just (CallCost "CNY" 0.25)))
    recordJobUsage jobs (AgentTurnId 2) (TokenUsage 5000 200 Nothing Nothing)
    recordJobUsage jobs (AgentTurnId 1) (TokenUsage 3000 100 (Just 2000) (Just (CallCost "USD" 0.01)))
    recordJobUsage jobs (AgentTurnId 99) (TokenUsage 1 1 Nothing (Just (CallCost "CNY" 9)))
    Just third <- lookupJob jobs request.group 3
    third.usage `shouldBe` JobUsage 1 120000 100000 800 (Map.fromList [("CNY", 0.25)]) 0
    Just second <- lookupJob jobs request.group 2
    second.usage `shouldBe` JobUsage 2 125000 100000 1000 (Map.fromList [("CNY", 0.25)]) 1
    completeJob jobs root.run Succeeded (JobResult "done" Nothing)
    Right (Router.JobReport relay) <- takeWork jobs
    let finished = relay.job
    finished.usage `shouldBe` JobUsage 3 128000 102000 1100 (Map.fromList [("CNY", 0.25), ("USD", 0.01)]) 1
    finished.finished `shouldSatisfy` maybe False (>= finished.created)
    let line = jobUsageLine finished
    line `shouldSatisfy` T.isPrefixOf "用量：模型调用 3 次，输入 12.8万 tokens（缓存命中 10.2万），输出 1100 tokens，用时 0 秒"
    line `shouldSatisfy` T.isInfixOf "预估费用 ¥0.2500 + $0.0100（另有 1 次调用未配置价格）"
    jobUsageLine finished {usage = finished.usage {costs = Map.empty}} `shouldSatisfy` (not . T.isInfixOf "费用")

  it "waits without holding a child worker slot and retains child results until collected" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    Right child <- admitJob jobs Nothing 2 (request {parent = Just root.run})
    withAsync (waitForChildren jobs (AgentTurnId 1) []) $ \joining -> do
      (isNothing <$> timeout 20000 (wait joining)) `shouldReturn` True
      Left started <- takeWork jobs
      started.run `shouldBe` child.run
      completeJob jobs child.run Succeeded (JobResult "child result" Nothing)
      Right (ChildrenFinished [result]) <- wait joining
      result.result `shouldBe` Just (JobResult "child result" Nothing)
    notes <- observeJobEvents jobs (AgentTurnId 1)
    length notes `shouldBe` 0
    observeJobEvents jobs (AgentTurnId 1) `shouldReturn` []
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing

  it "signals attributed feedback without completing the child future" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    _ <- admitJob jobs Nothing 2 (request {parent = Just root.run})
    withAsync (waitForChildren jobs (AgentTurnId 1) [2]) $ \joining -> do
      steerJob jobs request.group (PrincipalId 8) (Just (CanonicalMessageId 55)) 1 "new evidence" `shouldReturn` Right ()
      timeout 20000 (atomically (awaitJobInterrupt jobs (AgentTurnId 1))) `shouldReturn` Just ()
      timeout 20000 (wait joining) `shouldReturn` Nothing
    observeJobEvents jobs (AgentTurnId 1) `shouldReturn` [object ["author" .= PrincipalId 8, "source_message" .= CanonicalMessageId 55, "body" .= String "new evidence"]]
    waitForChildren jobs (AgentTurnId 1) [99] >>= (`shouldSatisfy` isLeft)

  it "wakes a waiting parent when its turn is cancelled outside Jobs" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    _ <- admitJob jobs Nothing 2 (request {parent = Just root.run})
    withAsync (waitForChildren jobs (AgentTurnId 1) []) $ \joining -> do
      cancelAgentTurnTask tasks (AgentTurnId 1) `shouldReturn` True
      wait joining `shouldThrow` (\TaskCancelled -> True)

  it "delivers child cancellation" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    Right _ <- admitJob jobs Nothing 2 (request {parent = Just root.run})
    cancelJob jobs request.group request.principal False 2 "cancel child" `shouldReturn` Right ()
    Right (ChildrenFinished [cancelled]) <- waitForChildren jobs (AgentTurnId 1) []
    cancelled.status `shouldBe` Cancelled
    notes <- observeJobEvents jobs (AgentTurnId 1)
    notes `shouldBe` [object ["child_update" .= cancelled]]

  it "returns an awaited root's report to the waiting turn instead of a relay notice" $ do
    (tasks, jobs, request) <- fixture
    caller <- beginTurnRuntime tasks (reference 99) request.group (UserId 7) Nothing
    Right admitted <- admitJob jobs (Just (AgentTurnId 99)) 1 (request {awaited = True})
    Left job <- takeWork jobs
    withAsync (awaitJob jobs (AgentTurnId 99) admitted.run) $ \waiting -> do
      completeJob jobs job.run Succeeded (JobResult "report" Nothing)
      Right finished <- wait waiting
      finished.result `shouldBe` Just (JobResult "report" Nothing)
    timeout 20_000 (takeWork jobs) `shouldReturn` Nothing
    finishTurnRuntime tasks caller

  it "relays a report its waiter collected only after the report was ready" $ do
    (tasks, jobs, request) <- fixture
    caller <- beginTurnRuntime tasks (reference 99) request.group (UserId 7) Nothing
    Right admitted <- admitJob jobs (Just (AgentTurnId 99)) 1 (request {awaited = True})
    Left job <- takeWork jobs
    completeJob jobs job.run Succeeded (JobResult "ready" Nothing)
    timeout 20_000 (takeWork jobs) `shouldReturn` Nothing
    _ <- cancelAgentTurnTask tasks (AgentTurnId 99)
    awaitJob jobs (AgentTurnId 99) admitted.run `shouldThrow` (\TaskCancelled -> True)
    Right (Router.JobReport relay) <- takeWork jobs
    let noticed = relay.job
        body = reportText relay
    (noticed.run, body) `shouldBe` (admitted.run, "ready")
    finishTurnRuntime tasks caller

  it "relays an awaited root's report once its waiter stops waiting" $ do
    (tasks, jobs, request) <- fixture
    caller <- beginTurnRuntime tasks (reference 99) request.group (UserId 7) Nothing
    Right first <- admitJob jobs (Just (AgentTurnId 99)) 1 (request {awaited = True})
    Right second <- admitJob jobs (Just (AgentTurnId 99)) 2 (request {awaited = True})
    Left running <- takeWork jobs
    Left _ <- takeWork jobs
    -- Abandoned while running: the report is relayed when it arrives.
    withAsync (awaitJob jobs (AgentTurnId 99) first.run) $ \waiting -> do
      cancelAgentTurnTask tasks (AgentTurnId 99) `shouldReturn` True
      wait waiting `shouldThrow` (\TaskCancelled -> True)
    completeJob jobs running.run Succeeded (JobResult "late report" Nothing)
    Right (Router.JobReport relay) <- takeWork jobs
    let noticed = relay.job
        body = reportText relay
    (noticed.run, body) `shouldBe` (first.run, "late report")
    -- Its waiter ended without ever waiting: relayed as soon as it finishes.
    completeJob jobs second.run Succeeded (JobResult "unread report" Nothing)
    Right (Router.JobReport secondRelay) <- takeWork jobs
    let unread = secondRelay.job
        text = reportText secondRelay
    (unread.run, text) `shouldBe` (second.run, "unread report")
    finishTurnRuntime tasks caller

  it "cancels descendants before signalling and stops old work after replacement" $ do
    (tasks, jobs, request) <- fixture
    (root, runtime) <- launch tasks jobs 1 request
    (child, _) <- launch tasks jobs 2 (request {parent = Just root.run})
    authorizeJobStep jobs (AgentTurnId 1) (ExecutionWork ReserveCall) `shouldReturn` True
    replaceJob jobs request.group request.principal False 1 "new objective" `shouldReturn` Right ()
    authorizeJobStep jobs (AgentTurnId 1) ExecutionCheckpoint `shouldReturn` False
    authorizeJobStep jobs (AgentTurnId 2) ExecutionCheckpoint `shouldReturn` False
    Just cancelled <- lookupJob jobs request.group child.run.jobId
    cancelled.status `shouldBe` Cancelled
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing
    finishTurnRuntime tasks runtime
    detachJobTurn jobs root.run
    Left replacement <- takeWork jobs
    replacement.run.generation `shouldBe` 2
    replacement.calls `shouldBe` 1
    replacement.spec.deadline `shouldBe` root.spec.deadline
    completeJob jobs root.run Succeeded (JobResult "obsolete" Nothing)
    lookupJob jobs request.group 1 `shouldReturn` Just replacement

  it "revokes every runtime and routes terminal controls before a cancellation signal can block" $ do
    (tasks, jobs, request) <- fixture
    (root, rootRuntime) <- launch tasks jobs 1 request
    (_, childRuntime) <- launch tasks jobs 2 (request {parent = Just root.run})
    rootEvents <- atomically (turnEvents rootRuntime)
    childEvents <- atomically (turnEvents childRuntime)
    entered <- newEmptyMVar
    release <- newEmptyMVar
    _ <- activateTurnRuntime childRuntime "blocked cancellation" (putMVar entered () >> takeMVar release)
    withAsync (replaceJob jobs request.group request.principal False 1 "new objective") $ \replacing -> do
      timeout 1000000 (takeMVar entered) `shouldReturn` Just ()
      atomically (turnIsLive tasks (AgentTurnId 1)) `shouldReturn` False
      atomically (turnIsLive tasks (AgentTurnId 2)) `shouldReturn` False
      authorizeTurnOutput tasks request.group (AgentTurnId 2) `shouldReturn` False
      map (.body) <$> atomically (Events.peekAll rootEvents) `shouldReturn` [Events.Replaced "new objective"]
      map (.body) <$> atomically (Events.peekAll childEvents) `shouldReturn` [Events.Cancelled]
      atomically (Events.deliver childEvents (Events.Steered Null)) `shouldReturn` False
      putMVar release ()
      wait replacing `shouldReturn` Right ()

  it "keeps replaced child handles joinable by their parent" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    Right child <- admitJob jobs Nothing 2 (request {parent = Just root.run})
    replaceJob jobs request.group request.principal False 2 "new child" `shouldReturn` Right ()
    Left replacement <- takeWork jobs
    completeJob jobs replacement.run Succeeded (JobResult "new result" Nothing)
    Right (ChildrenFinished [result]) <- waitForChildren jobs (AgentTurnId 1) [child.run.jobId]
    result.run `shouldBe` replacement.run

  it "rejects forged ownership, broader grants and longer child deadlines" $ do
    (tasks, jobs, request) <- fixture
    let permission = Map.singleton "web_search" "v1"
    (root, _) <- launch tasks jobs 1 (request {grants = permission})
    cancelJob jobs request.group (PrincipalId 8) False 1 "no" >>= (`shouldSatisfy` isLeft)
    replaceJob jobs (GroupId 99) request.principal True 1 "no" >>= (`shouldSatisfy` isLeft)
    forM_ [request {principal = PrincipalId 8}, request {group = GroupId 99}, request {grants = Map.singleton "web_search" "v2"}, request {profile = Sandbox, grants = Map.singleton "sandbox_exec" "v1"}] $ \wider ->
      admitJob jobs Nothing 2 (wider {parent = Just root.run}) >>= (`shouldSatisfy` isLeft)
    Right child <- admitJob jobs Nothing 2 (request {parent = Just root.run, deadline = addUTCTime 86400 request.deadline})
    child.spec.deadline `shouldBe` root.spec.deadline
    cancelJob jobs request.group (PrincipalId 8) True 1 "admin" `shouldReturn` Right ()
    attachJobTurn jobs child.run (reference 2) `shouldReturn` False

  it "caps a tree at six hours and preserves earlier requested and ancestor deadlines" $ do
    (_, jobs, request) <- fixture
    now <- getCurrentTime
    Right root <- admitJob jobs Nothing 1 request {deadline = addUTCTime 86400 now}
    root.spec.deadline `shouldBe` addUTCTime 21600 root.created
    Right child <- admitJob jobs Nothing 2 root.spec {parent = Just root.run, deadline = addUTCTime 86400 now}
    child.spec.deadline `shouldBe` root.spec.deadline
    let earlier = addUTCTime 60 now
    Right short <- admitJob jobs Nothing 3 child.spec {parent = Just child.run, deadline = earlier}
    short.spec.deadline `shouldBe` earlier
    admitJob jobs Nothing 4 request {deadline = addUTCTime (-1) now} `shouldReturn` Left "job deadline has passed"

  it "admits sixteen generations and rejects a seventeenth without consuming its identity" $ do
    (_, jobs, request) <- fixture
    Right root <- admitJob jobs Nothing 1 request
    deepest <-
      foldM
        ( \parent identifier -> do
            Right child <- admitJob jobs Nothing identifier request {parent = Just parent.run}
            pure child
        )
        root
        [2 .. 16]
    admitJob jobs Nothing 17 request {parent = Just deepest.run} `shouldReturn` Left "job nesting limit"
    admitJob jobs Nothing 17 request {parent = Just root.run} >>= (`shouldSatisfy` isRight)

  it "accepts 100000 report characters and rejects one more without truncating" $ do
    (_, _, request) <- fixture
    let body = T.replicate 100000 "😀"
    parseJobResult request body `shouldBe` Right (JobResult body Nothing)
    parseJobResult request (body <> "文") `shouldBe` Left "job response exceeds 100000 characters"

  it "keeps root progress internal without suppressing the final result" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    reportJobProgress jobs (AgentTurnId 1) "first" `shouldReturn` True
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing
    reportJobProgress jobs (AgentTurnId 1) "latest" `shouldReturn` True
    reportJobProgress jobs (AgentTurnId 1) "latest" `shouldReturn` True
    Just current <- lookupJob jobs request.group root.run.jobId
    current.progress `shouldBe` Just "latest"
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing
    completeJob jobs root.run Succeeded (JobResult "final" Nothing)
    Right (Router.JobReport relay) <- takeWork jobs
    let final = relay.job
        body = reportText relay
    final.status `shouldBe` Succeeded
    body `shouldBe` "final"
    atomically (Router.reportIsCurrent relay) `shouldReturn` True

  it "delivers tells to the parent and only urgent messages interrupt its await" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    (_, childRuntime) <- launch tasks jobs 2 (request {parent = Just root.run})
    tellParent jobs (AgentTurnId 2) "ordinary" False `shouldReturn` Right ()
    Just parentEvents <- atomically (jobEventTask jobs (AgentTurnId 1))
    atomically (Events.hasInterrupt parentEvents Events.noPending) `shouldReturn` False
    first <- atomically (Router.observeEvents jobs.resultRouter parentEvents)
    map (.body) first `shouldBe` [Events.ChildSaid (JobRun 2 1) "ordinary" Events.Normal]
    tellParent jobs (AgentTurnId 2) "urgent" True `shouldReturn` Right ()
    atomically (Events.hasInterrupt parentEvents Events.noPending) `shouldReturn` True
    finishTurnRuntime tasks childRuntime
    tellParent jobs (AgentTurnId 2) "too late" True `shouldReturnSatisfying` isLeft

  it "routes a root child's tells to the foreground task that admitted it" $ do
    (tasks, jobs, request) <- fixture
    caller <- beginTurnRuntime tasks (reference 99) request.group (UserId 7) Nothing
    parentEvents <- atomically (turnEvents caller)
    Right job <- admitJob jobs (Just (AgentTurnId 99)) 1 request
    Left _ <- takeWork jobs
    _ <- beginTurnRuntime tasks (reference 1) request.group (UserId 7) Nothing
    attachJobTurn jobs job.run (reference 1) `shouldReturn` True
    tellParent jobs (AgentTurnId 1) "question" True `shouldReturn` Right ()
    atomically (Events.hasInterrupt parentEvents Events.noPending) `shouldReturn` True
    observed <- atomically (Router.observeEvents jobs.resultRouter parentEvents)
    map (.body) observed `shouldBe` [Events.ChildSaid job.run "question" Events.Urgent]
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing

  it "rejects direct steering atomically when the parent's provenance log is full" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    _ <- launch tasks jobs 2 (request {parent = Just root.run})
    Just childEvents <- atomically (jobEventTask jobs (AgentTurnId 2))
    replicateM_ 255 $ tellParent jobs (AgentTurnId 2) "parent buffer" False `shouldReturn` Right ()
    steerJob jobs request.group request.principal Nothing 2 "change direction" `shouldReturnSatisfying` isLeft
    atomically (Router.observeEvents jobs.resultRouter childEvents) `shouldReturn` []
    _ <- observeJobEvents jobs (AgentTurnId 1)
    steerJob jobs request.group request.principal Nothing 2 "change direction" `shouldReturn` Right ()
    atomically (Events.hasInterrupt childEvents Events.noPending) `shouldReturn` True

  it "answers one question through the parent's steer without treating the answer as another interrupt" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    _ <- launch tasks jobs 2 (request {parent = Just root.run})
    Just parentEvents <- atomically (jobEventTask jobs (AgentTurnId 1))
    Just childEvents <- atomically (jobEventTask jobs (AgentTurnId 2))
    withAsync (askParent jobs (AgentTurnId 2) "which path?") $ \asking -> do
      timeout 1000000 (atomically (Events.awaitInterrupt parentEvents Events.noPending)) `shouldReturn` Just ()
      _ <- atomically (Router.observeEvents jobs.resultRouter parentEvents)
      askParent jobs (AgentTurnId 2) "second question" `shouldReturnSatisfying` isLeft
      steerJob jobs request.group request.principal Nothing 2 "outside advice" `shouldReturn` Right ()
      poll asking >>= (`shouldSatisfy` isNothing)
      _ <- atomically (Router.observeEvents jobs.resultRouter childEvents)
      steerJobFrom jobs (Just (AgentTurnId 1)) request.group request.principal Nothing 2 "path B" `shouldReturn` Right ()
      timeout 1000000 (wait asking) `shouldReturn` Just (Right (object ["author" .= request.principal, "source_message" .= Null, "body" .= ("path B" :: T.Text)]))
      atomically (Events.hasInterrupt childEvents Events.noPending) `shouldReturn` False
      notes <- atomically (Router.observeEvents jobs.resultRouter parentEvents)
      map (.body) notes `shouldSatisfy` any (\case Events.ChildSaid _ text Events.Normal -> "outside advice" `T.isInfixOf` text; _ -> False)

  it "answers asks across two levels while retaining both awaiting computations" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    (middle, _) <- launch tasks jobs 2 (request {parent = Just root.run})
    _ <- launch tasks jobs 3 (request {parent = Just middle.run})
    Just rootEvents <- atomically (jobEventTask jobs (AgentTurnId 1))
    Just middleEvents <- atomically (jobEventTask jobs (AgentTurnId 2))
    withAsync (askParent jobs (AgentTurnId 3) "permission?") $ \leaf -> do
      timeout 1000000 (atomically (Events.awaitInterrupt middleEvents Events.noPending)) `shouldReturn` Just ()
      _ <- atomically (Router.observeEvents jobs.resultRouter middleEvents)
      withAsync (askParent jobs (AgentTurnId 2) "leaf requests permission") $ \middleAsk -> do
        timeout 1000000 (atomically (Events.awaitInterrupt rootEvents Events.noPending)) `shouldReturn` Just ()
        steerJobFrom jobs (Just (AgentTurnId 1)) request.group request.principal Nothing 2 "yes" `shouldReturn` Right ()
        timeout 1000000 (wait middleAsk) `shouldReturn` Just (Right (object ["author" .= request.principal, "source_message" .= Null, "body" .= ("yes" :: T.Text)]))
      steerJobFrom jobs (Just (AgentTurnId 2)) request.group request.principal Nothing 3 "proceed" `shouldReturn` Right ()
      timeout 1000000 (wait leaf) `shouldReturn` Just (Right (object ["author" .= request.principal, "source_message" .= Null, "body" .= ("proceed" :: T.Text)]))

  it "releases a cancelled question without cancelling its agent" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    _ <- launch tasks jobs 2 (request {parent = Just root.run})
    Just parentEvents <- atomically (jobEventTask jobs (AgentTurnId 1))
    withAsync (askParent jobs (AgentTurnId 2) "first") $ \first -> do
      atomically (Events.awaitInterrupt parentEvents Events.noPending)
      cancel first
    _ <- atomically (Router.observeEvents jobs.resultRouter parentEvents)
    withAsync (askParent jobs (AgentTurnId 2) "second") $ \second -> do
      timeout 1000000 (atomically (Events.awaitInterrupt parentEvents Events.noPending)) `shouldReturn` Just ()
      steerJobFrom jobs (Just (AgentTurnId 1)) request.group request.principal Nothing 2 "answer" `shouldReturn` Right ()
      wait second `shouldReturnSatisfying` isRight

  it "releases a question when its runtime ends before job completion" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    (_, runtime) <- launch tasks jobs 2 (request {parent = Just root.run})
    Just parentEvents <- atomically (jobEventTask jobs (AgentTurnId 1))
    withAsync (askParent jobs (AgentTurnId 2) (T.replicate 8000 "x")) $ \asking -> do
      timeout 1000000 (atomically (Events.awaitInterrupt parentEvents Events.noPending)) `shouldReturn` Just ()
      finishTurnRuntime tasks runtime
      answer <- timeout 1000000 (wait asking)
      answer `shouldSatisfy` maybe False isLeft

  it "folds bounded late messages into the report without altering a contract payload" $ do
    (tasks, jobs, request) <- fixture
    caller <- beginTurnRuntime tasks (reference 99) request.group (UserId 7) Nothing
    Right job <- admitJob jobs (Just (AgentTurnId 99)) 1 request
    Left _ <- takeWork jobs
    runtime <- beginTurnRuntime tasks (reference 1) request.group (UserId 7) Nothing
    attachJobTurn jobs job.run (reference 1) `shouldReturn` True
    finishTurnRuntime tasks caller
    forM_ [1 .. 60 :: Int] $ \n -> tellParent jobs (AgentTurnId 1) (T.pack (show n)) False `shouldReturn` Right ()
    Just buffered <- lookupJob jobs request.group 1
    buffered.messages `shouldBe` map (T.pack . show) [11 .. 60 :: Int]
    forM_ [1 .. 60 :: Int] $ \n -> tellParent jobs (AgentTurnId 1) (T.pack (show n) <> T.replicate 1000 "汉") False `shouldReturn` Right ()
    let original = JobResult "{\"answer\":42}" (Just (object ["answer" .= (42 :: Int)]))
    completeJob jobs job.run Succeeded original
    Just finished <- lookupJob jobs request.group 1
    finished.result `shouldBe` Just original
    length finished.messages `shouldSatisfy` (<= 50)
    BS.length (TE.encodeUtf8 (T.intercalate "\n" finished.messages)) `shouldSatisfy` (<= 32768)
    last finished.messages `shouldSatisfy` T.isPrefixOf "60"
    Right (Router.JobReport relay) <- takeWork jobs
    let body = reportText relay
    body `shouldSatisfy` T.isInfixOf "60"
    finishTurnRuntime tasks runtime

  it "relays each unobserved urgent message and folds ordinary messages into an already-finished report" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    (child, _) <- launch tasks jobs 2 (request {parent = Just root.run})
    tellParent jobs (AgentTurnId 2) "ordinary evidence" False `shouldReturn` Right ()
    tellParent jobs (AgentTurnId 2) "first urgent" True `shouldReturn` Right ()
    tellParent jobs (AgentTurnId 2) "second urgent" True `shouldReturn` Right ()
    let result = JobResult "proof" (Just (object ["answer" .= (42 :: Int)]))
    completeJob jobs child.run Succeeded result
    completeJob jobs root.run Succeeded (JobResult "parent ended" Nothing)
    Right (Router.ChildMessage first) <- takeWork jobs
    Right (Router.ChildMessage second) <- takeWork jobs
    [first.text, second.text] `shouldBe` ["first urgent", "second urgent"]
    Right (Router.JobReport childReport) <- takeWork jobs
    childReport.job.run `shouldBe` child.run
    childReport.job.result `shouldBe` Just result
    childReport.job.messages `shouldBe` ["ordinary evidence"]
    Right (Router.JobReport parentReport) <- takeWork jobs
    parentReport.job.run `shouldBe` root.run
    atomically (Router.releaseMessage jobs.resultRouter first >> Router.releaseMessage jobs.resultRouter second >> Router.releaseReport jobs.resultRouter childReport >> Router.releaseReport jobs.resultRouter parentReport)
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing

  it "does not fold or relay child messages already observed by their parent" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    (child, _) <- launch tasks jobs 2 (request {parent = Just root.run})
    tellParent jobs (AgentTurnId 2) "ordinary" False `shouldReturn` Right ()
    tellParent jobs (AgentTurnId 2) "urgent" True `shouldReturn` Right ()
    Just target <- atomically (jobEventTask jobs (AgentTurnId 1))
    events <- atomically (Router.observeEvents jobs.resultRouter target)
    length events `shouldBe` 2
    completeJob jobs child.run Succeeded (JobResult "proof" Nothing)
    completeJob jobs root.run Succeeded (JobResult "done" Nothing)
    Right (Router.JobReport childReport) <- takeWork jobs
    Right (Router.JobReport _) <- takeWork jobs
    childReport.job.messages `shouldBe` []
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing

  it "folds messages in delivery order when the runtime closes before its router cleanup" $ do
    (tasks, jobs, request) <- fixture
    (root, runtime) <- launch tasks jobs 1 request
    (child, _) <- launch tasks jobs 2 (request {parent = Just root.run})
    tellParent jobs (AgentTurnId 2) "before closure" False `shouldReturn` Right ()
    finishTurnRuntime tasks runtime
    tellParent jobs (AgentTurnId 2) "after closure" False `shouldReturn` Right ()
    Just current <- lookupJob jobs request.group child.run.jobId
    current.messages `shouldBe` ["before closure", "after closure"]
    completeJob jobs child.run Succeeded (JobResult "proof" Nothing)
    Right (Router.JobReport report) <- takeWork jobs
    report.job.messages `shouldBe` current.messages

  it "removes revoked messages before observation without discarding a sibling's message" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    _ <- launch tasks jobs 2 (request {parent = Just root.run})
    (sibling, _) <- launch tasks jobs 3 (request {parent = Just root.run})
    tellParent jobs (AgentTurnId 2) "obsolete" False `shouldReturn` Right ()
    tellParent jobs (AgentTurnId 3) "current" False `shouldReturn` Right ()
    replaceJob jobs request.group request.principal False 2 "replacement" `shouldReturn` Right ()
    _ <- atomically (Router.referencedOwners jobs.resultRouter)
    Just target <- atomically (jobEventTask jobs (AgentTurnId 1))
    events <- atomically (Router.observeEvents jobs.resultRouter target)
    map (.body) events `shouldBe` [Events.ChildSaid sibling.run "current" Events.Normal]

  it "resumes a child's original question from its relay after the parent has ended" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    (child, _) <- launch tasks jobs 2 (request {parent = Just root.run})
    completeJob jobs root.run Succeeded (JobResult "done" Nothing)
    Right (Router.JobReport _) <- takeWork jobs
    withAsync (askParent jobs (AgentTurnId 2) "which value?") $ \asking -> do
      Right (Router.ChildMessage relay) <- takeWork jobs
      bindMessageRelay jobs (AgentTurnId 10) relay
      steerJobFrom jobs (Just (AgentTurnId 10)) request.group request.principal Nothing child.run.jobId "42" `shouldReturn` Right ()
      timeout 1000000 (wait asking) `shouldReturn` Just (Right (object ["author" .= request.principal, "source_message" .= (Nothing :: Maybe CanonicalMessageId), "body" .= String "42"]))
      detachJobNotice jobs (AgentTurnId 10)

  it "does not let an earlier question's relay settle a later question" $ do
    (tasks, jobs, request) <- fixture
    (job, _) <- launch tasks jobs 1 request
    withAsync (askParent jobs (AgentTurnId 1) "first?") $ \first -> do
      Right (Router.ChildMessage message) <- takeWork jobs
      bindMessageRelay jobs (AgentTurnId 10) message
      steerJobFrom jobs (Just (AgentTurnId 10)) request.group request.principal Nothing job.run.jobId "one" `shouldReturn` Right ()
      _ <- wait first
      withAsync (askParent jobs (AgentTurnId 1) "second?") $ \second -> do
        Right (Router.ChildMessage next) <- takeWork jobs
        steerJobFrom jobs (Just (AgentTurnId 10)) request.group request.principal Nothing job.run.jobId "old reply" `shouldReturn` Right ()
        timeout 20000 (wait second) `shouldReturn` Nothing
        bindMessageRelay jobs (AgentTurnId 11) next
        steerJobFrom jobs (Just (AgentTurnId 11)) request.group request.principal Nothing job.run.jobId "two" `shouldReturn` Right ()
        timeout 1000000 (wait second) `shouldReturn` Just (Right (object ["author" .= request.principal, "source_message" .= (Nothing :: Maybe CanonicalMessageId), "body" .= String "two"]))

  it "rejects a full relay queue before installing a question and releases capacity by message receipt" $ do
    (tasks, jobs, request) <- fixture
    (job, _) <- launch tasks jobs 1 request
    forM_ [1 .. 1024 :: Int] $ \n -> tellParent jobs (AgentTurnId 1) (T.pack (show n)) True `shouldReturn` Right ()
    tellParent jobs (AgentTurnId 1) "overflow" True `shouldReturnSatisfying` isLeft
    askParent jobs (AgentTurnId 1) "rejected question" `shouldReturnSatisfying` isLeft
    forM_ [1 .. 1024 :: Int] $ \n -> do
      Right (Router.ChildMessage relay) <- takeWork jobs
      relay.text `shouldBe` T.pack (show n)
      atomically (Router.releaseMessage jobs.resultRouter relay)
    withAsync (askParent jobs (AgentTurnId 1) "accepted question") $ \asking -> do
      Right (Router.ChildMessage relay) <- takeWork jobs
      bindMessageRelay jobs (AgentTurnId 10) relay
      steerJobFrom jobs (Just (AgentTurnId 10)) request.group request.principal Nothing job.run.jobId "answer" `shouldReturn` Right ()
      timeout 1000000 (wait asking) >>= (`shouldSatisfy` maybe False isRight)

  it "keeps a retried message owned when the previous relay attempt releases late" $ do
    (tasks, jobs, request) <- fixture
    (job, _) <- launch tasks jobs 1 request
    tellParent jobs (AgentTurnId 1) "need attention" True `shouldReturn` Right ()
    Right (Router.ChildMessage first) <- takeWork jobs
    atomically (Router.requeueMessage jobs.resultRouter first)
    Right (Router.ChildMessage second) <- takeWork jobs
    second.attempt `shouldBe` first.attempt + 1
    atomically (Router.releaseMessage jobs.resultRouter first >> Router.requeueMessage jobs.resultRouter first)
    atomically (Router.messageOwners jobs.resultRouter) `shouldReturn` Set.singleton job.run
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing
    bindMessageRelay jobs (AgentTurnId 10) second
    authorizeJobPublication jobs (AgentTurnId 10) `shouldReturn` True
    detachJobNotice jobs (AgentTurnId 10)
    atomically (Router.messageOwners jobs.resultRouter) `shouldReturn` Set.empty

  it "preserves queued urgent messages across completion and fences them on replacement" $ do
    (tasks, jobs, request) <- fixture
    (job, _) <- launch tasks jobs 1 request
    tellParent jobs (AgentTurnId 1) "need attention" True `shouldReturn` Right ()
    Right (Router.ChildMessage message) <- takeWork jobs
    completeJob jobs job.run Succeeded (JobResult "final" Nothing)
    atomically (Router.messageIsCurrent message) `shouldReturn` True
    atomically (Router.releaseMessage jobs.resultRouter message)
    Right (Router.JobReport relay) <- takeWork jobs
    let body = reportText relay
    body `shouldBe` "final"
    (_, _) <- launch tasks jobs 2 request
    tellParent jobs (AgentTurnId 2) "obsolete" True `shouldReturn` Right ()
    Right (Router.ChildMessage old) <- takeWork jobs
    replaceJob jobs request.group request.principal False 2 "new goal" `shouldReturn` Right ()
    atomically (Router.messageIsCurrent old) `shouldReturn` False

  it "does not attach node events to a runtime that has already ended" $ do
    (tasks, jobs, request) <- fixture
    Right job <- admitJob jobs Nothing 1 request
    Left _ <- takeWork jobs
    runtime <- beginTurnRuntime tasks (reference 1) request.group (UserId 7) Nothing
    finishTurnRuntime tasks runtime
    attachJobTurn jobs job.run (reference 1) `shouldReturn` False

  it "retains a completed child report when the node event buffer is full" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    (child, _) <- launch tasks jobs 2 (request {parent = Just root.run})
    replicateM_ 255 $ steerJob jobs request.group request.principal Nothing 1 "feedback" `shouldReturn` Right ()
    completeJob jobs child.run Succeeded (JobResult "retained report" Nothing)
    first <- observeJobEvents jobs (AgentTurnId 1)
    length first `shouldBe` 200
    second <- observeJobEvents jobs (AgentTurnId 1)
    length second `shouldBe` 56
    T.pack (show second) `shouldSatisfy` T.isInfixOf "retained report"
    observeJobEvents jobs (AgentTurnId 1) `shouldReturn` []

  it "keeps monitor and child progress in status rather than delivering messages" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 (request {monitor = Just (JobMonitor (MonitorId 10) (MonitorFireId 1))})
    reportJobProgress jobs (AgentTurnId 1) "monitor progress" `shouldReturn` True
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing
    (child, _) <- launch tasks jobs 2 (request {parent = Just root.run})
    reportJobProgress jobs (AgentTurnId 2) "child progress" `shouldReturn` True
    Just current <- lookupJob jobs request.group child.run.jobId
    current.progress `shouldBe` Just "child progress"
    observeJobEvents jobs (AgentTurnId 1) `shouldReturn` []
    reportJobProgress jobs (AgentTurnId 2) "child progress" `shouldReturn` True
    observeJobEvents jobs (AgentTurnId 1) `shouldReturn` []
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing

  it "blocks background publication and authorizes its current notice" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    authorizeJobPublication jobs (AgentTurnId 1) `shouldReturn` False
    reportJobProgress jobs (AgentTurnId 1) "progress" `shouldReturn` True
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing
    completeJob jobs root.run Succeeded (JobResult "final" Nothing)
    Right (Router.JobReport relay) <- takeWork jobs
    bindReportRelay jobs (AgentTurnId 10) relay
    authorizeJobPublication jobs (AgentTurnId 10) `shouldReturn` True
    detachJobNotice jobs (AgentTurnId 10)
    fresh <- newJobs tasks
    lookupJob fresh request.group 1 `shouldReturn` Nothing

  it "runs one occurrence per reminder while unrelated reminders and children proceed" $ do
    (tasks, jobs, request) <- fixture
    let reminder fire = request {monitor = Just (JobMonitor (MonitorId 10) (MonitorFireId fire))}
    (first, runtime) <- launch tasks jobs 1 (reminder 1)
    _ <- admitJob jobs Nothing 2 (reminder 2)
    Right other <- admitJob jobs Nothing 3 (request {monitor = Just (JobMonitor (MonitorId 11) (MonitorFireId 3))})
    Left started <- takeWork jobs
    started.run `shouldBe` other.run
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing
    completeJob jobs first.run Succeeded (JobResult "same observation" Nothing)
    Right (Router.MonitorCompleted result) <- takeWork jobs
    result.job.run `shouldBe` first.run
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing
    finishTurnRuntime tasks runtime
    detachJobTurn jobs first.run
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing
    atomically (Router.releaseMonitorResult jobs.resultRouter result)
    Left second <- takeWork jobs
    second.run.jobId `shouldBe` 2

  it "orders monitor completion with reports on the shared delivery queue" $ do
    (_, jobs, request) <- fixture
    Right first <- admitJob jobs Nothing 1 request
    Right monitor <- admitJob jobs Nothing 2 request {monitor = Just (JobMonitor (MonitorId 10) (MonitorFireId 1))}
    completeJob jobs first.run Succeeded (JobResult "ordinary report" Nothing)
    completeJob jobs monitor.run Succeeded (JobResult "business state" Nothing)
    Right (Router.JobReport report) <- takeWork jobs
    Right (Router.MonitorCompleted result) <- takeWork jobs
    report.job.run `shouldBe` first.run
    result.job.run `shouldBe` monitor.run
    atomically (Router.releaseReport jobs.resultRouter report >> Router.releaseMonitorResult jobs.resultRouter result)
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing

  it "retains monitor completion under shared router backpressure without blocking the producer" $ do
    (tasks, jobs, request) <- fixture
    (_, runtime) <- launch tasks jobs 1 request
    let callContext =
          TC.mkToolContext
            (TC.TurnIdentity request.group request.source (UserId 7) (UserId 99) request.principal Nothing Nothing)
            (TC.TurnCapabilities False False False noAdvertisedCaps False Map.empty Nothing False)
    origin <- resultOrigin jobs runtime callContext
    atomically (Router.closeTask jobs.resultRouter origin.target)
    forM_ [1 .. 1024 :: Int] $ \n -> atomically (Router.deliverResult jobs.resultRouter origin (T.pack (show n)) Null [])
    Right monitor <- admitJob jobs Nothing 2 request {monitor = Just (JobMonitor (MonitorId 10) (MonitorFireId 1))}
    timeout 1000000 (completeJob jobs monitor.run Succeeded (JobResult "retained business state" Nothing)) `shouldReturn` Just ()
    replicateM_ 1024 $ do
      Right (Router.NativeResult result) <- takeWork jobs
      atomically (Router.releaseRelay jobs.resultRouter result)
    Right (Router.MonitorCompleted result) <- takeWork jobs
    result.job.result `shouldBe` Just (JobResult "retained business state" Nothing)
    atomically (Router.releaseMonitorResult jobs.resultRouter result)
    timeout 20000 (takeWork jobs) `shouldReturn` Nothing

  it "revokes claimed monitor completion on cancellation and keeps the replacement receipt owned" $ do
    (_, jobs, request) <- fixture
    Right monitor <- admitJob jobs Nothing 1 request {monitor = Just (JobMonitor (MonitorId 10) (MonitorFireId 1))}
    completeJob jobs monitor.run Succeeded (JobResult "obsolete success" Nothing)
    Right (Router.MonitorCompleted old) <- takeWork jobs
    cancelJob jobs request.group request.principal False 1 "cancelled after claim" `shouldReturn` Right ()
    atomically (Router.monitorIsCurrent old) `shouldReturn` False
    Right (Router.MonitorCompleted current) <- takeWork jobs
    current.job.status `shouldBe` Cancelled
    atomically (Router.releaseMonitorResult jobs.resultRouter old)
    atomically (Router.monitorOwners jobs.resultRouter) `shouldReturn` Set.singleton monitor.run
    atomically (Router.releaseMonitorResult jobs.resultRouter current)
    atomically (Router.monitorOwners jobs.resultRouter) `shouldReturn` Set.empty

  it "revokes the previous generation's claimed monitor result on replacement" $ do
    (_, jobs, request) <- fixture
    Right monitor <- admitJob jobs Nothing 1 request {monitor = Just (JobMonitor (MonitorId 10) (MonitorFireId 1))}
    completeJob jobs monitor.run Succeeded (JobResult "old result" Nothing)
    Right (Router.MonitorCompleted old) <- takeWork jobs
    replaceJob jobs request.group request.principal False 1 "new consumer" `shouldReturn` Right ()
    atomically (Router.monitorIsCurrent old) `shouldReturn` False
    Left fresh <- takeWork jobs
    fresh.run.generation `shouldBe` 2
    completeJob jobs fresh.run Succeeded (JobResult "new result" Nothing)
    Right (Router.MonitorCompleted current) <- takeWork jobs
    atomically (Router.releaseMonitorResult jobs.resultRouter old)
    atomically (Router.monitorOwners jobs.resultRouter) `shouldReturn` Set.singleton fresh.run
    atomically (Router.releaseMonitorResult jobs.resultRouter current)

  it "takes over queued and claimed monitor results at shutdown without losing their final state" $ do
    (_, jobs, request) <- fixture
    forM_ [1, 2] $ \identifier -> do
      Right monitor <- admitJob jobs Nothing identifier request {monitor = Just (JobMonitor (MonitorId 10) (MonitorFireId identifier))}
      completeJob jobs monitor.run Succeeded (JobResult "completed before shutdown" Nothing)
    Right (Router.MonitorCompleted claimed) <- takeWork jobs
    notices <- closeJobs jobs
    map (.status) notices `shouldBe` [Succeeded, Succeeded]
    atomically (Router.monitorIsCurrent claimed) `shouldReturn` False
    atomically (Router.monitorOwners jobs.resultRouter) `shouldReturn` Set.empty
    closeJobs jobs `shouldReturn` []

  it "bounds queued jobs and feedback with explicit rejection" $ do
    (_, jobs, request) <- fixture
    forM_ [1 .. 160] $ \identifier -> admitJob jobs Nothing identifier request >>= (`shouldSatisfy` isRight)
    admitJob jobs Nothing 161 request >>= (`shouldSatisfy` isLeft)
    forM_ [1 .. 255 :: Int] $ \_ -> steerJob jobs request.group request.principal Nothing 1 "note" `shouldReturn` Right ()
    steerJob jobs request.group request.principal Nothing 1 "overflow" `shouldReturn` Left "job event log is full or its task has ended"
    steerJob jobs request.group request.principal Nothing 2 (T.replicate 8001 "x") `shouldReturn` Left "feedback exceeds 8000 characters"
    steerJob jobs request.group request.principal Nothing 999 "note" `shouldReturn` Left "no agent#999 in this conversation"
    Just third <- lookupJob jobs request.group 3
    completeJob jobs third.run Succeeded (JobResult "done" Nothing)
    steerJob jobs request.group request.principal Nothing 3 "late" `shouldReturn` Left "agent#3 has already finished"

fixture :: IO (TaskRegistry, Jobs, JobSpec)
fixture = do
  tasks <- newTaskRegistry
  jobs <- newJobs tasks
  now <- getCurrentTime
  pure
    ( tasks,
      jobs,
      JobSpec
        { group = GroupId 1,
          principal = PrincipalId 7,
          source = CanonicalMessageId 10,
          objective = "bounded work",
          profile = Basic,
          grants = Map.empty,
          inputs = Null,
          parent = Nothing,
          contract = Nothing,
          awaited = False,
          monitor = Nothing,
          browserProfile = Nothing,
          deadline = addUTCTime 3600 now
        }
    )

launch :: TaskRegistry -> Jobs -> Int64 -> JobSpec -> IO (JobView, TurnRuntime)
launch tasks jobs identifier request = do
  Right _ <- admitJob jobs Nothing identifier request
  Left job <- takeWork jobs
  runtime <- beginTurnRuntime tasks (reference identifier) request.group (UserId 7) Nothing
  attachJobTurn jobs job.run (reference identifier) `shouldReturn` True
  pure (job, runtime)

reference :: Int64 -> AgentTurnRef
reference identifier = AgentTurnRef (AgentTurnId identifier) (TurnOrdinal identifier)

observeJobEvents :: Jobs -> AgentTurnId -> IO [Value]
observeJobEvents jobs turn = atomically $ do
  flushJobEvents jobs
  target <- jobEventTask jobs turn
  events <- maybe (pure []) (Router.observeEvents jobs.resultRouter) target
  pure [value | event <- events, value <- case event.body of Events.Steered value -> [value]; Events.ChildDone _ value -> [value]; _ -> []]

awaitJobInterrupt :: Jobs -> AgentTurnId -> STM ()
awaitJobInterrupt jobs turn = jobEventTask jobs turn >>= maybe retry (`Events.awaitInterrupt` Events.noPending)

shouldReturnSatisfying :: (Show a) => IO a -> (a -> Bool) -> Expectation
shouldReturnSatisfying action predicate = action >>= (`shouldSatisfy` predicate)

reportText :: Router.ReportRelay -> T.Text
reportText relay = maybe "" (jobReportText relay.job) relay.job.result

takeWork :: Jobs -> IO (Either JobView Router.DeliveryWork)
takeWork jobs = timeout 3000000 (NodeWorkFixture.takeWork jobs) >>= maybe (fail "no job work arrived within three seconds") pure
