module Max.WorkflowAgentSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently)
import Control.Concurrent.Async qualified as Async
import Control.Monad (forM_, replicateM, void)
import Data.Aeson
import Data.Either (isLeft)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple.Types (Only (..), Query)
import Effectful (raise)
import Effectful.PostgreSQL (execute, query)
import ExecutionFixture (echoDefinition, echoTool)
import Helpers (truncateAll, withDb, withDbLog)
import Max.Agent.Execution (ExecutionAdmission (..))
import Max.Agent.Runtime (durableExecutionAdmission)
import Max.CodeMode.Execution
import Max.CodeMode.JavaScript (runJavaScript)
import Max.CodeMode.Wasm (WasmExit (..))
import Max.DB.AgentTurn
import Max.DB.Connection (DbPool)
import Max.DB.Task
import Max.DB.Task.Reporting (submitReportChecked)
import Max.DB.Task.Workflow
import Max.DB.TaskSpec (claimOne, seed)
import Max.DB.TaskSpec qualified as Fixture
import Max.Effects.Tools
import Max.Execution.Tools
import Max.Execution.Types (ExecutionStep (..), StepReservation (..))
import Max.ExecutionSpec (hooks, withHost)
import Max.Platform.Types
import Max.Task.Admission qualified as Admission
import Max.Task.Delegation
import Max.Task.Execution (ExecutionFailure (..))
import Max.Task.State
import Max.Task.Types
import Max.Task.WorkflowRuntime
import Max.Tool.Catalog (catalogTools)
import Max.ToolContext
import Max.Turn.Types
import OneBot.Types (GroupId (..), UserId (..))
import System.Timeout (timeout)
import Test.Hspec hiding (context)

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "ADR015 workflow children" $ do
  it "admits intersected research authority and rejects a wider requested profile before creating a child" $ do
    (_, parent) <- root pool
    entry <- journal pool parent "one"
    withDb pool (beginAgentStep parent.atrTurnId grants Null request {profile = Operations} entry.jeJournalId) `shouldReturn` Left "requested profile exceeds the parent capability ceiling"
    Right step <- withDb pool (beginAgentStep parent.atrTurnId grants Null request entry.jeJournalId)
    rows <- withDb pool (query "SELECT grants FROM durable_tasks WHERE task_id=?" (Only step.childId))
    rows `shouldBe` [Only (toJSON grants)]
    withDb pool (query "SELECT count(*) FROM durable_tasks WHERE parent_task_id IS NOT NULL" ()) `shouldReturn` [Only (1 :: Int64)]
  it "admits the unified browser grant only when its current contract matches the parent" $ do
    (front, message, actor) <- seed pool 900 1
    let browserGrants = Map.insert "browser" "browser/v1" grants
    Right _ <- withDb pool (admitTaskReceipt front message actor "browser-root" "browser audit" Browser (object []) browserGrants)
    parent <- claimOne pool
    entry <- journal pool parent "browser-child"
    forM_ [grants, Map.insert "browser" "changed-contract" grants] $ \current ->
      withDb pool (beginAgentStep parent.atrTurnId current Null request {profile = Browser} entry.jeJournalId) `shouldReturn` Left "requested profile exceeds the parent capability ceiling"
    withDb pool (query "SELECT count(*) FROM durable_tasks WHERE parent_task_id IS NOT NULL" ()) `shouldReturn` [Only (0 :: Int64)]
    Right step <- withDb pool (beginAgentStep parent.atrTurnId browserGrants Null request {profile = Browser} entry.jeJournalId)
    withDb pool (query "SELECT grants FROM durable_tasks WHERE task_id=?" (Only step.childId)) `shouldReturn` [Only (toJSON browserGrants)]
  it "validates payload shape independently of claimed success, then reuses an unchanged settled child" $ do
    (_, parent) <- root pool
    entry <- journal pool parent "first"
    Right step <- withDb pool (beginAgentStep parent.atrTurnId grants Null request entry.jeJournalId)
    child <- claimOne pool
    withDb pool (workflowAllowed child.atrTurnId) `shouldReturn` False
    withDb pool (taskReportTyped child.atrTurnId (Fixture.report ReportSucceeded)) `shouldReturn` False
    withDb pool (taskReportTyped child.atrTurnId (Fixture.report ReportSucceeded) {payload = Just (Number 1)}) `shouldReturn` False
    withDb pool (submitReportChecked child.atrTurnId (Fixture.report ReportSucceeded) {payload = Just (Number 1)}) >>= (`shouldSatisfy` (\case Left (ExecutionInvalidPayload _) -> True; _ -> False))
    withDb pool (taskReportTyped child.atrTurnId (Fixture.report ReportSucceeded) {payload = Just (String "verified")}) `shouldReturn` True
    withDb pool (finishAgentTurn child TurnSucceeded 1 Nothing Nothing)
    Right (Just result) <- withDb pool (pollAgentStep parent.atrTurnId step request.outputContract entry.jeJournalId)
    withDb pool (endAgentWait parent.atrTurnId step)
    withDbLog pool (finishJournalExecution entry (JournalCommitted result))
    again <- journal pool parent "second-program"
    Right cached <- withDb pool (beginAgentStep parent.atrTurnId grants Null request again.jeJournalId)
    cached.cached `shouldBe` Just result
    cached.originalJournal `shouldBe` entry.jeJournalId
    cached.childId `shouldBe` step.childId
    withDb pool (query "SELECT count(*) FROM workflow_agent_waits WHERE child_task_id=?" (Only step.childId)) `shouldReturn` [Only (0 :: Int64)]
    changed <- journal pool parent "changed-step"
    Right new <- withDb pool (beginAgentStep parent.atrTurnId grants Null request {objective = "different question"} changed.jeJournalId)
    new.childId `shouldNotBe` step.childId
    receiptChanged <- journal pool parent "changed-receipt"
    Right updated <- withDb pool (beginAgentStep parent.atrTurnId grants (String "new skill receipt") request receiptChanged.jeJournalId)
    updated.childId `shouldNotBe` step.childId
    narrower <- journal pool parent "narrower-policy"
    Right narrowed <- withDb pool (beginAgentStep parent.atrTurnId (Map.delete "web_search" grants) Null request narrower.jeJournalId)
    narrowed.childId `shouldNotBe` step.childId
    withDb pool (query "SELECT grants FROM durable_tasks WHERE task_id=?" (Only narrowed.childId)) `shouldReturn` [Only (toJSON (Map.delete "web_search" grants))]
  it "does not let an awaited child reopen guest execution through an ordinary grandchild" $ do
    (_, parent) <- root pool
    entry <- journal pool parent "first"
    Right _ <- withDb pool (beginAgentStep parent.atrTurnId grants Null request entry.jeJournalId)
    child <- claimOne pool
    Just execution <- withDb pool (loadTaskExecution child.atrTurnId)
    Right _ <- withDb pool (admitTaskReceipt child execution.teSeed execution.tePrincipal "grandchild" "ordinary child" Research Null grants)
    grandchild <- claimOne pool
    withDb pool (workflowAllowed parent.atrTurnId) `shouldReturn` True
    withDb pool (workflowAllowed child.atrTurnId) `shouldReturn` False
    withDb pool (workflowAllowed grandchild.atrTurnId) `shouldReturn` False
  it "accounts outstanding sibling calls and model rounds against the same root allowance" $ do
    (parentId, parent) <- root pool
    entry <- journal pool parent "a"
    Right _ <- withDb pool (beginAgentStep parent.atrTurnId grants Null request entry.jeJournalId)
    second <- journal pool parent "b"
    Right _ <- withDb pool (beginAgentStep parent.atrTurnId grants Null request {objective = "other"} second.jeJournalId)
    left <- claimOne pool
    right <- claimOne pool
    void $ withDb pool (execute "UPDATE durable_tasks SET max_calls=calls_reserved+1,max_rounds=rounds_reserved+1 WHERE task_id=?" (Only parentId))
    let reserve kind turn = withDb pool (authorizeTaskStep turn.atrTurnId (ExecutionWork kind))
    (a, b) <- concurrently (reserve ReserveCall left) (reserve ReserveCall right)
    length (filter id [a, b]) `shouldBe` 1
    (c, d) <- concurrently (reserve ReserveRound left) (reserve ReserveRound right)
    length (filter id [c, d]) `shouldBe` 1
  it "observes steering before admission without consuming the parent's inbox" $ do
    (parentId, parent) <- root pool
    void $ withDb pool (execute "INSERT INTO task_events(task_id,revision,kind,body) VALUES(?,1,'steer','look at the newer source')" (Only parentId))
    entry <- journal pool parent "steered"
    withDb pool (beginAgentStep parent.atrTurnId grants Null request entry.jeJournalId) `shouldReturn` Left "workflow_steering_pending"
    withDb pool (workflowSteeringPending parent.atrTurnId) `shouldReturn` True
    void $ withDb pool (taskInbox parent.atrTurnId)
    withDb pool (workflowSteeringPending parent.atrTurnId) `shouldReturn` False
    Right _ <- withDb pool (beginAgentStep parent.atrTurnId grants Null request entry.jeJournalId)
    pure ()
  it "joins real JS children, records phases, and reuses only unchanged calls after a source edit" $ do
    (_, parent) <- root pool
    let program second = "max.phase('research'); return max.batch(['first','" <> second <> "'].map(objective=>({agent:{objective,profile:'research'}}))).map(max.value);"
    first <- Async.async (runScript pool parent Nothing (program "second"))
    forM_ [1 :: Int, 2] $ \_ -> settleNext pool
    result <- Async.wait first
    result.cmExit `shouldBe` WasmCompleted
    second <- Async.async (runScript pool parent Nothing (program "changed"))
    settleNext pool
    rerun <- Async.wait second
    rerun.cmExit `shouldBe` WasmCompleted
    withDb pool (query "SELECT count(*) FROM durable_tasks WHERE parent_task_id IS NOT NULL" ()) `shouldReturn` [Only (3 :: Int64)]
    withDb pool (query "SELECT result_inline->>'reused',result_inline->>'original_execution' FROM execution_journal WHERE turn_id=? AND tool_ref='host:workflow_agent/v1' AND result_inline->>'reused'='true'" (Only parent.atrTurnId)) >>= \rows ->
      length (rows :: [(Text, Text)]) `shouldBe` 1
    withDb pool (query "SELECT count(DISTINCT normalized_input->>'source_fingerprint') FROM execution_journal WHERE turn_id=? AND tool_ref='host:workflow_agent/v1'" (Only parent.atrTurnId)) `shouldReturn` [Only (2 :: Int64)]
    withDb pool (query "SELECT count(*) FROM task_progress" ()) `shouldReturn` [Only (1 :: Int64)]
    withDb pool (query "SELECT count(*) FROM workflow_agent_waits" ()) `shouldReturn` [Only (0 :: Int64)]
  it "rejects an over-budget agent batch atomically before any child admission" $ do
    (_, parent) <- root pool
    result <- runScript pool parent (Just 1) "return max.batch(['one','two'].map(objective=>({agent:{objective,profile:'research'}})));"
    result.cmOverBudget `shouldBe` True
    withDb pool (query "SELECT count(*) FROM durable_tasks WHERE parent_task_id IS NOT NULL" ()) `shouldReturn` [Only (0 :: Int64)]
  it "cancels an awaiting guest without leaking a wait or admitting its next step" $ do
    (_, parent) <- root pool
    running <- Async.async (runScript pool parent Nothing "agent({objective:'one',profile:'research'}); agent({objective:'unreachable',profile:'research'});")
    waitFor pool "SELECT count(*) FROM workflow_agent_waits" 1
    timeout 3000000 (Async.cancel running) `shouldReturn` Just ()
    withDb pool (query "SELECT count(*) FROM workflow_agent_waits" ()) `shouldReturn` [Only (0 :: Int64)]
    withDb pool (query "SELECT count(*) FROM durable_tasks WHERE parent_task_id IS NOT NULL" ()) `shouldReturn` [Only (1 :: Int64)]
    withDb pool (query "SELECT count(*) FROM workflow_agent_steps WHERE result IS NOT NULL" ()) `shouldReturn` [Only (0 :: Int64)]
  it "stops real guest code when steering arrives during a child wait and leaves the inbox unread" $ do
    (parentId, parent) <- root pool
    running <- Async.async (runScript pool parent Nothing "agent({objective:'one',profile:'research'}); agent({objective:'unreachable',profile:'research'});")
    waitFor pool "SELECT count(*) FROM workflow_agent_waits" 1
    void $ withDb pool (execute "INSERT INTO task_events(task_id,revision,kind,body) VALUES(?,1,'steer','use newer evidence')" (Only parentId))
    settled <- timeout 3000000 (Async.wait running)
    fmap (.cmExit) settled `shouldBe` Just WasmHostStopped
    withDb pool (workflowSteeringPending parent.atrTurnId) `shouldReturn` True
    withDb pool (query "SELECT count(*) FROM durable_tasks WHERE parent_task_id IS NOT NULL" ()) `shouldReturn` [Only (1 :: Int64)]
    withDb pool (query "SELECT count(*) FROM workflow_agent_waits" ()) `shouldReturn` [Only (0 :: Int64)]
  it "lets children run when all ten owner slots are awaiting and counts resumed parents again" $ do
    forM_ [1 .. 10 :: Int] $ \n -> do
      (front, message, actor) <- seed pool 900 (fromIntegral n)
      Right _ <- withDb pool (admitTaskReceipt front message actor (T.pack (show n)) "root" Research (object []) grants)
      pure ()
    parents <- replicateM 10 (claimOne pool)
    forM_ parents $ \parent -> do
      entry <- journal pool parent "awaiting"
      Right _ <- withDb pool (beginAgentStep parent.atrTurnId grants Null request entry.jeJournalId)
      pure ()
    children <- withDb pool (query "SELECT count(*) FROM durable_tasks WHERE status='running'" ())
    children `shouldBe` [Only (10 :: Int64)]
    child <- claimOne pool
    withDb pool (workflowAllowed child.atrTurnId) `shouldReturn` False
    void $ withDb pool (execute "DELETE FROM workflow_agent_waits" ())
    withDb pool (claimTask "capacity-test") `shouldReturn` []
  it "never serves a cached report after the parent or child generation is invalidated" $ do
    (parentId, parent) <- root pool
    entry <- journal pool parent "first"
    Right step <- withDb pool (beginAgentStep parent.atrTurnId grants Null request entry.jeJournalId)
    child <- claimOne pool
    withDb pool (taskReportTyped child.atrTurnId (Fixture.report ReportSucceeded) {payload = Just (String "verified")}) `shouldReturn` True
    withDb pool (finishAgentTurn child TurnSucceeded 1 Nothing Nothing)
    Right result <- withDb pool (pollAgentStep parent.atrTurnId step request.outputContract entry.jeJournalId)
    result `shouldSatisfy` isJust
    void $ withDb pool (execute "UPDATE durable_tasks SET revision=revision+1 WHERE task_id=?" (Only step.childId))
    withDb pool (beginAgentStep parent.atrTurnId grants Null request entry.jeJournalId) >>= (`shouldSatisfy` isLeft)
    void $ withDb pool (execute "UPDATE durable_tasks SET status='cancelled' WHERE task_id=?" (Only parentId))
    withDb pool (beginAgentStep parent.atrTurnId grants Null request entry.jeJournalId) >>= (`shouldSatisfy` isLeft)

grants :: Map.Map Text Text
grants = Map.fromList [("task_start", "start/v1"), ("web_search", "search/v1")]

request :: AgentRequest
request = AgentRequest "bounded question" (object ["source" .= ("provided evidence" :: Text)]) Research (Just (object ["type" .= ("string" :: Text)]))

root :: DbPool -> IO (Int64, AgentTurnRef)
root pool = do
  (front, message, actor) <- seed pool 900 1
  Right admitted <- withDb pool (admitTaskReceipt front message actor "root" "research" Research (object []) grants)
  parent <- claimOne pool
  pure (Admission.taskId admitted, parent)

journal :: DbPool -> AgentTurnRef -> Text -> IO JournalExecution
journal pool parent key = do
  Just entry <- withDb pool (durableExecutionAdmission.eaStartTool (GroupId 900) parent (ExecutionWork ReserveCall) (JournalStart key "host:workflow_agent/v1" 1 "agent/v1" (object []) (toJSON (["task"] :: [Text])) "idempotent"))
  pure entry

runScript :: DbPool -> AgentTurnRef -> Maybe Int -> Text -> IO CodeModeResult
runScript pool parent budget source = do
  output <- newTurnOutputContext parent
  Just execution <- withDb pool (loadTaskExecution parent.atrTurnId)
  let context = mkToolContext (TurnIdentity (GroupId 900) execution.teSeed (UserId 1) (UserId 3) execution.tePrincipal Nothing (Just output)) (TurnCapabilities False False True noAdvertisedCaps False grants (Just grants) True)
      bound = (hooks parent) {ehWorkflow = Just (taskWorkflowHost context parent)}
      definitions = [echoDefinition {tdRef = ToolRef name} | name <- ["task_start", "task_progress"]]
      runners = [echoTool {toolName = name} | name <- ["task_start", "task_progress"]]
  registry <- either (fail . show) pure (buildToolRegistry definitions runners)
  withHost pool . runTools registry $ do
    session <- newExecutionSession budget
    runJavaScript session (hoistExecutionHooks raise bound) (catalogTools (registryCatalog registry)) source

waitFor :: DbPool -> Query -> Int64 -> IO ()
waitFor pool statement expected = do
  let loop = do
        rows <- withDb pool (query statement ())
        if rows == [Only expected] then pure () else threadDelay 10000 >> loop
  timeout 30000000 loop `shouldReturn` Just ()

settleNext :: DbPool -> IO ()
settleNext pool = do
  let next = do
        turns <- withDb pool (claimTask "workflow-test")
        case turns of
          [identifier] -> do
            Just child <- withDb pool (taskTurnRef identifier)
            withDb pool (taskReportTyped child.atrTurnId (Fixture.report ReportSucceeded)) `shouldReturn` True
            withDb pool (finishAgentTurn child TurnSucceeded 1 Nothing Nothing)
          _ -> threadDelay 10000 >> next
  timeout 30000000 next `shouldReturn` Just ()
