module Max.JobsSpec (Max.JobsSpec.spec) where

import Control.Concurrent.Async (mapConcurrently, wait, withAsync)
import Control.Monad (forM_, replicateM)
import Data.Aeson (Value (..), object, (.=))
import Data.Either (isLeft, isRight)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Time (addUTCTime, getCurrentTime)
import Max.Execution.Types (ExecutionStep (..), StepReservation (..))
import Max.Jobs
import Max.Monitor.Types (MonitorFireId (..), MonitorId (..))
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..))
import Max.Task.State
import Max.Task.Types (JobMonitor (..), TaskProfile (..))
import Max.Tasks
import Max.Turn.Types
import OneBot.Types (GroupId (..), UserId (..))
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "process-owned Jobs" $ do
  it "keeps detached jobs after their initiating reply and binds status to a conversation" $ do
    (tasks, jobs, request) <- fixture
    source <- beginDurableTurnRuntime tasks (reference 99) request.group (UserId 7) Nothing
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
    reserved <- mapConcurrently (\n -> authorizeJobStep jobs (AgentTurnId (if even n then 2 else 3)) (ExecutionWork ReserveCall)) [1 .. 260 :: Int]
    length (filter id reserved) `shouldBe` 200
    Just budget <- lookupJob jobs request.group 1
    budget.calls `shouldBe` 200
    rounds <- replicateM 400 (authorizeJobStep jobs (AgentTurnId 1) (ExecutionWork ReserveRound))
    and rounds `shouldBe` True
    authorizeJobStep jobs (AgentTurnId 1) (ExecutionWork ReserveRound) `shouldReturn` False
    authorizeJobStep jobs (AgentTurnId 1) ExecutionCheckpoint `shouldReturn` True
    completeJob jobs budget.run Failed (JobResult "budget spent" Nothing)
    fmap (fmap (.status)) (lookupJob jobs request.group 1) `shouldReturn` Just BudgetExhausted

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

  it "delivers child cancellation and inherits delegation restrictions" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 (request {delegated = True})
    Right child <- admitJob jobs Nothing 2 (request {parent = Just root.run})
    child.spec.delegated `shouldBe` True
    cancelJob jobs request.group request.principal False 2 "cancel child" `shouldReturn` Right ()
    Right (ChildrenFinished [cancelled]) <- waitForChildren jobs (AgentTurnId 1) []
    cancelled.status `shouldBe` Cancelled
    notes <- readJobInbox jobs (AgentTurnId 1)
    notes `shouldBe` [object ["child_update" .= cancelled]]

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

  it "coalesces progress and supersedes queued notices without suppressing the final result" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    reportJobProgress jobs (AgentTurnId 1) "first" `shouldReturn` True
    PublishJobNotice first version "first" <- takeJobWork jobs
    bindJobNotice jobs (AgentTurnId 10) first.run version
    reportJobProgress jobs (AgentTurnId 1) "latest" `shouldReturn` True
    reportJobProgress jobs (AgentTurnId 1) "latest" `shouldReturn` True
    authorizeJobPublication jobs (AgentTurnId 10) `shouldReturn` False
    timeout 20000 (takeJobWork jobs) `shouldReturn` Nothing
    completeJob jobs root.run Succeeded (JobResult "final" Nothing)
    detachJobNotice jobs (AgentTurnId 10)
    PublishJobNotice final finalVersion body <- takeJobWork jobs
    final.status `shouldBe` Succeeded
    body `shouldBe` "final"
    noticeIsCurrent jobs final.run finalVersion `shouldReturn` True

  it "blocks background publication and tracks notice replies without reviving old work" $ do
    (tasks, jobs, request) <- fixture
    (root, _) <- launch tasks jobs 1 request
    authorizeJobPublication jobs (AgentTurnId 1) `shouldReturn` False
    reportJobProgress jobs (AgentTurnId 1) "progress" `shouldReturn` True
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
    steerJob jobs request.group request.principal Nothing 1 "overflow" >>= (`shouldSatisfy` isLeft)

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
          profile = Research,
          grants = Map.empty,
          inputs = Null,
          parent = Nothing,
          contract = Nothing,
          delegated = False,
          monitor = Nothing,
          browserProfile = Nothing,
          deadline = addUTCTime 3600 now
        }
    )

launch :: TaskRegistry -> Jobs -> Int64 -> JobSpec -> IO (JobView, TurnRuntime)
launch tasks jobs identifier request = do
  Right _ <- admitJob jobs Nothing identifier request
  LaunchJob job <- takeJobWork jobs
  runtime <- beginDurableTurnRuntime tasks (reference identifier) request.group (UserId 7) Nothing
  attachJobTurn jobs job.run (reference identifier) `shouldReturn` True
  pure (job, runtime)

reference :: Int64 -> AgentTurnRef
reference identifier = AgentTurnRef (AgentTurnId identifier) (TurnOrdinal identifier)
