module Max.ExecutionSpec (spec, withHost, hooks) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async qualified as Async
import Control.Exception (SomeException, fromException, try)
import Control.Monad (unless, void)
import Data.Aeson (Value, object, (.=))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Database.PostgreSQL.Simple (Only (..))
import Effectful (Eff, IOE, liftIO, raise, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Exception (throwIO)
import Effectful.PostgreSQL (WithConnection, execute, query)
import Effectful.PostgreSQL.Connection.Pool (runWithConnectionPool)
import ExecutionFixture
import Helpers (truncateAll, withDb)
import Max.Agent.Execution (ExecutionAdmission (..))
import Max.Agent.Runtime (durableExecutionAdmission)
import Max.CodeMode.Execution
import Max.CodeMode.JavaScript (javaScriptRuntimeVersion, runJavaScript)
import Max.CodeMode.Model (executeModelBatch)
import Max.CodeMode.Wasm
import Max.DB.AgentTurn
import Max.DB.Connection (DbPool)
import Max.DB.Task (claimTask, recordTaskFailure)
import Max.DB.TaskSpec (admit, claimOne, seed)
import Max.Effects.Blob (Blob, runBlob)
import Max.Effects.ToolControl (activateSkills, runToolControl)
import Max.Effects.Tools
import Max.Execution.Tools
import Max.Skill.Package
import Max.Skill.Workflow (bindWorkflowContracts)
import Max.Task.State (FailureKind (Transient))
import Max.Tasks (TaskCancelled (..))
import Max.Tool.Bundles (SkillLoad (..), skillLoadVersion)
import Max.Tool.Catalog (catalogTools)
import Max.Tool.Control (LoopControl (..))
import Max.Turn.Types (AgentTurnRef (..))
import OneBot.Types (GroupId (..))
import System.Timeout (timeout)
import Test.Hspec

type DbEffects = '[Blob, WithConnection, Concurrent, IOE]

withHost :: DbPool -> Eff DbEffects a -> IO a
withHost pool = runEff . runConcurrent . runWithConnectionPool pool . runBlob "var/test-codemode-blobs"

hooks :: AgentTurnRef -> ExecutionHooks DbEffects
hooks turn =
  ExecutionHooks
    { ehCheck = durableExecutionAdmission.eaCheck turn >>= \active -> unless active (throwIO TaskCancelled),
      ehStart = durableExecutionAdmission.eaStartTool (GroupId 900) turn,
      ehFinish = finishJournalExecution,
      ehUnknown = markJournalOutcomeUnknown,
      ehWorkflow = Nothing
    }

-- Lift the assembly callbacks into the local validated Tools interpreter.
hostHooks :: AgentTurnRef -> ExecutionHooks (Tools : DbEffects)
hostHooks = hoistExecutionHooks raise . hooks

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "native and Wasm execution with real journal" $ do
  it "records a JavaScript syntax failure before any leaf as failed-before-effect" $ do
    (_, turn) <- fixture
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [echoTool])
    result <- withHost pool . runTools registry $ do
      session <- newExecutionSession Nothing
      runJavaScript session (hostHooks turn) (views registry) "return ("
    outcomeName (codeModeInvocation result).tiOutcome `shouldBe` "failed-before-effect"
    states turn `shouldReturn` [("host:wasm/v1", "failed")]
    callCount turn `shouldReturn` 0

  it "journals real JavaScript batches and source evidence without charging the container" $ do
    (_, turn) <- fixture
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [echoTool])
    let source = "return max.batch([1,2].map(value => ({tool:'echo',args:{value}}))).map(max.value);"
    result <- withHost pool . runTools registry $ do
      session <- newExecutionSession (Just 2)
      runJavaScript session (hostHooks turn) (views registry) source
    result.cmExit `shouldBe` WasmCompleted
    states turn `shouldReturn` [("host:wasm/v1", "succeeded"), ("echo", "succeeded"), ("echo", "succeeded")]
    callCount turn `shouldReturn` 2
    sourceRows <- withDb pool $ query "SELECT normalized_input->'program'->>'source' FROM execution_journal WHERE turn_id=? AND tool_ref='host:wasm/v1'" (Only turn.atrTurnId)
    sourceRows `shouldBe` [Only source]

  it "retains committed JavaScript leaves and partial failure evidence without replay" $ do
    (_, turn) <- fixture
    count <- newIORef (0 :: Int)
    let definition = echoDefinition {tdEffects = Set.singleton (EffectWrite "test"), tdRetryClass = RetryUnsafe, tdParallelism = SequentialOnly, tdFailuresPrecedeEffects = False}
        runner = echoTool {toolRun = \value -> liftIO (modifyIORef' count (+ 1)) >> pure (Right value)}
    registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
    result <- withHost pool . runTools registry $ do
      session <- newExecutionSession Nothing
      runJavaScript session (hostHooks turn) (views registry) "tools.echo({value:1}); throw new Error('after commit');"
    result.cmExit `shouldSatisfy` (\case WasmTrapped _ -> True; _ -> False)
    map (.ccOutcome) result.cmCalls `shouldBe` ["committed"]
    states turn `shouldReturn` [("host:wasm/v1", "outcome-unknown"), ("echo", "committed")]
    callCount turn `shouldReturn` 1
    readIORef count `shouldReturn` 1

  it "cancels a JavaScript host call with no leaked worker or later effect" $ do
    (_, turn) <- fixture
    entered <- newEmptyMVar
    blocked <- newEmptyMVar
    let runner = echoTool {toolRun = \value -> liftIO (putMVar entered () >> takeMVar blocked) >> pure (Right value)}
        definition = echoDefinition {tdParallelism = SequentialOnly}
    registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
    worker <- Async.async . withHost pool . runTools registry $ do
      session <- newExecutionSession Nothing
      runJavaScript session (hostHooks turn) (views registry) "tools.echo({value:1}); tools.echo({value:2});"
    reached <- timeout 30000000 (takeMVar entered)
    reached `shouldBe` Just ()
    timeout 3000000 (Async.cancel worker) `shouldReturn` Just ()
    states turn `shouldReturn` [("host:wasm/v1", "outcome-unknown"), ("echo", "outcome-unknown")]
    callCount turn `shouldReturn` 1

  it "records identical leaf outcomes, schemas, input and results through both adapters" $ do
    (_, turn) <- fixture
    let readFail = echoTool {toolName = "read_fail", toolRun = \_ -> pure (Left "read failed")}
        write = echoTool {toolName = "write"}
        unknown = echoTool {toolName = "unknown", toolRun = \_ -> pure (Left "ambiguous effect")}
        readDefinition = echoDefinition {tdRef = ToolRef "read_fail"}
        writeDefinition name = echoDefinition {tdRef = ToolRef name, tdEffects = Set.singleton (EffectWrite "test"), tdRetryClass = RetryUnsafe, tdParallelism = SequentialOnly, tdFailuresPrecedeEffects = False}
        calls = [("echo", args), ("echo", object []), ("hidden", args), ("read_fail", args), ("write", args), ("unknown", args)]
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition, readDefinition, writeDefinition "write", writeDefinition "unknown"] [echoTool, readFail, write, unknown])
    binary <- guestCalls [request name value | (name, value) <- calls] ""
    _ <- withHost pool . runTools registry $ do
      session <- newExecutionSession Nothing
      _ <- executeToolBatch session (hostHooks turn) (views registry) [ToolRequest ("native:" <> name) name value | (name, value) <- calls]
      runWasmTools session (hostHooks turn) (views registry) defaultWasmLimits binary
    rows <- withDb pool $ query "SELECT state,tool_ref,schema_hash,normalized_input,result_inline,failure_code FROM execution_journal WHERE turn_id=? AND tool_ref<>'host:wasm/v1' ORDER BY execution_ordinal" (Only turn.atrTurnId)
    let facts = rows :: [(Text, Text, Text, Value, Maybe Value, Maybe Text)]
    take 6 facts `shouldBe` drop 6 facts
    map (\(state, _, _, _, _, _) -> state) (take 6 facts) `shouldBe` ["succeeded", "rejected", "rejected", "failed", "committed", "outcome-unknown"]
    callCount turn `shouldReturn` 12
    labels <- withDb pool $ query "SELECT call_id FROM execution_journal WHERE turn_id=? AND call_id LIKE 'wasm:%/call:%'" (Only turn.atrTurnId)
    length (labels :: [Only Text]) `shouldBe` 6

  it "persists trusted skill controls from either path even when the guest later traps" $ do
    (_, turn) <- fixture
    let load = SkillLoad "web" (skillLoadVersion "trusted skill") "trusted skill" Nothing Nothing
        runner = echoTool {toolName = "use_skill", toolRun = \value -> activateSkills [load] >> pure (Right value)}
        definition = echoDefinition {tdRef = ToolRef "use_skill", tdEffects = Set.singleton EffectReflect, tdParallelism = SequentialOnly, tdRetryClass = RetryUnsafe}
    registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
    binary <- guestCalls [request "use_skill" args, request "hidden" args] "unreachable"
    result <- withHost pool . runToolsWithControl runToolControl registry $ do
      session <- newExecutionSession Nothing
      _ <- executeToolBatch session (hostHooks turn) (views registry) [ToolRequest "native" "use_skill" args]
      runWasmTools session (hostHooks turn) (views registry) defaultWasmLimits binary
    result.cmControl `shouldBe` LoadSkills [load]
    map (.ccOutcome) result.cmCalls `shouldBe` ["succeeded", "rejected"]
    withDb pool (readSkillLoads turn) `shouldReturn` [load, load]

  it "recovers an exact saved workflow and journals its version and output contract failure" $ do
    (_, turn) <- fixture
    let contract = object ["type" .= ("object" :: Text), "additionalProperties" .= True]
        workflow = Workflow "saved" "tools.echo(args); return 'wrong shape';" contract contract ["echo"]
        package = SkillPackage [] (Map.singleton "run" workflow)
        raw = SkillLoad "saved" "" "saved instructions" Nothing (Just (PinnedPackage 1 package Map.empty Nothing TrustedSkill))
        writeDefinition = echoDefinition {tdEffects = Set.singleton (EffectWrite "test"), tdParallelism = SequentialOnly, tdRetryClass = RetryUnsafe}
    effectRegistry <- either (fail . show) pure (buildToolRegistry [writeDefinition] [echoTool])
    [pinned] <- either (fail . show) pure (bindWorkflowContracts javaScriptRuntimeVersion Map.empty (views effectRegistry) [raw])
    let loader = echoTool {toolName = "use_skill", toolRun = \value -> activateSkills [pinned] >> pure (Right value)}
        definition = echoDefinition {tdRef = ToolRef "use_skill", tdEffects = Set.singleton EffectReflect, tdParallelism = SequentialOnly, tdRetryClass = RetryUnsafe}
    registry <- either (fail . show) pure (buildToolRegistry [definition] [loader])
    _ <- withHost pool . runToolsWithControl runToolControl registry $ do
      session <- newExecutionSession Nothing
      executeToolBatch session (hostHooks turn) (views registry) [ToolRequest "load" "use_skill" args]
    void . withDb pool $ execute "UPDATE task_attempts SET lease_until=now()-interval '1 second' WHERE turn_id=?" (Only turn.atrTurnId)
    resumed <- claimOne pool
    restored <- withDb pool (readSkillLoads resumed)
    restored `shouldBe` [pinned]
    result <- withHost pool . runTools effectRegistry $ do
      session <- newExecutionSession Nothing
      executeModelBatch
        True
        (Map.fromList [(l.slName, l) | l <- restored])
        session
        (hostHooks resumed)
        (views effectRegistry)
        [ToolRequest "saved-code" "run_code" (object ["workflow" .= ("saved/run" :: Text), "args" .= args])]
    map (outcomeName . (.tiOutcome)) result.tbInvocations `shouldBe` ["outcome-unknown"]
    states resumed `shouldReturn` [("host:wasm/v1", "outcome-unknown"), ("echo", "committed")]
    evidence <- withDb pool $ query "SELECT normalized_input->'program'->'workflow'->>'version', normalized_input->'program'->>'source' FROM execution_journal WHERE turn_id=? AND tool_ref='host:wasm/v1'" (Only resumed.atrTurnId)
    evidence `shouldBe` [(pinned.slVersion, workflow.wfSource)]

  it "charges one durable leaf when different sessions race for the last call" $ do
    (identifier, turn) <- fixture
    void . withDb pool $ execute "UPDATE durable_tasks SET max_calls=1 WHERE task_id=?" (Only identifier)
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [echoTool])
    binary <- guestCalls [request "echo" args] ""
    let native = withHost pool . runTools registry $ do
          session <- newExecutionSession Nothing
          void (executeToolBatch session (hostHooks turn) (views registry) [ToolRequest "native" "echo" args])
        guest = withHost pool . runTools registry $ do
          session <- newExecutionSession Nothing
          void (runWasmTools session (hostHooks turn) (views registry) defaultWasmLimits binary)
    (a, b) <- Async.concurrently (try @SomeException native) (try @SomeException guest)
    length [() | Right () <- [a, b]] `shouldBe` 1
    length [() | Left exception <- [a, b], Just TaskCancelled <- [fromException exception]] `shouldBe` 1
    callCount turn `shouldReturn` 1
    rows <- withDb pool $ query "SELECT state FROM execution_journal WHERE turn_id=? AND tool_ref='echo'" (Only turn.atrTurnId)
    rows `shouldBe` [Only ("succeeded" :: Text)]

  it "retains a committed leaf after a guest trap and never retries the container" $ do
    (_, turn) <- fixture
    effects <- newIORef (0 :: Int)
    let definition = echoDefinition {tdEffects = Set.singleton (EffectWrite "test"), tdRetryClass = RetryUnsafe, tdParallelism = SequentialOnly, tdFailuresPrecedeEffects = False}
        runner = echoTool {toolRun = \value -> liftIO (modifyIORef' effects (+ 1)) >> pure (Right value)}
    registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
    binary <- guestCalls [request "echo" args] "unreachable"
    result <- withHost pool . runTools registry $ do
      session <- newExecutionSession Nothing
      runWasmTools session (hostHooks turn) (views registry) defaultWasmLimits binary
    result.cmExit `shouldSatisfy` (\case WasmTrapped _ -> True; _ -> False)
    rows <- states turn
    rows `shouldBe` [("host:wasm/v1", "outcome-unknown"), ("echo", "committed")]
    readIORef effects `shouldReturn` 1
    callCount turn `shouldReturn` 1
    withDb pool (recordTaskFailure turn.atrTurnId "guest trapped" Transient) `shouldReturn` True
    withDb pool (finishAgentTurn turn TurnFailed 0 Nothing Nothing)
    withDb pool (claimTask "must-not-replay-script") `shouldReturn` []

  it "settles cancellation during a host call and leaves later calls unstarted" $ do
    -- Exercise both adapters against separate turns and the same DB interpreter.
    mapM_
      ( \guest -> do
          truncateAll pool
          (_, turn) <- fixture
          entered <- newEmptyMVar
          blocked <- newEmptyMVar
          let runner = echoTool {toolRun = \value -> liftIO (putMVar entered () >> takeMVar blocked) >> pure (Right value)}
              definition = echoDefinition {tdParallelism = SequentialOnly}
          registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
          binary <- guestCalls [request "echo" args, request "echo" args] ""
          worker <- Async.async . withHost pool . runTools registry $ do
            session <- newExecutionSession Nothing
            if guest
              then void (runWasmTools session (hostHooks turn) (views registry) defaultWasmLimits binary)
              else void (executeToolBatch session (hostHooks turn) (views registry) [ToolRequest "one" "echo" args, ToolRequest "two" "echo" args])
          takeMVar entered
          timeout 3000000 (Async.cancel worker) `shouldReturn` Just ()
          rows <- states turn
          rows `shouldBe` ([("host:wasm/v1", "outcome-unknown") | guest] <> [("echo", "outcome-unknown")])
          callCount turn `shouldReturn` 1
      )
      [False, True]

  it "fences both paths after lease takeover without replaying completed calls" $ do
    (identifier, old) <- fixture
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [echoTool])
    binary <- guestCalls [request "echo" args] ""
    _ <- withHost pool . runTools registry $ do
      session <- newExecutionSession Nothing
      runWasmTools session (hostHooks old) (views registry) defaultWasmLimits binary
    void . withDb pool $ execute "UPDATE task_attempts SET lease_until=now()-interval '1 second' WHERE turn_id=?" (Only old.atrTurnId)
    resumed <- claimOne pool
    resumed `shouldNotBe` old
    let stale wasm = withHost pool . runTools registry $ do
          session <- newExecutionSession Nothing
          if wasm
            then void (runWasmTools session (hostHooks old) (views registry) defaultWasmLimits binary)
            else void (executeToolBatch session (hostHooks old) (views registry) [ToolRequest "stale" "echo" args])
    stale False `shouldThrow` (\TaskCancelled -> True)
    stale True `shouldThrow` (\TaskCancelled -> True)
    rows <- states old
    rows `shouldBe` [("host:wasm/v1", "succeeded"), ("echo", "succeeded")]
    counts <- withDb pool $ query "SELECT calls_reserved FROM durable_tasks WHERE task_id=?" (Only identifier)
    counts `shouldBe` [Only (1 :: Int)]
    newRows <- states resumed
    newRows `shouldBe` []
  where
    fixture = do
      source <- seed pool 900 1
      identifier <- admit pool source "codemode-test"
      turn <- claimOne pool
      pure (identifier, turn)
    callCount turn = do
      [Only count] <- withDb pool $ query "SELECT calls_reserved FROM durable_tasks JOIN task_attempts USING(task_id) WHERE turn_id=?" (Only turn.atrTurnId)
      pure (count :: Int)
    states turn = withDb pool (query "SELECT tool_ref,state FROM execution_journal WHERE turn_id=? ORDER BY execution_ordinal" (Only turn.atrTurnId)) :: IO [(Text, Text)]
    args = object ["value" .= (7 :: Int)]

views :: ToolRegistry es -> [CatalogTool]
views = catalogTools . registryCatalog

request :: Text -> Value -> Value
request name args = object ["tool" .= name, "args" .= args]
