module Max.WorkflowAgentSpec (Max.WorkflowAgentSpec.spec) where

import Control.Concurrent.Async qualified as Async
import Control.Monad (forM_)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Database.PostgreSQL.Simple (Only (..))
import Effectful (raise)
import Effectful.PostgreSQL (query)
import Helpers (truncateAll, withDb)
import JobFixture
import Max.CodeMode.Execution
import Max.CodeMode.JavaScript (runJavaScript)
import Max.CodeMode.Wasm (WasmExit (..))
import Max.DB.Connection (DbPool)
import Max.Effects.Tools
import Max.Execution.Tools
import Max.ExecutionSpec (hooks, withHost)
import Max.Jobs qualified as Jobs
import Max.Platform.Types (CanonicalMessageId, PrincipalId, noAdvertisedCaps)
import Max.Task.Delegation (parseJobResult)
import Max.Task.State (TaskStatus (Succeeded))
import Max.Task.ToolRuntime (taskTools)
import Max.Task.Types
import Max.Task.WorkflowRuntime
import Max.Tasks (TurnRuntime, beginTurnRuntime)
import Max.Tool.Catalog (catalogTools)
import Max.ToolContext
import Max.Turn.Types
import OneBot.Types (GroupId (..), UserId (..))
import System.Timeout (timeout)
import Test.Hspec hiding (context)

-- agent() is the ordinary agent tool with wait; these run it for real,
-- through the same registry, admission and Jobs as a model's native call.
spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "agent() through the agent tool" $ do
  it "waits for an ordinary child and returns its checked report" $ do
    running <- runningJob pool Basic workflowGrants
    Async.withAsync (runScript pool running Nothing "return await agent({objective: 'answer', profile: 'basic', output_contract: {type: 'string'}});") $ \waiting -> do
      child <- awaitChild running.jobs
      child.spec.grants `shouldBe` workflowGrants
      (child.spec.parent, child.spec.delegated, child.spec.awaited) `shouldBe` (Just running.job.run, True, True)
      Right result <- pure (parseJobResult child.spec "\"answer\"")
      Jobs.completeJob running.jobs child.run Succeeded result
      returned <- Async.wait waiting
      returned.cmExit `shouldBe` WasmCompleted
      fmap (field "result") returned.cmOutput `shouldBe` Just (Just (object ["text" .= ("\"answer\"" :: Text), "payload" .= ("answer" :: Text)]))
    withDb pool (query "SELECT count(*) FROM workflow_agent_steps" ()) `shouldReturn` [Only (0 :: Int)]

  it "rejects wider profiles and changed tool contracts before starting children" $ do
    forM_ [(Browser, "browser"), (Sandbox, "sandbox_exec")] $ \(profile, tool) -> do
      running <- runningJob pool profile (Map.insert tool "v1" workflowGrants)
      forM_ [workflowGrants, Map.insert tool "changed" workflowGrants] $ \current -> do
        result <- runScriptWith pool running current Nothing ("return (await max.raw('agent', {objective: 'inspect', profile: '" <> profileName profile <> "', wait: true})).outcome;")
        result.cmOutput `shouldSatisfy` (`notElem` [Just "succeeded", Just "committed"])
      jobs <- Jobs.allJobs running.jobs
      length jobs `shouldBe` 1

  it "runs agents started together concurrently and starts new ones when a program is rerun" $ do
    running <- runningJob pool Basic workflowGrants
    let program = "await max.phase('research'); const reports = await Promise.all(['first', 'second'].map(objective => agent({objective, profile: 'basic'}))); return reports.map(report => report.result.text);"
    forM_ [1 .. 2 :: Int] $ \_ -> Async.withAsync (runScript pool running Nothing program) $ \worker -> do
      -- Both children are admitted before either finishes: the batch overlaps them.
      first <- awaitChild running.jobs
      second <- awaitChild running.jobs
      forM_ [first, second] $ \child -> Jobs.completeJob running.jobs child.run Succeeded (JobResult child.spec.objective Nothing)
      result <- Async.wait worker
      result.cmExit `shouldBe` WasmCompleted
      result.cmOutput `shouldBe` Just (toJSON ["first" :: Text, "second"])
    jobs <- Jobs.allJobs running.jobs
    length [job | job <- jobs, job.spec.parent == Just running.job.run] `shouldBe` 4
    withDb pool (query "SELECT count(*) FROM workflow_agent_waits" ()) `shouldReturn` [Only (0 :: Int)]

  it "rejects an over-budget batch before child admission" $ do
    running <- runningJob pool Basic workflowGrants
    result <- runScript pool running (Just 1) "return await Promise.all(['one', 'two'].map(objective => max.raw('agent', {objective, profile: 'basic', wait: true})));"
    result.cmOverBudget `shouldBe` True
    Jobs.allJobs running.jobs >>= (\jobs -> length jobs `shouldBe` 1)

  it "stops guest code on feedback, retains the child, and leaves feedback for the model" $ do
    running <- runningJob pool Basic workflowGrants
    Async.withAsync (runScript pool running Nothing "await agent({objective: 'one', profile: 'basic'}); await agent({objective: 'unreachable', profile: 'basic'});") $ \worker -> do
      _ <- awaitChild running.jobs
      Jobs.steerJob running.jobs running.job.spec.group running.job.spec.principal Nothing running.job.run.jobId "new evidence" `shouldReturn` Right ()
      result <- timeout 3000000 (Async.wait worker)
      fmap (.cmExit) result `shouldBe` Just WasmHostStopped
    Jobs.jobHasFeedback running.jobs running.turn.atrTurnId `shouldReturn` True
    Jobs.allJobs running.jobs >>= (\jobs -> length jobs `shouldBe` 2)

  it "does not start a child when feedback was already pending" $ do
    running <- runningJob pool Basic workflowGrants
    Jobs.steerJob running.jobs running.job.spec.group running.job.spec.principal Nothing running.job.run.jobId "wait" `shouldReturn` Right ()
    result <- runScript pool running Nothing "await agent({objective: 'unreachable', profile: 'basic'});"
    result.cmExit `shouldBe` WasmHostStopped
    Jobs.allJobs running.jobs >>= (\jobs -> length jobs `shouldBe` 1)

  it "cancels an awaiting guest without executing its next step" $ do
    running <- runningJob pool Basic workflowGrants
    Async.withAsync (runScript pool running Nothing "await agent({objective: 'one', profile: 'basic'}); await agent({objective: 'unreachable', profile: 'basic'});") $ \worker -> do
      _ <- awaitChild running.jobs
      timeout 3000000 (Async.cancel worker) `shouldReturn` Just ()
    Jobs.allJobs running.jobs >>= (\jobs -> length jobs `shouldBe` 2)

  it "lets a foreground turn wait for a root agent and keeps its report out of the relay" $ do
    running <- runningJob pool Basic workflowGrants
    (turn, message, principal) <- seed pool 900 2
    runtime <- beginTurnRuntime running.tasks turn (GroupId 900) (UserId 2) (Just message)
    let front = Foreground running.jobs turn runtime message principal
    Async.withAsync (runForeground pool front "const report = await agent({objective: 'look', profile: 'basic'}); return report.result.text;") $ \waiting -> do
      child <- awaitChild running.jobs
      (child.spec.parent, child.spec.awaited) `shouldBe` (Nothing, True)
      Jobs.completeJob running.jobs child.run Succeeded (JobResult "found it" Nothing)
      result <- Async.wait waiting
      result.cmExit `shouldBe` WasmCompleted
      result.cmOutput `shouldBe` Just (String "found it")
    timeout 20000 (Jobs.takeJobWork running.jobs) `shouldReturn` Nothing

awaitChild :: Jobs.Jobs -> IO JobView
awaitChild jobs = do
  next <- timeout 30000000 (Jobs.takeJobWork jobs)
  case next of
    Just (Jobs.LaunchJob child) -> pure child
    Just (Jobs.PublishJobNotice job _ _) -> Jobs.releaseJobNotice jobs job.run >> awaitChild jobs
    _ -> fail "workflow child did not start"

field :: Key -> Value -> Maybe Value
field key = \case
  Object fields -> KeyMap.lookup key fields
  _ -> Nothing

workflowGrants :: Map.Map Text Text
workflowGrants = Map.fromList [("agent", "v1"), ("web_search", "v1")]

agentDefinitions :: [ToolDefinition]
agentDefinitions =
  [ ToolDefinition (ToolRef name) (SchemaVersion 1) (Set.singleton (EffectWrite "task.db")) parallelism RetryUnsafe (Set.singleton CurrentConversation) (ToolDeadline 21600) True mode
  | (name, parallelism, mode) <- [("agent", ParallelIndependent, WorkCall), ("agent_progress", SequentialOnly, CheckpointCall)]
  ]

capabilities :: Bool -> Map.Map Text Text -> TurnCapabilities
capabilities background current =
  TurnCapabilities
    { tcMultimodal = False,
      tcStickers = False,
      tcSkills = True,
      tcOutput = noAdvertisedCaps,
      tcMonitorArming = False,
      tcCatalogGrants = current,
      tcEffectCeiling = Just current,
      tcBackground = background
    }

runScript :: DbPool -> RunningJob -> Maybe Int -> Text -> IO CodeModeResult
runScript pool running = runScriptWith pool running workflowGrants

runScriptWith :: DbPool -> RunningJob -> Map.Map Text Text -> Maybe Int -> Text -> IO CodeModeResult
runScriptWith pool running current budget source = do
  output <- newTurnOutputContext running.turn
  let context = mkToolContext (TurnIdentity (GroupId 900) running.job.spec.source (UserId 1) (UserId 3) running.job.spec.principal Nothing (Just output)) (capabilities True current)
  runProgram pool running.jobs running.runtime running.turn context budget source

data Foreground = Foreground
  { jobs :: Jobs.Jobs,
    turn :: AgentTurnRef,
    runtime :: TurnRuntime,
    message :: CanonicalMessageId,
    principal :: PrincipalId
  }

runForeground :: DbPool -> Foreground -> Text -> IO CodeModeResult
runForeground pool front source = do
  output <- newTurnOutputContext front.turn
  let context = mkToolContext (TurnIdentity (GroupId 900) front.message (UserId 2) (UserId 3) front.principal Nothing (Just output)) (capabilities False workflowGrants)
  runProgram pool front.jobs front.runtime front.turn context Nothing source

runProgram :: DbPool -> Jobs.Jobs -> TurnRuntime -> AgentTurnRef -> ToolContext -> Maybe Int -> Text -> IO CodeModeResult
runProgram pool jobs runtime turn context budget source = do
  let bound = (hooks jobs runtime) {ehWorkflow = Just (taskWorkflowHost jobs turn)}
      runners = [tool | tool <- taskTools jobs context, tool.toolName `elem` ["agent", "agent_progress"]]
      present = map (.toolName) runners
  registry <- either (fail . show) pure (buildToolRegistry [definition | definition <- agentDefinitions, definition.tdRef.unToolRef `elem` present] runners)
  withHost pool . runTools registry $ do
    session <- newExecutionSession budget
    runJavaScript session (hoistExecutionHooks raise bound) (catalogTools (registryCatalog registry)) source
