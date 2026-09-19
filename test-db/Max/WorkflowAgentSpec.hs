module Max.WorkflowAgentSpec (Max.WorkflowAgentSpec.spec) where

import Control.Concurrent.Async qualified as Async
import Control.Monad (forM_)
import Data.Aeson
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Database.PostgreSQL.Simple (Only (..))
import Effectful (raise)
import Effectful.PostgreSQL (query)
import ExecutionFixture (echoDefinition, echoTool)
import Helpers (truncateAll, withDb)
import JobFixture
import Max.CodeMode.Execution
import Max.CodeMode.JavaScript (runJavaScript)
import Max.CodeMode.Wasm (WasmExit (..))
import Max.DB.Connection (DbPool)
import Max.Effects.Tools
import Max.Execution.Tools
import Max.Execution.Workflow (WorkflowHost (..))
import Max.ExecutionSpec (hooks, withHost)
import Max.Jobs qualified as Jobs
import Max.Platform.Types (noAdvertisedCaps)
import Max.Task.Delegation (parseJobResult)
import Max.Task.State (TaskStatus (Succeeded))
import Max.Task.Types
import Max.Task.WorkflowRuntime
import Max.Tool.Catalog (catalogTools)
import Max.ToolContext
import Max.Turn.Types
import OneBot.Types (GroupId (..), UserId (..))
import System.Timeout (timeout)
import Test.Hspec hiding (context)

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "process-owned workflow children" $ do
  it "admits ordinary children without a durable journal or model key" $ do
    running <- runningJob pool Research workflowGrants
    context <- toolContext running workflowGrants
    let host = taskWorkflowHost running.jobs context running.turn
        request = object ["objective" .= ("answer" :: Text), "profile" .= ("research" :: Text), "output_contract" .= object ["type" .= ("string" :: Text)]]
    Async.withAsync (withDb pool (host.whAgent request)) $ \waiting -> do
      child <- awaitChild running.jobs
      child.spec.grants `shouldBe` workflowGrants
      Right result <- pure (parseJobResult child.spec "\"answer\"")
      Jobs.completeJob running.jobs child.run Succeeded result
      returned <- Async.wait waiting
      returned.tiOutcome `shouldSatisfy` (\case ToolCommitted _ -> True; _ -> False)
    withDb pool (query "SELECT count(*) FROM workflow_agent_steps" ()) `shouldReturn` [Only (0 :: Int)]

  it "rejects wider profiles and changed tool contracts before starting children" $ do
    forM_ [(Browser, "browser"), (Sandbox, "sandbox_exec")] $ \(profile, tool) -> do
      running <- runningJob pool profile (Map.insert tool "v1" workflowGrants)
      forM_ [workflowGrants, Map.insert tool "changed" workflowGrants] $ \current -> do
        context <- toolContext running current
        let host = taskWorkflowHost running.jobs context running.turn
        result <- withDb pool (host.whAgent (object ["objective" .= ("inspect" :: Text), "profile" .= profileName profile]))
        result.tiOutcome `shouldSatisfy` (\case ToolRejected _ -> True; _ -> False)
      jobs <- Jobs.allJobs running.jobs
      length jobs `shouldBe` 1

  it "joins real JavaScript batches and starts explicit new calls when a program is rerun" $ do
    running <- runningJob pool Research workflowGrants
    let program = "max.phase('research'); return max.batch(['first','second'].map(objective=>({agent:{objective,profile:'research'}}))).map(max.value);"
    forM_ [1 .. 2 :: Int] $ \_ -> Async.withAsync (runScript pool running Nothing program) $ \worker -> do
      first <- awaitChild running.jobs
      second <- awaitChild running.jobs
      forM_ [first, second] $ \child -> Jobs.completeJob running.jobs child.run Succeeded (JobResult child.spec.objective Nothing)
      result <- Async.wait worker
      result.cmExit `shouldBe` WasmCompleted
    jobs <- Jobs.allJobs running.jobs
    length [job | job <- jobs, job.spec.parent == Just running.job.run] `shouldBe` 4
    withDb pool (query "SELECT count(*) FROM workflow_agent_waits" ()) `shouldReturn` [Only (0 :: Int)]

  it "rejects an over-budget batch before child admission" $ do
    running <- runningJob pool Research workflowGrants
    result <- runScript pool running (Just 1) "return max.batch(['one','two'].map(objective=>({agent:{objective,profile:'research'}})));"
    result.cmOverBudget `shouldBe` True
    Jobs.allJobs running.jobs >>= (\jobs -> length jobs `shouldBe` 1)

  it "stops guest code on feedback, retains the child, and leaves feedback for the model" $ do
    running <- runningJob pool Research workflowGrants
    Async.withAsync (runScript pool running Nothing "agent({objective:'one',profile:'research'}); agent({objective:'unreachable',profile:'research'});") $ \worker -> do
      _ <- awaitChild running.jobs
      Jobs.steerJob running.jobs running.job.spec.group running.job.spec.principal Nothing running.job.run.jobId "new evidence" `shouldReturn` Right ()
      result <- timeout 3000000 (Async.wait worker)
      fmap (.cmExit) result `shouldBe` Just WasmHostStopped
    Jobs.jobHasFeedback running.jobs running.turn.atrTurnId `shouldReturn` True
    Jobs.allJobs running.jobs >>= (\jobs -> length jobs `shouldBe` 2)

  it "does not admit a child when feedback was already pending" $ do
    running <- runningJob pool Research workflowGrants
    Jobs.steerJob running.jobs running.job.spec.group running.job.spec.principal Nothing running.job.run.jobId "wait" `shouldReturn` Right ()
    result <- runScript pool running Nothing "agent({objective:'unreachable',profile:'research'});"
    result.cmExit `shouldBe` WasmHostStopped
    Jobs.allJobs running.jobs >>= (\jobs -> length jobs `shouldBe` 1)

  it "cancels an awaiting guest without executing its next step" $ do
    running <- runningJob pool Research workflowGrants
    Async.withAsync (runScript pool running Nothing "agent({objective:'one',profile:'research'}); agent({objective:'unreachable',profile:'research'});") $ \worker -> do
      _ <- awaitChild running.jobs
      timeout 3000000 (Async.cancel worker) `shouldReturn` Just ()
    Jobs.allJobs running.jobs >>= (\jobs -> length jobs `shouldBe` 2)

awaitChild :: Jobs.Jobs -> IO JobView
awaitChild jobs = do
  next <- timeout 30000000 (Jobs.takeJobWork jobs)
  case next of
    Just (Jobs.LaunchJob child) -> pure child
    Just (Jobs.PublishJobNotice job _ _) -> Jobs.releaseJobNotice jobs job.run >> awaitChild jobs
    _ -> fail "workflow child did not start"

workflowGrants :: Map.Map Text Text
workflowGrants = Map.fromList [("task_start", "v1"), ("web_search", "v1")]

toolContext :: RunningJob -> Map.Map Text Text -> IO ToolContext
toolContext running current = do
  output <- newTurnOutputContext running.turn
  pure (mkToolContext (TurnIdentity (GroupId 900) running.job.spec.source (UserId 1) (UserId 3) running.job.spec.principal Nothing (Just output)) (TurnCapabilities False False True noAdvertisedCaps False current (Just current) True))

runScript :: DbPool -> RunningJob -> Maybe Int -> Text -> IO CodeModeResult
runScript pool running budget source = do
  context <- toolContext running workflowGrants
  let bound = (hooks running.jobs running.runtime) {ehWorkflow = Just (taskWorkflowHost running.jobs context running.turn)}
      definitions = [echoDefinition {tdRef = ToolRef name} | name <- ["task_start", "task_progress"]]
      runners = [echoTool {toolName = name} | name <- ["task_start", "task_progress"]]
  registry <- either (fail . show) pure (buildToolRegistry definitions runners)
  withHost pool . runTools registry $ do
    session <- newExecutionSession budget
    runJavaScript session (hoistExecutionHooks raise bound) (catalogTools (registryCatalog registry)) source
