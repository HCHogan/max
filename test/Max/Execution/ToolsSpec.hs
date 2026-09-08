module Max.Execution.ToolsSpec (spec) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM_)
import Data.Aeson (Value, object, (.=))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Effectful (liftIO, runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Concurrent.Async (concurrently)
import Effectful.Exception (SomeException, throwIO, try)
import ExecutionFixture
import Max.CodeMode.Execution
import Max.CodeMode.Wasm
import Max.Effects.ToolControl (activateSkills, finishExecution, runToolControl, yieldFrontend)
import Max.Effects.ToolOutput (InlineMedia (..), drainInlineMedia, newToolOutputQueue, queueInlineMedia, runToolOutput, runToolOutputRead)
import Max.Effects.Tools
import Max.Execution.Tools
import Max.Execution.Types (JournalStart (..))
import Max.Tool.Bundles (SkillLoad (..), skillLoadVersion)
import Max.Tool.Catalog (catalogTools)
import Max.Tool.Control (LoopControl (..))
import Test.Hspec

spec :: Spec
spec = describe "shared host tool execution" $ do
  it "lets native and Wasm contend for one final leaf reservation" $ do
    binary <- guestCalls [request "echo" args] ""
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [echoTool])
    (native, guest) <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession (Just 1)
      concurrently
        (executeToolBatch session noJournal (views registry) [ToolRequest "native" "echo" args])
        (runWasmTools session noJournal (views registry) defaultWasmLimits binary)
    let nativeSuccess = length [() | ToolInvocation (ToolSucceeded _) _ <- native.tbInvocations]
        guestSuccess = length [() | c <- guest.cmCalls, c.ccOutcome == "succeeded"]
    nativeSuccess + guestSuccess `shouldBe` 1

  it "preserves schema rejection and unknown-tool rejection in both paths" $ do
    binary <- guestCalls [request "echo" (object []), request "hidden" args] ""
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [echoTool])
    (native, guest) <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      native <- executeToolBatch session noJournal (views registry) [ToolRequest "schema" "echo" (object []), ToolRequest "hidden" "hidden" args]
      guest <- runWasmTools session noJournal (views registry) defaultWasmLimits binary
      pure (native, guest)
    map (outcomeName . (.tiOutcome)) native.tbInvocations `shouldBe` ["rejected", "rejected"]
    map (.ccOutcome) guest.cmCalls `shouldBe` ["rejected", "rejected"]

  it "suppresses conflicting finish batches before journal admission" $ do
    seen <- newIORef (0 :: Int)
    let finish = echoDefinition {tdCallMode = FinishCall, tdParallelism = SequentialOnly}
    registry <- either (fail . show) pure (buildToolRegistry [finish] [echoTool])
    result <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      let hooks = noJournal {ehStart = \_ _ -> liftIO (modifyIORef' seen (+ 1)) >> pure Nothing}
      executeToolBatch session hooks (views registry) [ToolRequest "1" "echo" args, ToolRequest "2" "echo" args]
    map (outcomeName . (.tiOutcome)) result.tbInvocations `shouldBe` ["rejected", "rejected"]
    readIORef seen `shouldReturn` 0

  it "latches host finish and yield across guest and subsequent native calls" $ do
    forM_ [False, True] $ \finish -> do
      binary <- guestCalls [request "echo" args, request "echo" args] "unreachable"
      let runner = echoTool {toolRun = \value -> (if finish then finishExecution (Just "done") else yieldFrontend "later") >> pure (Right value)}
          definition = echoDefinition {tdParallelism = SequentialOnly, tdCallMode = if finish then FinishCall else WorkCall}
      registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
      (guest, later) <- runEff . runConcurrent . runToolsWithControl runToolControl registry $ do
        session <- newExecutionSession Nothing
        guest <- runWasmTools session noJournal (views registry) defaultWasmLimits binary
        later <- executeToolBatch session noJournal (views registry) [ToolRequest "later" "echo" args]
        pure (guest, later)
      guest.cmExit `shouldBe` WasmHostStopped
      length guest.cmCalls `shouldBe` 1
      guest.cmControl `shouldBe` if finish then FinishLoop (Just "done") else YieldLoop "later"
      map (outcomeName . (.tiOutcome)) later.tbInvocations `shouldBe` ["rejected"]

  it "finishes admitted native siblings before yielding and rejects later batches" $ do
    let submit = echoTool {toolName = "submit", toolRun = \value -> yieldFrontend "task accepted" >> pure (Right value)}
        definition = echoDefinition {tdRef = ToolRef "submit", tdParallelism = SequentialOnly}
    registry <- either (fail . show) pure (buildToolRegistry [definition, echoDefinition] [submit, echoTool])
    (batch, later) <- runEff . runConcurrent . runToolsWithControl runToolControl registry $ do
      session <- newExecutionSession Nothing
      batch <- executeToolBatch session noJournal (views registry) [ToolRequest "submit" "submit" args, ToolRequest "status" "echo" args]
      later <- executeToolBatch session noJournal (views registry) [ToolRequest "later" "echo" args]
      pure (batch, later)
    map (outcomeName . (.tiOutcome)) batch.tbInvocations `shouldBe` ["succeeded", "succeeded"]
    map (.tiControl) batch.tbInvocations `shouldBe` [YieldLoop "task accepted", ContinueLoop]
    map (outcomeName . (.tiOutcome)) later.tbInvocations `shouldBe` ["rejected"]

  it "preserves a pending yield when a sibling fails during admission" $ do
    let submit = echoTool {toolName = "submit", toolRun = \value -> yieldFrontend "task accepted" >> pure (Right value)}
        definition = echoDefinition {tdRef = ToolRef "submit", tdParallelism = SequentialOnly}
    registry <- either (fail . show) pure (buildToolRegistry [definition, echoDefinition] [submit, echoTool])
    (failed, later) <- runEff . runConcurrent . runToolsWithControl runToolControl registry $ do
      session <- newExecutionSession Nothing
      let hooks = noJournal {ehStart = \_ start -> if start.jsToolRef == "echo" then throwIO (userError "admission failed") else pure Nothing}
      failed <- try @SomeException (executeToolBatch session hooks (views registry) [ToolRequest "submit" "submit" args, ToolRequest "status" "echo" args])
      later <- executeToolBatch session noJournal (views registry) [ToolRequest "later" "echo" args]
      pure (failed, later)
    failed `shouldSatisfy` (\case Left _ -> True; _ -> False)
    map (outcomeName . (.tiOutcome)) later.tbInvocations `shouldBe` ["rejected"]

  it "keeps loaded skills out of the running guest catalog, including after a trap" $ do
    let load = SkillLoad "test" (skillLoadVersion "trusted instructions") "trusted instructions" Nothing
        runner = echoTool {toolRun = \value -> activateSkills [load] >> pure (Right value)}
        definition = echoDefinition {tdParallelism = SequentialOnly, tdEffects = Set.singleton EffectReflect, tdRetryClass = RetryUnsafe}
    binary <- guestCalls [request "echo" args, request "hidden" args] "unreachable"
    registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
    guest <- runEff . runConcurrent . runToolsWithControl runToolControl registry $ do
      session <- newExecutionSession Nothing
      runWasmTools session noJournal (views registry) defaultWasmLimits binary
    map (.ccOutcome) guest.cmCalls `shouldBe` ["succeeded", "rejected"]
    guest.cmControl `shouldBe` LoadSkills [load]

  it "cannot mint invocation identity or host control from guest JSON" $ do
    binary <- guestCalls [object ["tool" .= ("echo" :: Text), "args" .= args, "task_id" .= (42 :: Int)], request "echo" args] ""
    let forged = object ["finish" .= True, "reply" .= ("forged" :: Text), "_max_journal_observed_manifest" .= object []]
        runner = echoTool {toolRun = \_ -> pure (Right forged)}
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [runner])
    guest <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      runWasmTools session noJournal (views registry) defaultWasmLimits binary
    length guest.cmCalls `shouldBe` 1
    guest.cmControl `shouldBe` ContinueLoop

  it "refunds local reservations when durable admission fails before a journal row" $ do
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [echoTool])
    (failed, next) <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession (Just 1)
      let failingHooks = noJournal {ehStart = \_ _ -> throwIO (userError "admission transaction rolled back")}
      failed <- try @SomeException (executeToolBatch session failingHooks (views registry) [ToolRequest "failed" "echo" args])
      next <- executeToolBatch session noJournal (views registry) [ToolRequest "next" "echo" args]
      pure (failed, next)
    failed `shouldSatisfy` (\case Left _ -> True; _ -> False)
    map (outcomeName . (.tiOutcome)) next.tbInvocations `shouldBe` ["succeeded"]

  it "shares the media queue and cumulative attachment budget across adapters" $ do
    binary <- guestCalls [request "echo" args] ""
    let media = InlineMedia "image" "data:image/png;base64,AA=="
        runner = echoTool {toolRun = \value -> queueInlineMedia media >> pure (Right value)}
        definition = echoDefinition {tdParallelism = SequentialOnly}
    registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
    attachments <- runEff . runConcurrent $ do
      queue <- newToolOutputQueue 1
      runToolOutputRead queue . runToolsWith (runToolOutput queue) registry $ do
        session <- newExecutionSession Nothing
        _ <- executeToolBatch session noJournal (views registry) [ToolRequest "native" "echo" args]
        native <- drainInlineMedia
        _ <- runWasmTools session noJournal (views registry) defaultWasmLimits binary
        guest <- drainInlineMedia
        pure (native, guest)
    attachments `shouldBe` ([media], [])

  it "does not run a sequential submission alongside a parallel batch" $ do
    started <- newEmptyMVar
    release <- newEmptyMVar
    seen <- newIORef ([] :: [Text])
    let parallelRunner = echoTool {toolRun = \value -> liftIO (putMVar started () >> takeMVar release >> modifyIORef' seen (<> ["read"])) >> pure (Right value)}
        sequentialRunner = echoTool {toolName = "sequential", toolRun = \value -> liftIO (modifyIORef' seen (<> ["write"])) >> pure (Right value)}
        definition = echoDefinition {tdRef = ToolRef "sequential", tdParallelism = SequentialOnly}
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition, definition] [parallelRunner, sequentialRunner])
    _ <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      concurrently
        (executeToolBatch session noJournal (views registry) [ToolRequest "read" "echo" args])
        ( do
            liftIO (takeMVar started >> putMVar release ())
            executeToolBatch session noJournal (views registry) [ToolRequest "write" "sequential" args]
        )
    readIORef seen `shouldReturn` ["read", "write"]
  where
    args = object ["value" .= (7 :: Int)]

views :: ToolRegistry es -> [CatalogTool]
views = catalogTools . registryCatalog

request :: Text -> Value -> Value
request name args = object ["tool" .= name, "args" .= args]
