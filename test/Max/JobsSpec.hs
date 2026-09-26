module Max.JobsSpec (Max.JobsSpec.spec) where

import Control.Concurrent.Async (mapConcurrently, wait, withAsync)
import Control.Monad (forM_, replicateM)
import Data.Aeson (Value (..), object, (.=))
import Data.Either (isLeft, isRight)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, isJust, isNothing)
import Data.Text qualified as T
import Data.Time (addUTCTime, getCurrentTime)
import Max.Execution.Types (Admission (..), ExecutionStep (..), StepReservation (..))
import Max.Jobs
import Max.LLM.Types (CallCost (..), TokenUsage (..))
import Max.Monitor.Types (MonitorFireId (..), MonitorId (..))
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..))
import Max.Task.Policy (treeModelRounds, treeToolCalls)
import Max.Task.State
import Max.Task.Types (JobMonitor (..), JobUsage (..), TaskProfile (..), jobUsageLine)
import Max.Tasks
import Max.Turn.Types
import OneBot.Types (GroupId (..), UserId (..))
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "process-owned Jobs" $ do
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
    _ <- takeJobWork jobs
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
    timeout 20_000 (takeJobWork jobs) `shouldReturn` Nothing
    closeJobs jobs `shouldReturn` []

  it "includes an unclaimed final result but does not replay a notice already publishing" $ do
    (tasks, jobs, request) <- fixture
    (first, _) <- launch tasks jobs 1 request
    (second, _) <- launch tasks jobs 2 request
    completeJob jobs first.run Succeeded (JobResult "first result" Nothing)
    PublishJobNotice sending version _ <- takeJobWork jobs
    bindJobNotice jobs (AgentTurnId 10) sending.run version
    completeJob jobs second.run Succeeded (JobResult "second result" Nothing)
    notices <- closeJobs jobs
    map (.run.jobId) notices `shouldBe` [2]
    map (.result) notices `shouldBe` [Just (JobResult "second result" Nothing)]
    authorizeJobPublication jobs (AgentTurnId 10) `shouldReturn` True

  it "takes over a final notice claimed just before shutdown admission closes" $ do
    (tasks, jobs, request) <- fixture
    (job, _) <- launch tasks jobs 1 request
    completeJob jobs job.run Succeeded (JobResult "result" Nothing)
    PublishJobNotice sending version _ <- takeJobWork jobs
    notices <- closeJobs jobs
    map (.run.jobId) notices `shouldBe` [1]
    bindJobNotice jobs (AgentTurnId 10) sending.run version
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
    PublishJobNotice finished _ _ <- takeJobWork jobs
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
      LaunchJob started <- takeJobWork jobs
      started.run `shouldBe` child.run
      completeJob jobs child.run Succeeded (JobResult "child result" Nothing)
      Right (ChildrenFinished [result]) <- wait joining
      result.result `shouldBe` Just (JobResult "child result" Nothing)
    notes <- readJobInbox jobs (AgentTurnId 1)
    length notes `shouldBe` 1
    readJobInbox jobs (AgentTurnId 1) `shouldReturn` []
    timeout 20000 (takeJobWork jobs) `shouldReturn` Nothing

  it "wakes waits for attributed feedback and refuses another job's children" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    _ <- admitJob jobs Nothing 2 (request {parent = Just root.run})
    withAsync (waitForChildren jobs (AgentTurnId 1) [2]) $ \joining -> do
      steerJob jobs request.group (PrincipalId 8) (Just (CanonicalMessageId 55)) 1 "new evidence" `shouldReturn` Right ()
      wait joining `shouldReturn` Right FeedbackPending
    readJobInbox jobs (AgentTurnId 1) `shouldReturn` [object ["author" .= PrincipalId 8, "source_message" .= CanonicalMessageId 55, "body" .= String "new evidence"]]
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
    notes <- readJobInbox jobs (AgentTurnId 1)
    notes `shouldBe` [object ["child_update" .= cancelled]]

  it "returns an awaited root's report to the waiting turn instead of a relay notice" $ do
    (tasks, jobs, request) <- fixture
    caller <- beginTurnRuntime tasks (reference 99) request.group (UserId 7) Nothing
    Right admitted <- admitJob jobs (Just (AgentTurnId 99)) 1 (request {awaited = True})
    LaunchJob job <- takeJobWork jobs
    withAsync (awaitJob jobs (AgentTurnId 99) admitted.run) $ \waiting -> do
      completeJob jobs job.run Succeeded (JobResult "report" Nothing)
      Right finished <- wait waiting
      finished.result `shouldBe` Just (JobResult "report" Nothing)
    timeout 20_000 (takeJobWork jobs) `shouldReturn` Nothing
    finishTurnRuntime tasks caller

  it "relays a report its waiter collected only after the report was ready" $ do
    (tasks, jobs, request) <- fixture
    caller <- beginTurnRuntime tasks (reference 99) request.group (UserId 7) Nothing
    Right admitted <- admitJob jobs (Just (AgentTurnId 99)) 1 (request {awaited = True})
    LaunchJob job <- takeJobWork jobs
    completeJob jobs job.run Succeeded (JobResult "ready" Nothing)
    timeout 20_000 (takeJobWork jobs) `shouldReturn` Nothing
    _ <- cancelAgentTurnTask tasks (AgentTurnId 99)
    awaitJob jobs (AgentTurnId 99) admitted.run `shouldThrow` (\TaskCancelled -> True)
    PublishJobNotice noticed _ body <- takeJobWork jobs
    (noticed.run, body) `shouldBe` (admitted.run, "ready")
    finishTurnRuntime tasks caller

  it "relays an awaited root's report once its waiter stops waiting" $ do
    (tasks, jobs, request) <- fixture
    caller <- beginTurnRuntime tasks (reference 99) request.group (UserId 7) Nothing
    Right first <- admitJob jobs (Just (AgentTurnId 99)) 1 (request {awaited = True})
    Right second <- admitJob jobs (Just (AgentTurnId 99)) 2 (request {awaited = True})
    LaunchJob running <- takeJobWork jobs
    LaunchJob _ <- takeJobWork jobs
    -- Abandoned while running: the report is relayed when it arrives.
    withAsync (awaitJob jobs (AgentTurnId 99) first.run) $ \waiting -> do
      cancelAgentTurnTask tasks (AgentTurnId 99) `shouldReturn` True
      wait waiting `shouldThrow` (\TaskCancelled -> True)
    completeJob jobs running.run Succeeded (JobResult "late report" Nothing)
    PublishJobNotice noticed _ body <- takeJobWork jobs
    (noticed.run, body) `shouldBe` (first.run, "late report")
    -- Its waiter ended without ever waiting: relayed as soon as it finishes.
    completeJob jobs second.run Succeeded (JobResult "unread report" Nothing)
    PublishJobNotice unread _ text <- takeJobWork jobs
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
    timeout 20000 (takeJobWork jobs) `shouldReturn` Nothing
    finishTurnRuntime tasks runtime
    detachJobTurn jobs root.run
    LaunchJob replacement <- takeJobWork jobs
    replacement.run.generation `shouldBe` 2
    replacement.calls `shouldBe` 1
    replacement.spec.deadline `shouldBe` root.spec.deadline
    completeJob jobs root.run Succeeded (JobResult "obsolete" Nothing)
    lookupJob jobs request.group 1 `shouldReturn` Just replacement

  it "keeps replaced child handles joinable by their parent" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    Right child <- admitJob jobs Nothing 2 (request {parent = Just root.run})
    replaceJob jobs request.group request.principal False 2 "new child" `shouldReturn` Right ()
    LaunchJob replacement <- takeJobWork jobs
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

  it "keeps root progress internal without suppressing the final result" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    reportJobProgress jobs (AgentTurnId 1) "first" `shouldReturn` True
    timeout 20000 (takeJobWork jobs) `shouldReturn` Nothing
    reportJobProgress jobs (AgentTurnId 1) "latest" `shouldReturn` True
    reportJobProgress jobs (AgentTurnId 1) "latest" `shouldReturn` True
    Just current <- lookupJob jobs request.group root.run.jobId
    current.progress `shouldBe` Just "latest"
    timeout 20000 (takeJobWork jobs) `shouldReturn` Nothing
    completeJob jobs root.run Succeeded (JobResult "final" Nothing)
    PublishJobNotice final finalVersion body <- takeJobWork jobs
    final.status `shouldBe` Succeeded
    body `shouldBe` "final"
    noticeIsCurrent jobs final.run finalVersion `shouldReturn` True

  it "keeps monitor progress internal and still notifies parents of child progress" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 (request {monitor = Just (JobMonitor (MonitorId 10) (MonitorFireId 1))})
    reportJobProgress jobs (AgentTurnId 1) "monitor progress" `shouldReturn` True
    timeout 20000 (takeJobWork jobs) `shouldReturn` Nothing
    (child, _) <- launch tasks jobs 2 (request {parent = Just root.run})
    reportJobProgress jobs (AgentTurnId 2) "child progress" `shouldReturn` True
    Just current <- lookupJob jobs request.group child.run.jobId
    current.progress `shouldBe` Just "child progress"
    readJobInbox jobs (AgentTurnId 1) `shouldReturn` [object ["child_update" .= current]]
    reportJobProgress jobs (AgentTurnId 2) "child progress" `shouldReturn` True
    readJobInbox jobs (AgentTurnId 1) `shouldReturn` []
    timeout 20000 (takeJobWork jobs) `shouldReturn` Nothing

  it "blocks background publication and tracks notice replies without reviving old work" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    authorizeJobPublication jobs (AgentTurnId 1) `shouldReturn` False
    reportJobProgress jobs (AgentTurnId 1) "progress" `shouldReturn` True
    timeout 20000 (takeJobWork jobs) `shouldReturn` Nothing
    completeJob jobs root.run Succeeded (JobResult "final" Nothing)
    PublishJobNotice _ version _ <- takeJobWork jobs
    bindJobNotice jobs (AgentTurnId 10) root.run version
    authorizeJobPublication jobs (AgentTurnId 10) `shouldReturn` True
    recordJobPublication jobs (AgentTurnId 10) (CanonicalMessageId 20)
    detachJobNotice jobs (AgentTurnId 10)
    taskForReply jobs request.group (CanonicalMessageId 20) `shouldReturn` Just 1
    taskForReply jobs (GroupId 9) (CanonicalMessageId 20) `shouldReturn` Nothing
    fresh <- newJobs tasks
    lookupJob fresh request.group 1 `shouldReturn` Nothing
    taskForReply fresh request.group (CanonicalMessageId 20) `shouldReturn` Nothing

  it "runs one occurrence per reminder while unrelated reminders and children proceed" $ do
    (tasks, jobs, request) <- fixture
    let reminder fire = request {monitor = Just (JobMonitor (MonitorId 10) (MonitorFireId fire))}
    (first, runtime) <- launch tasks jobs 1 (reminder 1)
    _ <- admitJob jobs Nothing 2 (reminder 2)
    Right other <- admitJob jobs Nothing 3 (request {monitor = Just (JobMonitor (MonitorId 11) (MonitorFireId 3))})
    LaunchJob started <- takeJobWork jobs
    started.run `shouldBe` other.run
    timeout 20000 (takeJobWork jobs) `shouldReturn` Nothing
    completeJob jobs first.run Succeeded (JobResult "same observation" Nothing)
    RecordMonitorResult result <- takeJobWork jobs
    result.run `shouldBe` first.run
    timeout 20000 (takeJobWork jobs) `shouldReturn` Nothing
    finishTurnRuntime tasks runtime
    detachJobTurn jobs first.run
    LaunchJob second <- takeJobWork jobs
    second.run.jobId `shouldBe` 2

  it "bounds queued jobs and feedback with explicit rejection" $ do
    (_, jobs, request) <- fixture
    forM_ [1 .. 160] $ \identifier -> admitJob jobs Nothing identifier request >>= (`shouldSatisfy` isRight)
    admitJob jobs Nothing 161 request >>= (`shouldSatisfy` isLeft)
    forM_ [1 .. 256 :: Int] $ \_ -> steerJob jobs request.group request.principal Nothing 1 "note" `shouldReturn` Right ()
    steerJob jobs request.group request.principal Nothing 1 "overflow" `shouldReturn` Left "job feedback inbox is full"
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
  LaunchJob job <- takeJobWork jobs
  runtime <- beginTurnRuntime tasks (reference identifier) request.group (UserId 7) Nothing
  attachJobTurn jobs job.run (reference identifier) `shouldReturn` True
  pure (job, runtime)

reference :: Int64 -> AgentTurnRef
reference identifier = AgentTurnRef (AgentTurnId identifier) (TurnOrdinal identifier)
