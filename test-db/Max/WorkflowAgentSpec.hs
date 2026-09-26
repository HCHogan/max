module Max.WorkflowAgentSpec (Max.WorkflowAgentSpec.spec) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (atomically, retry)
import Control.Monad (forM_)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified
import Database.PostgreSQL.Simple (Only (..))
import Effectful (Eff, liftIO, raise)
import Effectful.Exception (finally)
import Effectful.PostgreSQL (query)
import Helpers (truncateAll, withDb)
import JobFixture
import Max.CodeMode.Execution
import Max.CodeMode.JavaScript (runJavaScript)
import Max.CodeMode.Wasm (WasmExit (..))
import Max.DB.Connection (DbPool)
import Max.Effects.Tools
import Max.Execution.Tools
import Max.ExecutionSpec (DbEffects, hooks, withHost)
import Max.Jobs qualified as Jobs
import Max.Node.Events qualified as Events
import Max.Node.Router qualified as Router
import Max.Platform.Types (CanonicalMessageId, PrincipalId, noAdvertisedCaps)
import Max.Task.Delegation (parseJobResult)
import Max.Task.State (TaskStatus (Cancelled, Succeeded))
import Max.Task.ToolRuntime (taskTools)
import Max.Task.Types
import Max.Tasks (TurnRuntime, beginTurnRuntime)
import Max.Tool.Catalog (catalogTools)
import Max.ToolContext
import Max.Turn.Types
import NodeWorkFixture qualified
import OneBot.Types (GroupId (..), UserId (..))
import System.Timeout (timeout)
import Test.Hspec hiding (context)

-- agent() is the ordinary agent tool with wait; these run it for real,
-- through the same registry, admission and Jobs as a model's native call.
spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "agent() through the agent tool" $ do
  it "runs SDK tell and ask, then resumes the original JavaScript await with the parent's answer" $ do
    running <- runningJob pool Basic workflowGrants
    Async.withAsync (runScript pool running Nothing "const base=40; await max.tell('working'); const answer=await max.ask('which number?'); return base+Number(answer.body);") $ \worker -> do
      Just (Right (Router.ChildMessage notice)) <- timeout 3000000 (NodeWorkFixture.takeWork running.jobs)
      notice.text `shouldSatisfy` Data.Text.isInfixOf "which number?"
      (relay, message, principal) <- seed pool 900 2
      _ <- beginTurnRuntime running.tasks relay (GroupId 900) (UserId 2) (Just message)
      Jobs.bindMessageRelay running.jobs relay.atrTurnId notice
      Jobs.steerJobFrom running.jobs (Just relay.atrTurnId) (GroupId 900) principal (Just message) running.job.run.jobId "2" `shouldReturn` Right ()
      Just result <- timeout 3000000 (Async.wait worker)
      result.cmExit `shouldBe` WasmCompleted
      result.cmOutput `shouldBe` Just (toJSON (42 :: Int))
      Just current <- Jobs.lookupJob running.jobs (GroupId 900) running.job.run.jobId
      current.calls `shouldBe` 2
      current.messages `shouldBe` ["working"]

  it "waits for an ordinary child and returns its checked report" $ do
    running <- runningJob pool Basic workflowGrants
    Async.withAsync (runScript pool running Nothing "return await agent({objective: 'answer', profile: 'basic', output_contract: {type: 'string'}});") $ \waiting -> do
      child <- awaitChild running.jobs
      child.spec.grants `shouldBe` workflowGrants
      (child.spec.parent, child.spec.awaited) `shouldBe` (Just running.job.run, True)
      Right result <- pure (parseJobResult child.spec "\"answer\"")
      Jobs.completeJob running.jobs child.run Succeeded result
      returned <- Async.wait waiting
      returned.cmExit `shouldBe` WasmCompleted
      fmap (field "result") returned.cmOutput `shouldBe` Just (Just (object ["text" .= ("\"answer\"" :: Text), "payload" .= ("answer" :: Text)]))
    withDb pool (query "SELECT count(*) FROM workflow_agent_steps" ()) `shouldReturn` [Only (0 :: Int)]

  it "cancels an awaited race loser and its descendants when the program returns" $ do
    running <- runningJob pool Basic workflowGrants
    Async.withAsync (runScript pool running Nothing "return await Promise.race(['one','two'].map(objective=>agent({objective,profile:'basic'})));") $ \worker -> do
      first <- awaitChild running.jobs
      second <- awaitChild running.jobs
      Right descendant <- Jobs.admitJob running.jobs Nothing 999 (second.spec {parent = Just second.run, awaited = False})
      Jobs.completeJob running.jobs first.run Succeeded (JobResult "winner" Nothing)
      result <- timeout 3000000 (Async.wait worker)
      fmap (.cmExit) result `shouldBe` Just WasmCompleted
      Just loser <- Jobs.lookupJob running.jobs second.spec.group second.run.jobId
      loser.status `shouldBe` Cancelled
      Just cancelled <- Jobs.lookupJob running.jobs second.spec.group descendant.run.jobId
      cancelled.status `shouldBe` Cancelled

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

  it "reserves each call's budget before child admission" $ do
    running <- runningJob pool Basic workflowGrants
    Async.withAsync (runScript pool running (Just 1) "return await Promise.all(['one', 'two'].map(objective => max.raw('agent', {objective, profile: 'basic', wait: true})));") $ \worker -> do
      child <- awaitChild running.jobs
      Jobs.completeJob running.jobs child.run Succeeded (JobResult "done" Nothing)
      result <- Async.wait worker
      result.cmOverBudget `shouldBe` True
      Jobs.allJobs running.jobs >>= (\jobs -> length jobs `shouldBe` 2)

  it "lets an awaited background child run code without a leaf restriction" $ do
    running <- runningJob pool Basic workflowGrants
    Async.withAsync (runScript pool running Nothing "return await agent({objective:'code child',profile:'basic'});") $ \parent -> do
      child <- launchNext pool running.tasks running.jobs
      child.job.spec.awaited `shouldBe` True
      output <- runScript pool child Nothing "return {calculated:6*7};"
      output.cmOutput `shouldBe` Just (object ["calculated" .= (42 :: Int)])
      Jobs.completeJob running.jobs child.job.run Succeeded (JobResult "42" Nothing)
      result <- Async.wait parent
      result.cmExit `shouldBe` WasmCompleted

  it "pauses on feedback, keeps the child and resumes with its actual report" $ do
    running <- runningJob pool Basic workflowGrants
    pausedSignal <- newEmptyMVar
    resumeSignal <- newEmptyMVar
    let afterPause session paused = do
          liftIO (paused.cmExit `shouldBe` WasmPaused)
          liftIO (putMVar pausedSignal () >> takeMVar resumeSignal)
          controlProgram session True paused.cmRunRef
    Async.withAsync (runScriptUsing pool running "const child=await agent({objective:'one',profile:'basic'}); return child.result.text;" afterPause) $ \worker -> do
      child <- awaitChild running.jobs
      Jobs.steerJob running.jobs running.job.spec.group running.job.spec.principal Nothing running.job.run.jobId "new evidence" `shouldReturn` Right ()
      timeout 3000000 (takeMVar pausedSignal) `shouldReturn` Just ()
      atomically (Jobs.jobEventTask running.jobs running.turn.atrTurnId >>= maybe (pure False) (`Events.hasInterrupt` Events.noPending)) `shouldReturn` True
      Jobs.completeJob running.jobs child.run Succeeded (JobResult "actual report" Nothing)
      _ <- atomically (Jobs.jobEventTask running.jobs running.turn.atrTurnId >>= maybe (pure []) (Router.observeEvents running.jobs.resultRouter))
      putMVar resumeSignal ()
      result <- timeout 3000000 (Async.wait worker)
      fmap (.tiOutcome) result `shouldSatisfy` (\case Just (ToolSucceeded (Object fields)) -> KeyMap.lookup "value" fields == Just (String "actual report"); _ -> False)
    Jobs.allJobs running.jobs >>= (\jobs -> length jobs `shouldBe` 2)

  it "does not start a child when feedback was already pending" $ do
    running <- runningJob pool Basic workflowGrants
    Jobs.steerJob running.jobs running.job.spec.group running.job.spec.principal Nothing running.job.run.jobId "wait" `shouldReturn` Right ()
    result <- runScript pool running Nothing "await agent({objective: 'unreachable', profile: 'basic'});"
    result.cmExit `shouldBe` WasmPaused
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
    timeout 20000 (NodeWorkFixture.takeWork running.jobs) `shouldReturn` Nothing

awaitChild :: Jobs.Jobs -> IO JobView
awaitChild jobs = do
  next <- timeout 30000000 (NodeWorkFixture.takeWork jobs)
  case next of
    Just (Left child) -> pure child
    Just (Right (Router.ChildMessage relay)) -> atomically (Router.releaseMessage jobs.resultRouter relay) >> awaitChild jobs
    Just (Right (Router.JobReport relay)) -> atomically (Router.releaseReport jobs.resultRouter relay) >> awaitChild jobs
    _ -> fail "workflow child did not start"

field :: Key -> Value -> Maybe Value
field key = \case
  Object fields -> KeyMap.lookup key fields
  _ -> Nothing

workflowGrants :: Map.Map Text Text
workflowGrants = Map.fromList [("agent", "v1"), ("web_search", "v1")]

agentDefinitions :: [ToolDefinition]
agentDefinitions =
  [ ToolDefinition (ToolRef name) (SchemaVersion 1) (Set.singleton (EffectWrite "task.db")) parallelism RetryUnsafe (Set.singleton CurrentConversation) (ToolDeadline 21600) True mode (if name `elem` ["agent", "agent_ask"] then AsyncTool else ShortTool)
  | (name, parallelism, mode) <- [("agent", ParallelIndependent, WorkCall), ("agent_progress", SequentialOnly, CheckpointCall), ("agent_tell", SequentialOnly, WorkCall), ("agent_ask", ParallelIndependent, WorkCall)]
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

runScriptUsing :: DbPool -> RunningJob -> Text -> (ExecutionSession -> CodeModeResult -> Eff (Tools : DbEffects) a) -> IO a
runScriptUsing pool running source continuation = do
  output <- newTurnOutputContext running.turn
  let context = mkToolContext (TurnIdentity (GroupId 900) running.job.spec.source (UserId 1) (UserId 3) running.job.spec.principal Nothing (Just output)) (capabilities True workflowGrants)
  runProgramUsing pool running.jobs running.runtime running.turn context Nothing source continuation

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
runProgram pool jobs runtime turn context budget source = runProgramUsing pool jobs runtime turn context budget source (const pure)

runProgramUsing :: DbPool -> Jobs.Jobs -> TurnRuntime -> AgentTurnRef -> ToolContext -> Maybe Int -> Text -> (ExecutionSession -> CodeModeResult -> Eff (Tools : DbEffects) a) -> IO a
runProgramUsing pool jobs runtime turn context budget source continuation = do
  let bound = (hooks jobs runtime) {ehAcquireGuest = liftIO (Jobs.acquireGuestSlot jobs turn.atrTurnId), ehInterrupt = Jobs.jobEventTask jobs turn.atrTurnId >>= maybe retry (`Events.awaitInterrupt` Events.noPending)}
      runners = [tool | tool <- taskTools jobs context, tool.toolName `elem` ["agent", "agent_progress", "agent_tell", "agent_ask"]]
      present = map (.toolName) runners
  registry <- either (fail . show) pure (buildToolRegistry [definition | definition <- agentDefinitions, definition.tdRef.unToolRef `elem` present] runners)
  withHost pool . runTools registry $ do
    session <- newExecutionSession budget
    (runJavaScript session (hoistExecutionHooks raise bound) (catalogTools (registryCatalog registry)) source >>= continuation session) `finally` closeExecutionSession session
