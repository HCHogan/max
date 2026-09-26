module Max.ExecutionSpec (Max.ExecutionSpec.spec, withHost, hooks) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async qualified as Async
import Control.Exception (bracket_)
import Control.Monad (replicateM_, void)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Database.PostgreSQL.Simple (Only (..))
import Effectful (Eff, IOE, liftIO, raise, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Log (Log, LogLevel (LogAttention), runLog)
import Effectful.PostgreSQL (WithConnection, execute, query)
import Effectful.PostgreSQL.Connection.Pool (runWithConnectionPool)
import ExecutionFixture
import Helpers (truncateAll, withDb)
import JobFixture (RunningJob (..), runningJob)
import Max.Agent.Runtime (executionAdmission, executionJournal)
import Max.CodeMode.Execution
import Max.CodeMode.JavaScript (javaScriptRuntimeVersion, runJavaScript)
import Max.CodeMode.Model (executeModelBatch)
import Max.CodeMode.Wasm
import Max.DB.AgentTurn
import Max.DB.Connection (DbPool)
import Max.Effects.Blob (Blob, runBlob)
import Max.Effects.ToolControl (activateSkills, runToolControl)
import Max.Effects.Tools
import Max.Execution.Tools
import Max.Execution.Types (ExecutionStep (..), StepReservation (..))
import Max.Jobs qualified as Jobs
import Max.Log (ColorMode (ColorNever), withCompactLogger)
import Max.Skill.Contract (Contract, parseContract)
import Max.Skill.Package
import Max.Skill.Workflow (bindWorkflowContracts)
import Max.Task.Policy (treeToolCalls)
import Max.Task.State (TaskStatus (Failed))
import Max.Task.Types (JobResult (..), JobRun (..), JobSpec (..), JobView (..), TaskProfile (Basic))
import Max.Tasks (TaskCancelled (..), TurnRuntime)
import Max.Tool.Bundles (SkillLoad (..), skillLoadVersion)
import Max.Tool.Catalog (catalogTools)
import Max.Tool.Control (LoopControl (..), controlSkillLoads)
import Max.Turn.Types (AgentTurnRef (..))
import OneBot.Types (GroupId (..))
import System.Timeout (timeout)
import Test.Hspec

type DbEffects = '[Blob, WithConnection, Log, Concurrent, IOE]

withHost :: DbPool -> Eff DbEffects a -> IO a
withHost pool action = withCompactLogger ColorNever Nothing $ \logger ->
  runEff . runConcurrent . runLog "execution-test" logger LogAttention . runWithConnectionPool pool . runBlob "var/test-codemode-blobs" $ action

hooks :: Jobs.Jobs -> TurnRuntime -> ExecutionHooks DbEffects
hooks jobs runtime =
  executionHooks
    (executionAdmission jobs)
    executionJournal
    (GroupId 900)
    runtime

-- Lift the assembly callbacks into the local validated Tools interpreter.
hostHooks :: Jobs.Jobs -> TurnRuntime -> ExecutionHooks (Tools : DbEffects)
hostHooks jobs = hoistExecutionHooks raise . hooks jobs

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "native and Wasm execution with real journal" $ do
  it "records a JavaScript syntax failure before any leaf as failed-before-effect" $ do
    (jobs, turn, runtime) <- fixture
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [echoTool])
    result <- withHost pool . runTools registry $ do
      session <- newExecutionSession Nothing
      runJavaScript session (hostHooks jobs runtime) (views registry) "return ("
    outcomeName (codeModeInvocation result).tiOutcome `shouldBe` "failed-before-effect"
    states turn `shouldReturn` [("host:wasm/v1", "failed")]
    callCount jobs turn `shouldReturn` 0

  it "journals real JavaScript batches and source evidence without charging the container" $ do
    (jobs, turn, runtime) <- fixture
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [echoTool])
    let source = "return await Promise.all([1,2].map(value => tools.echo({value})));"
    result <- withHost pool . runTools registry $ do
      session <- newExecutionSession (Just 2)
      runJavaScript session (hostHooks jobs runtime) (views registry) source
    result.cmExit `shouldBe` WasmCompleted
    states turn `shouldReturn` [("host:wasm/v1", "succeeded"), ("echo", "succeeded"), ("echo", "succeeded")]
    callCount jobs turn `shouldReturn` 2
    sourceRows <- withDb pool $ query "SELECT normalized_input->'program'->>'source' FROM execution_journal WHERE turn_id=? AND tool_ref='host:wasm/v1'" (Only turn.atrTurnId)
    sourceRows `shouldBe` [Only source]

  it "retains committed JavaScript leaves and partial failure evidence without replay" $ do
    (jobs, turn, runtime) <- fixture
    count <- newIORef (0 :: Int)
    let definition = echoDefinition {tdEffects = Set.singleton (EffectWrite "test"), tdRetryClass = RetryUnsafe, tdParallelism = SequentialOnly, tdFailuresPrecedeEffects = False}
        runner = echoTool {toolRunner = LegacyRunner $ \value -> liftIO (modifyIORef' count (+ 1)) >> pure (Right value)}
    registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
    result <- withHost pool . runTools registry $ do
      session <- newExecutionSession Nothing
      runJavaScript session (hostHooks jobs runtime) (views registry) "tools.echo({value:1}); throw new Error('after commit');"
    result.cmExit `shouldSatisfy` (\case WasmTrapped _ -> True; _ -> False)
    map (.ccOutcome) result.cmCalls `shouldBe` ["committed"]
    states turn `shouldReturn` [("host:wasm/v1", "outcome-unknown"), ("echo", "committed")]
    callCount jobs turn `shouldReturn` 1
    readIORef count `shouldReturn` 1

  it "cancels a JavaScript host call with no leaked worker or later effect" $ do
    (jobs, turn, runtime) <- fixture
    entered <- newEmptyMVar
    blocked <- newEmptyMVar
    let runner = echoTool {toolRunner = LegacyRunner $ \value -> liftIO (putMVar entered () >> takeMVar blocked) >> pure (Right value)}
        definition = echoDefinition {tdParallelism = SequentialOnly}
    registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
    worker <- Async.async . withHost pool . runTools registry $ do
      session <- newExecutionSession Nothing
      runJavaScript session (hostHooks jobs runtime) (views registry) "tools.echo({value:1}); tools.echo({value:2});"
    reached <- timeout 30000000 (takeMVar entered)
    reached `shouldBe` Just ()
    timeout 3000000 (Async.cancel worker) `shouldReturn` Just ()
    states turn `shouldReturn` [("host:wasm/v1", "outcome-unknown"), ("echo", "outcome-unknown")]
    callCount jobs turn `shouldReturn` 1

  it "records identical leaf outcomes, schemas, input and results through both adapters" $ do
    (jobs, turn, runtime) <- fixture
    let readFail = echoTool {toolName = "read_fail", toolRunner = LegacyRunner $ \_ -> pure (Left "read failed")}
        write = echoTool {toolName = "write"}
        unknown = echoTool {toolName = "unknown", toolRunner = LegacyRunner $ \_ -> pure (Left "ambiguous effect")}
        readDefinition = echoDefinition {tdRef = ToolRef "read_fail"}
        writeDefinition name = echoDefinition {tdRef = ToolRef name, tdEffects = Set.singleton (EffectWrite "test"), tdRetryClass = RetryUnsafe, tdParallelism = SequentialOnly, tdFailuresPrecedeEffects = False}
        calls = [("echo", args), ("echo", object []), ("hidden", args), ("read_fail", args), ("write", args), ("unknown", args)]
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition, readDefinition, writeDefinition "write", writeDefinition "unknown"] [echoTool, readFail, write, unknown])
    binary <- guestCalls [request name value | (name, value) <- calls] ""
    _ <- withHost pool . runTools registry $ do
      session <- newExecutionSession Nothing
      _ <- executeToolBatch session (hostHooks jobs runtime) (views registry) [ToolRequest ("native:" <> name) name value | (name, value) <- calls]
      runWasmTools session (hostHooks jobs runtime) (views registry) defaultWasmLimits binary
    rows <- withDb pool $ query "SELECT state,tool_ref,schema_hash,normalized_input,result_inline,failure_code FROM execution_journal WHERE turn_id=? AND tool_ref<>'host:wasm/v1' ORDER BY execution_ordinal" (Only turn.atrTurnId)
    let facts = rows :: [(Text, Text, Text, Value, Maybe Value, Maybe Text)]
    take 6 facts `shouldBe` drop 6 facts
    map (\(state, _, _, _, _, _) -> state) (take 6 facts) `shouldBe` ["succeeded", "rejected", "rejected", "failed", "committed", "outcome-unknown"]
    callCount jobs turn `shouldReturn` 12
    labels <- withDb pool $ query "SELECT call_id FROM execution_journal WHERE turn_id=? AND call_id LIKE 'wasm:%/call:%'" (Only turn.atrTurnId)
    length (labels :: [Only Text]) `shouldBe` 6

  it "persists trusted skill controls from either path even when the guest later traps" $ do
    (jobs, turn, runtime) <- fixture
    let load = SkillLoad "web" (skillLoadVersion "trusted skill") "trusted skill" Nothing Nothing
        runner = echoTool {toolName = "use_skill", toolRunner = LegacyRunner $ \value -> activateSkills [load] >> pure (Right value)}
        definition = echoDefinition {tdRef = ToolRef "use_skill", tdEffects = Set.singleton EffectReflect, tdParallelism = SequentialOnly, tdRetryClass = RetryUnsafe}
    registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
    binary <- guestCalls [request "use_skill" args, request "hidden" args] "unreachable"
    result <- withHost pool . runToolsWith runToolControl (pure registry) $ do
      session <- newExecutionSession Nothing
      _ <- executeToolBatch session (hostHooks jobs runtime) (views registry) [ToolRequest "native" "use_skill" args]
      runWasmTools session (hostHooks jobs runtime) (views registry) defaultWasmLimits binary
    result.cmControl `shouldBe` LoadSkills [load]
    map (.ccOutcome) result.cmCalls `shouldBe` ["succeeded", "rejected"]
    withDb pool (query "SELECT observed_manifest->'skill_loads' FROM execution_journal WHERE turn_id=? AND tool_ref='use_skill' ORDER BY execution_ordinal" (Only turn.atrTurnId)) `shouldReturn` [Only (toJSON [load]), Only (toJSON [load])]

  it "uses an exact loaded workflow and journals its version and output contract failure" $ do
    (jobs, turn, runtime) <- fixture
    let contract = checkedContract $ object ["type" .= ("object" :: Text), "additionalProperties" .= True]
        workflow = Workflow "saved" "tools.echo(args); return 'wrong shape';" contract contract ["echo"]
        package = SkillPackage [] (Map.singleton "run" workflow)
        raw = SkillLoad "saved" "" "saved instructions" Nothing (Just (PinnedPackage 1 package Map.empty Nothing TrustedSkill))
        writeDefinition = echoDefinition {tdEffects = Set.singleton (EffectWrite "test"), tdParallelism = SequentialOnly, tdRetryClass = RetryUnsafe}
    effectRegistry <- either (fail . show) pure (buildToolRegistry [writeDefinition] [echoTool])
    [pinned] <- either (fail . show) pure (bindWorkflowContracts javaScriptRuntimeVersion (views effectRegistry) [raw])
    let loader = echoTool {toolName = "use_skill", toolRunner = LegacyRunner $ \value -> activateSkills [pinned] >> pure (Right value)}
        definition = echoDefinition {tdRef = ToolRef "use_skill", tdEffects = Set.singleton EffectReflect, tdParallelism = SequentialOnly, tdRetryClass = RetryUnsafe}
    registry <- either (fail . show) pure (buildToolRegistry [definition] [loader])
    loaded <- withHost pool . runToolsWith runToolControl (pure registry) $ do
      session <- newExecutionSession Nothing
      executeToolBatch session (hostHooks jobs runtime) (views registry) [ToolRequest "load" "use_skill" args]
    let active = concatMap (controlSkillLoads . (.tiControl)) loaded.tbInvocations
    active `shouldBe` [pinned]
    result <- withHost pool . runTools effectRegistry $ do
      session <- newExecutionSession Nothing
      executeModelBatch
        True
        (Map.fromList [(l.slName, l) | l <- active])
        session
        (hostHooks jobs runtime)
        (views effectRegistry)
        [ToolRequest "saved-code" "run_code" (object ["workflow" .= ("saved/run" :: Text), "args" .= args])]
    map (outcomeName . (.tiOutcome)) result.tbInvocations `shouldBe` ["outcome-unknown"]
    states turn `shouldReturn` [("use_skill", "succeeded"), ("host:wasm/v1", "outcome-unknown"), ("echo", "committed")]
    evidence <- withDb pool $ query "SELECT normalized_input->'program'->'workflow'->>'version', normalized_input->'program'->>'source' FROM execution_journal WHERE turn_id=? AND tool_ref='host:wasm/v1'" (Only turn.atrTurnId)
    evidence `shouldBe` [(pinned.slVersion, workflow.wfSource)]

  it "refuses the loser before effect when sessions race for the last shared call" $ do
    (jobs, turn, runtime) <- fixture
    replicateM_ (treeToolCalls - 1) (Jobs.authorizeJobStep jobs turn.atrTurnId (ExecutionWork ReserveCall) >>= (`shouldBe` True))
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [echoTool])
    binary <- guestCalls [request "echo" args] ""
    let native = withHost pool . runTools registry $ do
          session <- newExecutionSession Nothing
          batch <- executeToolBatch session (hostHooks jobs runtime) (views registry) [ToolRequest "native" "echo" args]
          pure (batch.tbOverBudget, map (outcomeName . (.tiOutcome)) batch.tbInvocations)
        guest = withHost pool . runTools registry $ do
          session <- newExecutionSession Nothing
          result <- runWasmTools session (hostHooks jobs runtime) (views registry) defaultWasmLimits binary
          pure (result.cmOverBudget, map (.ccOutcome) result.cmCalls)
    -- Neither side is cancelled: the loser's call is rejected and flagged.
    (a, b) <- Async.concurrently native guest
    sort [a, b] `shouldBe` [(False, ["succeeded"]), (True, ["rejected"])]
    callCount jobs turn `shouldReturn` treeToolCalls
    rows <- withDb pool $ query "SELECT state FROM execution_journal WHERE turn_id=? AND tool_ref='echo'" (Only turn.atrTurnId)
    rows `shouldBe` [Only ("succeeded" :: Text)]

  it "returns committed outcomes when diagnostic storage fails without replaying either adapter" $ do
    (jobs, turn, runtime) <- fixture
    count <- newIORef (0 :: Int)
    let definition = echoDefinition {tdEffects = Set.singleton (EffectWrite "test"), tdParallelism = SequentialOnly, tdRetryClass = RetryUnsafe, tdFailuresPrecedeEffects = False}
        runner = echoTool {toolRunner = LegacyRunner $ \value -> liftIO (modifyIORef' count (+ 1)) >> pure (Right value)}
    registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
    binary <- guestCalls [request "echo" args] ""
    (native, guest) <- bracket_
      (withDb pool (execute "ALTER TABLE execution_journal ADD CONSTRAINT test_no_echo CHECK (tool_ref IS DISTINCT FROM 'echo')" ()))
      (withDb pool (execute "ALTER TABLE execution_journal DROP CONSTRAINT test_no_echo" ()))
      $ withHost pool . runTools registry
      $ do
        session <- newExecutionSession Nothing
        native <- executeToolBatch session (hostHooks jobs runtime) (views registry) [ToolRequest "native" "echo" args]
        guest <- runWasmTools session (hostHooks jobs runtime) (views registry) defaultWasmLimits binary
        pure (native, guest)
    map (outcomeName . (.tiOutcome)) native.tbInvocations `shouldBe` ["committed"]
    map (.ccOutcome) guest.cmCalls `shouldBe` ["committed"]
    readIORef count `shouldReturn` 2
    states turn `shouldReturn` [("host:wasm/v1", "succeeded")]
    callCount jobs turn `shouldReturn` 2

  it "retains a committed leaf after a guest trap and never retries the container" $ do
    (jobs, turn, runtime) <- fixture
    effects <- newIORef (0 :: Int)
    let definition = echoDefinition {tdEffects = Set.singleton (EffectWrite "test"), tdRetryClass = RetryUnsafe, tdParallelism = SequentialOnly, tdFailuresPrecedeEffects = False}
        runner = echoTool {toolRunner = LegacyRunner $ \value -> liftIO (modifyIORef' effects (+ 1)) >> pure (Right value)}
    registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
    binary <- guestCalls [request "echo" args] "unreachable"
    result <- withHost pool . runTools registry $ do
      session <- newExecutionSession Nothing
      runWasmTools session (hostHooks jobs runtime) (views registry) defaultWasmLimits binary
    result.cmExit `shouldSatisfy` (\case WasmTrapped _ -> True; _ -> False)
    rows <- states turn
    rows `shouldBe` [("host:wasm/v1", "outcome-unknown"), ("echo", "committed")]
    readIORef effects `shouldReturn` 1
    callCount jobs turn `shouldReturn` 1
    Just job <- Jobs.jobForTurn jobs turn.atrTurnId
    Jobs.completeJob jobs job.run Failed (JobResult "guest trapped" Nothing)
    withDb pool (finishAgentTurn turn TurnFailed 0 Nothing)
    _ <- Jobs.takeJobWork jobs -- one result notice, never another execution
    timeout 20000 (Jobs.takeJobWork jobs) `shouldReturn` Nothing

  it "settles cancellation during a host call and leaves later calls unstarted" $ do
    -- Exercise both adapters against separate turns and the same DB interpreter.
    mapM_
      ( \guest -> do
          truncateAll pool
          (jobs, turn, runtime) <- fixture
          entered <- newEmptyMVar
          blocked <- newEmptyMVar
          let runner = echoTool {toolRunner = LegacyRunner $ \value -> liftIO (putMVar entered () >> takeMVar blocked) >> pure (Right value)}
              definition = echoDefinition {tdParallelism = SequentialOnly}
          registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
          binary <- guestCalls [request "echo" args, request "echo" args] ""
          worker <- Async.async . withHost pool . runTools registry $ do
            session <- newExecutionSession Nothing
            if guest
              then void (runWasmTools session (hostHooks jobs runtime) (views registry) defaultWasmLimits binary)
              else void (executeToolBatch session (hostHooks jobs runtime) (views registry) [ToolRequest "one" "echo" args, ToolRequest "two" "echo" args])
          takeMVar entered
          withDb pool (query "SELECT count(*) FROM execution_journal WHERE turn_id=?" (Only turn.atrTurnId)) `shouldReturn` [Only (0 :: Int)]
          timeout 3000000 (Async.cancel worker) `shouldReturn` Just ()
          rows <- states turn
          rows `shouldBe` ([("host:wasm/v1", "outcome-unknown") | guest] <> [("echo", "outcome-unknown")])
          callCount jobs turn `shouldReturn` 1
      )
      [False, True]

  it "fences both paths after replacement without replaying completed calls" $ do
    (jobs, old, runtime) <- fixture
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [echoTool])
    binary <- guestCalls [request "echo" args] ""
    _ <- withHost pool . runTools registry $ do
      session <- newExecutionSession Nothing
      runWasmTools session (hostHooks jobs runtime) (views registry) defaultWasmLimits binary
    Just job <- Jobs.jobForTurn jobs old.atrTurnId
    Jobs.replaceJob jobs job.spec.group job.spec.principal False job.run.jobId "replacement" `shouldReturn` Right ()
    let stale wasm = withHost pool . runTools registry $ do
          session <- newExecutionSession Nothing
          if wasm
            then void (runWasmTools session (hostHooks jobs runtime) (views registry) defaultWasmLimits binary)
            else void (executeToolBatch session (hostHooks jobs runtime) (views registry) [ToolRequest "stale" "echo" args])
    stale False `shouldThrow` (\TaskCancelled -> True)
    stale True `shouldThrow` (\TaskCancelled -> True)
    rows <- states old
    rows `shouldBe` [("host:wasm/v1", "succeeded"), ("echo", "succeeded")]
    Just replaced <- Jobs.lookupJob jobs job.spec.group job.run.jobId
    replaced.calls `shouldBe` 1
    timeout 20000 (Jobs.takeJobWork jobs) `shouldReturn` Nothing
  where
    fixture = do
      running <- runningJob pool Basic Map.empty
      pure (running.jobs, running.turn, running.runtime)
    callCount jobs turn = do
      Just job <- Jobs.jobForTurn jobs turn.atrTurnId
      pure job.calls
    states turn = withDb pool (query "SELECT tool_ref,state FROM execution_journal WHERE turn_id=? ORDER BY execution_ordinal" (Only turn.atrTurnId)) :: IO [(Text, Text)]
    args = object ["value" .= (7 :: Int)]

views :: ToolRegistry es -> [CatalogTool]
views = catalogTools . registryCatalog

request :: Text -> Value -> Value
request name args = object ["tool" .= name, "args" .= args]

checkedContract :: Value -> Contract
checkedContract = either (error . show) id . parseContract
