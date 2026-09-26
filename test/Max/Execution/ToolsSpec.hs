module Max.Execution.ToolsSpec (spec) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (atomically, check, modifyTVar', newTVarIO, readTVar, writeTVar)
import Control.Monad (forM_, replicateM_)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Effectful (liftIO, runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Concurrent.Async (cancel, concurrently, wait)
import Effectful.Exception (SomeException, throwIO, try)
import ExecutionFixture
import Max.CodeMode.Execution
import Max.CodeMode.Wasm
import Max.Effects.ToolControl (activateSkills, runToolControl)
import Max.Effects.ToolOutput (InlineMedia (..), canQueueInlineMediaOnce, drainInlineMedia, newToolOutputQueue, queueInlineMedia, queueInlineMediaOnce, runToolOutput, runToolOutputRead)
import Max.Effects.Tools
import Max.Execution.Tools
import Max.Node.Events qualified as Events
import Max.Node.Log qualified as Log
import Max.Tool.Bundles (SkillLoad (..), skillLoadVersion)
import Max.Tool.Catalog (catalogTools)
import Max.Tool.Control (LoopControl (..))
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "shared host tool execution" $ do
  it "logs native settlements in completion order while returning protocol order without duplicate observations" $ do
    target <- atomically (Events.newNode >>= Events.newTask)
    blocked <- newEmptyMVar
    let first = object ["value" .= (1 :: Int)]
        second = object ["value" .= (2 :: Int)]
        runner =
          echoTool
            { toolRunner = LegacyRunner $ \value -> do
                if value == first then liftIO (takeMVar blocked) else pure ()
                pure (Right value)
            }
        hooks = noJournal {ehEvents = pure (Just target)}
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [runner])
    Async.withAsync
      ( runEff . runConcurrent . runTools registry $ do
          session <- newExecutionSession Nothing
          executeToolBatch session hooks (views registry) [ToolRequest "one" "echo" first, ToolRequest "two" "echo" second]
      )
      $ \waiting -> do
        timeout
          1000000
          ( atomically $ do
              snapshot <- Events.readObservations target
              let events = Log.deliveredBetween (Events.observationOwner target) (Log.logCursor Log.emptyLog) (Log.logCursor snapshot) snapshot
              check (any (\case Events.Settled _ value _ -> value == outcomeEnvelope (ToolSucceeded second); _ -> False) events)
          )
          `shouldReturn` Just ()
        putMVar blocked ()
        result <- Async.wait waiting
        map (.tiOutcome) result.tbInvocations `shouldBe` [ToolSucceeded first, ToolSucceeded second]
    snapshot <- atomically (Events.readObservations target)
    let events = Log.deliveredBetween (Events.observationOwner target) (Log.logCursor Log.emptyLog) (Log.logCursor snapshot) snapshot
    [value | Events.Settled _ value _ <- events] `shouldBe` map (outcomeEnvelope . ToolSucceeded) [second, first]
    atomically (Events.observeAll target) `shouldReturn` []

  it "completes an owned native await despite a full buffer of non-interrupting model inputs" $ do
    target <- atomically (Events.newNode >>= Events.newTask)
    atomically (replicateM_ 255 (Events.deliver target (Events.Settled "unselected" Null [])))
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [echoTool])
    result <- timeout 1000000 $ runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      executeToolBatch session noJournal {ehEvents = pure (Just target), ehInterrupt = Events.awaitInterrupt target Events.noPending} (views registry) [ToolRequest "native" "echo" args]
    fmap (map (.tiOutcome) . (.tbInvocations)) result `shouldBe` Just [ToolSucceeded args]
    length <$> atomically (Events.observeAll target) `shouldReturn` 255

  it "logs only the whole program result while keeping its private leaf settlements out of the model node log" $ do
    target <- atomically (Events.newNode >>= Events.newTask)
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [echoTool])
    binary <- guestCalls [request "echo" args] ""
    result <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      runWasmTools session noJournal {ehEvents = pure (Just target)} (views registry) defaultWasmLimits binary
    result.cmExit `shouldBe` WasmCompleted
    snapshot <- atomically (Events.readObservations target)
    let events = Log.deliveredBetween (Events.observationOwner target) (Log.logCursor Log.emptyLog) (Log.logCursor snapshot) snapshot
    [value | Events.Settled _ value _ <- events] `shouldBe` [outcomeEnvelope (codeModeInvocation result).tiOutcome]
    atomically (Events.observeAll target) `shouldReturn` []

  it "interrupts a native async await without cancelling or repeating its call" $ do
    entered <- newEmptyMVar
    release <- newEmptyMVar
    steering <- newTVarIO False
    count <- newIORef (0 :: Int)
    delivered <- newEmptyMVar
    let media = InlineMedia "detached" "data:image/png;base64,AA==" Nothing
    let runner = echoTool {toolRunner = LegacyRunner $ \value -> liftIO (modifyIORef' count (+ 1) >> putMVar entered () >> takeMVar release) >> pure (Right value)}
        hooks = noJournal {ehInterrupt = readTVar steering >>= check}
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition {tdAwait = AsyncTool}] [runner])
    Async.withAsync (takeMVar entered >> atomically (writeTVar steering True)) $ \_ ->
      runEff . runConcurrent . runToolsWithMedia (\action -> do value <- action; pure (value, ContinueLoop, [media])) (pure registry) $ do
        session <- newExecutionSession Nothing
        setExecutionResultSink session (\_ invocation -> putMVar delivered invocation.tiMedia)
        batch <- executeToolBatch session hooks (views registry) [ToolRequest "async" "echo" args]
        ref <- case batch.tbInvocations of
          [ToolInvocation (ToolSucceeded (Object fields)) _] | Just (String ref) <- KeyMap.lookup "result" fields -> pure ref
          _ -> liftIO (fail "await did not detach as a handle")
        liftIO (atomically (writeTVar steering False))
        liftIO (putMVar release ())
        finished <- waitExecution session hooks ref
        liftIO (finished.tiOutcome `shouldBe` ToolSucceeded args)
        liftIO (finished.tiMedia `shouldBe` [])
        liftIO (timeout 1000000 (takeMVar delivered) `shouldReturn` Just [media])
        liftIO (readIORef count `shouldReturn` 1)

  it "waits for non-async tools before admitting steering" $ do
    entered <- newEmptyMVar
    release <- newEmptyMVar
    let runner = echoTool {toolRunner = LegacyRunner $ \value -> liftIO (putMVar entered () >> takeMVar release) >> pure (Right value)}
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [runner])
    Async.withAsync
      ( runEff . runConcurrent . runTools registry $ do
          session <- newExecutionSession Nothing
          executeToolBatch session noJournal {ehInterrupt = pure ()} (views registry) [ToolRequest "short" "echo" args]
      )
      $ \worker -> do
        takeMVar entered
        timeout 20000 (Async.wait worker) >>= (`shouldSatisfy` maybe True (const False))
        putMVar release ()
        batch <- Async.wait worker
        map (.tiOutcome) batch.tbInvocations `shouldBe` [ToolSucceeded args]

  it "enforces remote identifier string bounds before native or Wasm execution" $ do
    let runner = echoTool {toolSchema = object ["type" .= ("object" :: Text), "required" .= (["value"] :: [Text]), "properties" .= object ["value" .= object ["type" .= ("string" :: Text), "minLength" .= (36 :: Int), "maxLength" .= (36 :: Int)]]]}
        values = map (\value -> object ["value" .= (value :: Text)]) ["133", "01a08fdf-744d-7401-a700-616632d53bee", "01a08fdf-744d-7401-a700-616632d53bee-extra"]
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [runner])
    binary <- guestCalls (map (request "echo") values) ""
    (native, guest) <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      native <- executeToolBatch session noJournal (views registry) [ToolRequest "native" "echo" value | value <- values]
      guest <- runWasmTools session noJournal (views registry) defaultWasmLimits binary
      pure (native, guest)
    map (outcomeName . (.tiOutcome)) native.tbInvocations `shouldBe` ["rejected", "succeeded", "rejected"]
    map (.ccOutcome) guest.cmCalls `shouldBe` ["rejected", "succeeded", "rejected"]

  it "overlaps explicitly independent writes without changing their effect or retry classification" $ do
    entered <- newTVarIO (0 :: Int)
    let definition = echoDefinition {tdEffects = Set.singleton (EffectWrite "sandbox.fs"), tdParallelism = ParallelIndependent, tdRetryClass = RetryUnsafe}
        runner =
          echoTool
            { toolRunner = LegacyRunner $ \value -> do
                liftIO $ atomically (modifyTVar' entered (+ 1))
                liftIO $ atomically (readTVar entered >>= check . (== 2))
                pure (Right value)
            }
    registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
    result <- timeout 2000000 $ runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      executeToolBatch session noJournal (views registry) [ToolRequest "one" "echo" args, ToolRequest "two" "echo" args]
    fmap (map (outcomeName . (.tiOutcome)) . (.tbInvocations)) result `shouldBe` Just ["committed", "committed"]
    forM_ [definition {tdRetryClass = RetrySafe}, definition {tdEffects = Set.singleton EffectReflect}] $ \invalid ->
      case buildToolRegistry [invalid] [runner] of
        Left _ -> pure ()
        Right _ -> expectationFailure "invalid independent-call metadata was accepted"

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

  it "keeps loaded skills out of the running guest catalog, including after a trap" $ do
    let load = SkillLoad "test" (skillLoadVersion "trusted instructions") "trusted instructions" Nothing Nothing
        runner = echoTool {toolRunner = LegacyRunner $ \value -> activateSkills [load] >> pure (Right value)}
        definition = echoDefinition {tdParallelism = SequentialOnly, tdEffects = Set.singleton EffectReflect, tdRetryClass = RetryUnsafe}
    binary <- guestCalls [request "echo" args, request "hidden" args] "unreachable"
    registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
    guest <- runEff . runConcurrent . runToolsWith runToolControl (pure registry) $ do
      session <- newExecutionSession Nothing
      runWasmTools session noJournal (views registry) defaultWasmLimits binary
    map (.ccOutcome) guest.cmCalls `shouldBe` ["succeeded", "rejected"]
    guest.cmControl `shouldBe` LoadSkills [load]

  it "cannot mint invocation identity or host control from guest JSON" $ do
    binary <- guestCalls [object ["tool" .= ("echo" :: Text), "args" .= args, "task_id" .= (42 :: Int)], request "echo" args] ""
    let forged = object ["finish" .= True, "reply" .= ("forged" :: Text), "_max_journal_observed_manifest" .= object []]
        runner = echoTool {toolRunner = LegacyRunner $ \_ -> pure (Right forged)}
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [runner])
    guest <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      runWasmTools session noJournal (views registry) defaultWasmLimits binary
    guest.cmCalls `shouldBe` []
    guest.cmExit `shouldSatisfy` (\case WasmTrapped _ -> True; _ -> False)
    guest.cmControl `shouldBe` ContinueLoop

  it "refunds local reservations when admission denies a call" $ do
    registry <- either (fail . show) pure (buildToolRegistry [echoDefinition] [echoTool])
    (failed, next) <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession (Just 1)
      let failingHooks = noJournal {ehStart = \_ _ -> throwIO (userError "admission denied")}
      failed <- try @SomeException (executeToolBatch session failingHooks (views registry) [ToolRequest "failed" "echo" args])
      next <- executeToolBatch session noJournal (views registry) [ToolRequest "next" "echo" args]
      pure (failed, next)
    failed `shouldSatisfy` (\case Left _ -> True; _ -> False)
    map (outcomeName . (.tiOutcome)) next.tbInvocations `shouldBe` ["succeeded"]

  it "shares the media queue and cumulative attachment budget across adapters" $ do
    binary <- guestCalls [request "echo" args] ""
    let media = InlineMedia "image" "data:image/png;base64,AA==" Nothing
        runner = echoTool {toolRunner = LegacyRunner $ \value -> queueInlineMedia media >> pure (Right value)}
        definition = echoDefinition {tdParallelism = SequentialOnly}
    registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
    attachments <- runEff . runConcurrent $ do
      queue <- newToolOutputQueue 1
      runToolOutputRead queue . runToolsWith (fmap (,ContinueLoop) . runToolOutput queue) (pure registry) $ do
        session <- newExecutionSession Nothing
        _ <- executeToolBatch session noJournal (views registry) [ToolRequest "native" "echo" args]
        native <- drainInlineMedia
        _ <- runWasmTools session noJournal (views registry) defaultWasmLimits binary
        guest <- drainInlineMedia
        pure (native, guest)
    attachments `shouldBe` ([media], [])

  it "keeps the browser screenshot category spent after drains and adapter reconstruction" $ do
    let media = InlineMedia "browser screenshot" "data:image/jpeg;base64,AA==" Nothing
    result <- runEff $ do
      queue <- newToolOutputQueue 8
      first <- runToolOutput queue (queueInlineMediaOnce "browser.screenshot" media)
      drained <- runToolOutputRead queue drainInlineMedia
      available <- runToolOutput queue (canQueueInlineMediaOnce "browser.screenshot")
      second <- runToolOutput queue (queueInlineMediaOnce "browser.screenshot" media)
      ordinary <- runToolOutput queue (queueInlineMedia media)
      remaining <- runToolOutputRead queue drainInlineMedia
      pure (first, drained, available, second, ordinary, remaining)
    result `shouldBe` (True, [media], False, False, True, [media])

  it "admits in arrival order and keeps later readers behind an exclusive call" $ do
    entered <- newEmptyMVar
    release <- newEmptyMVar
    seen <- newIORef ([] :: [Text])
    let runner name =
          echoTool
            { toolName = name,
              toolRunner = LegacyRunner $ \value -> do
                liftIO $ if name == "first" then putMVar entered () >> takeMVar release else pure ()
                liftIO (modifyIORef' seen (<> [name]))
                pure (Right value)
            }
        definitions = [echoDefinition {tdRef = ToolRef name, tdParallelism = if name == "exclusive" then SequentialOnly else ParallelSafe} | name <- ["first", "exclusive", "last"]]
    registry <- either (fail . show) pure (buildToolRegistry definitions (map runner ["first", "exclusive", "last"]))
    result <- timeout 3000000 . runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      first <- launchCall session noJournal (views registry) (ToolRequest "1" "first" args)
      liftIO (takeMVar entered)
      exclusive <- launchCall session noJournal (views registry) (ToolRequest "2" "exclusive" args)
      lastCall <- launchCall session noJournal (views registry) (ToolRequest "3" "last" args)
      liftIO (putMVar release ())
      traverse wait [first, exclusive, lastCall]
    fmap length result `shouldBe` Just 3
    readIORef seen `shouldReturn` ["first", "exclusive", "last"]

  it "records a queued cancellation as pre-effect and releases its gate ticket" $ do
    entered <- newEmptyMVar
    release <- newEmptyMVar
    let definition = echoDefinition {tdParallelism = SequentialOnly}
        runner = echoTool {toolRunner = LegacyRunner $ \value -> liftIO (putMVar entered () >> takeMVar release) >> pure (Right value)}
    registry <- either (fail . show) pure (buildToolRegistry [definition] [runner])
    result <- timeout 3000000 . runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      first <- launchCall session noJournal (views registry) (ToolRequest "1" "echo" args)
      liftIO (takeMVar entered)
      queued <- launchCall session noJournal (views registry) (ToolRequest "2" "echo" args)
      cancel queued
      cancelled <- wait queued
      liftIO (putMVar release ())
      _ <- wait first
      pure (outcomeName cancelled.tiOutcome)
    result `shouldBe` Just "rejected"

  it "does not run a sequential submission alongside a parallel batch" $ do
    started <- newEmptyMVar
    release <- newEmptyMVar
    seen <- newIORef ([] :: [Text])
    let parallelRunner = echoTool {toolRunner = LegacyRunner $ \value -> liftIO (putMVar started () >> takeMVar release >> modifyIORef' seen (<> ["read"])) >> pure (Right value)}
        sequentialRunner = echoTool {toolName = "sequential", toolRunner = LegacyRunner $ \value -> liftIO (modifyIORef' seen (<> ["write"])) >> pure (Right value)}
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
