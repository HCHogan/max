module Max.CodeMode.JavaScriptSpec (spec) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM
import Control.Exception qualified as Exception
import Control.Monad (forM_)
import Data.Aeson (Value (..), encode, object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Effectful (Eff, IOE, liftIO, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Exception qualified as Eff
import ExecutionFixture
import Max.Browser.View (browserBudget, browserView)
import Max.CodeMode.Execution
import Max.CodeMode.JavaScript
import Max.CodeMode.Model (executeModelBatch)
import Max.CodeMode.Wasm
import Max.Effects.ToolOutput (InlineMedia (..), ToolOutput, drainInlineMedia, forkToolOutputQueue, newToolOutputQueue, queueInlineMedia, runToolOutput, runToolOutputRead)
import Max.Effects.Tools
import Max.Execution.Tools
import Max.Node.Events qualified as Events
import Max.Node.Executor qualified as Node
import Max.Node.Log qualified as NodeLog
import Max.Tool.Catalog (catalogTools)
import Max.Tool.Control (LoopControl (ContinueLoop))
import Max.Turn.Types (AgentTurnId (..))
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "JavaScript SDK in embedded Wasm" $ do
  it "lets another root segment run during an async await and gates every resumed guest step" $ do
    target <- atomically (Events.newNode >>= Events.newTask)
    node <- Node.newExecutor
    parent <- atomically (Node.registerTask node (AgentTurnId 1) Node.NewRequest)
    other <- atomically (Node.registerTask node (AgentTurnId 2) Node.NewRequest)
    entered <- newEmptyMVar
    release <- newEmptyMVar
    nextEffect <- newEmptyMVar
    let runner value = liftIO $ do
          case valueOf value of
            Just (Number 2) -> putMVar entered () >> takeMVar release
            _ -> putMVar nextEffect ()
          pure (Right value)
    registry <- checked [echoDefinition {tdAwait = AsyncTool}] [echoTool {toolRunner = LegacyRunner runner}]
    let program = runEff . runConcurrent . runTools registry $ do
          session <- newExecutionSession Nothing
          runJavaScript session noJournal {ehActor = pure (Just parent), ehEvents = pure (Just target)} (views registry) "let base=40; const a=await tools.echo({value:2}); await tools.echo({value:3}); return base+a.value;"
    Async.withAsync program $ \running -> do
      timeout 1000000 (takeMVar entered) `shouldReturn` Just ()
      timeout 1000000 (Node.enter other) `shouldReturn` Just True
      putMVar release ()
      -- Readiness is logged before the guest can regain the node permit.
      timeout 1000000 (atomically (guestEvents target >>= check . (== 1) . length)) `shouldReturn` Just ()
      timeout 20000 (takeMVar nextEffect) `shouldReturn` Nothing
      atomically (Node.closeTask other)
      result <- timeout 30000000 (Async.wait running)
      fmap (.cmOutput) result `shouldBe` Just (Just (Number 42))
      timeout 1000000 (takeMVar nextEffect) `shouldReturn` Just ()
    length <$> atomically (guestEvents target) `shouldReturn` 2
    atomically (Events.observeAll target) `shouldReturn` []
    atomically (Node.closeTask parent)

  it "runs agent() calls started together concurrently, as waiting agent tool calls, in input order" $ do
    first <- newEmptyMVar
    second <- newEmptyMVar
    let definition = echoDefinition {tdRef = ToolRef "agent", tdEffects = Set.singleton (EffectWrite "task.db"), tdParallelism = ParallelIndependent, tdRetryClass = RetryUnsafe}
        runner args = do
          liftIO $
            if objectiveOf args == Just "one"
              then putMVar first () >> takeMVar second
              else putMVar second () >> takeMVar first
          pure (Right args)
    registry <- checked [definition] [legacyTool "agent" "agent" (object ["type" .= ("object" :: Text)]) runner]
    result <- timeout 30000000 . runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession (Just 2)
      runJavaScript session noJournal (views registry) "const reports = await Promise.all(['one','two'].map(objective => agent({objective, profile:'basic'}))); return reports.map(x => [x.objective, x.wait]);"
    fmap (.cmExit) result `shouldBe` Just WasmCompleted
    fmap (.cmOutput) result `shouldBe` Just (Just (toValue [toValue [String "one", Bool True], toValue [String "two", Bool True]]))
  it "hands each leaf attachment to one guest snapshot across pause and resume" $ do
    target <- atomically (Events.newNode >>= Events.newTask)
    entered <- newEmptyMVar
    release <- newEmptyMVar
    steering <- newTVarIO False
    let first = InlineMedia "first" "data:image/png;base64,AA==" Nothing
        second = InlineMedia "second" "data:video/mp4;base64,BB==" (Just 128)
        runner value = do
          media <- case valueOf value of
            Just (Number 2) -> liftIO (putMVar entered () >> takeMVar release) >> pure second
            _ -> pure first
          _ <- queueInlineMedia media
          pure (Right value)
        hooks = noJournal {ehInterrupt = readTVar steering >>= check, ehEvents = pure (Just target)}
    registry <- checked [echoDefinition {tdAwait = AsyncTool}] [echoTool {toolRunner = LegacyRunner runner}]
    output <- runEff (newToolOutputQueue 2)
    let lower :: forall x. Eff '[ToolOutput, Concurrent, IOE] x -> Eff '[Concurrent, IOE] (x, LoopControl, [InlineMedia])
        lower action = do
          scoped <- forkToolOutputQueue output
          value <- runToolOutput scoped action
          media <- runToolOutputRead scoped drainInlineMedia
          pure (value, ContinueLoop, media)
    Async.withAsync (takeMVar entered >> atomically (writeTVar steering True)) $ \_ ->
      runEff . runConcurrent . runToolsWithMedia lower (pure registry) $ do
        session <- newExecutionSession Nothing
        ( do
            paused <- runJavaScript session hooks (views registry) "await tools.echo({value:1}); await tools.echo({value:2}); return 'done';"
            liftIO (paused.cmExit `shouldBe` WasmPaused)
            liftIO (paused.cmMedia `shouldBe` [first])
            liftIO (atomically (writeTVar steering False) >> putMVar release ())
            resumed <- controlProgram session True paused.cmRunRef
            liftIO (resumed.tiMedia `shouldBe` [second])
            liftIO (codeValue resumed `shouldBe` Just (String "done"))
            liftIO $ programEvents target `shouldReturn` [(outcomeEnvelope (codeModeInvocation paused).tiOutcome, [first]), (outcomeEnvelope resumed.tiOutcome, [second])]
            liftIO $ length . filter (T.isSuffixOf "/resume") <$> atomically (guestEvents target) `shouldReturn` 1
            liftIO (atomically (Events.observeAll target) `shouldReturn` [])
          )
          `Eff.finally` closeExecutionSession session

  it "pauses on steering and resumes the original await with buffered results" $ do
    entered <- newEmptyMVar
    release <- newEmptyMVar
    completed <- newEmptyMVar
    slots <- newTVarIO (0 :: Int)
    steering <- newTVarIO False
    count <- newIORef (0 :: Int)
    let definition = echoDefinition {tdAwait = AsyncTool}
        runner value = liftIO $ do
          modifyIORef' count (+ 1)
          case valueOf value of
            Just (Number 2) -> putMVar entered () >> takeMVar release >> putMVar completed ()
            _ -> pure ()
          pure (Right value)
        hooks =
          noJournal
            { ehInterrupt = readTVar steering >>= check,
              ehAcquireGuest = liftIO $ do
                atomically (modifyTVar' slots (+ 1))
                pure (Just (atomically (modifyTVar' slots (subtract 1))))
            }
    registry <- checked [definition] [echoTool {toolRunner = LegacyRunner runner}]
    Async.withAsync (takeMVar entered >> atomically (writeTVar steering True)) $ \_ ->
      runEff . runConcurrent . runTools registry $ do
        session <- newExecutionSession Nothing
        ( do
            paused <- runJavaScript session hooks (views registry) "let base=40; const a=await tools.echo({value:2}); await tools.echo({value:3}); return base+a.value;"
            liftIO (paused.cmExit `shouldBe` WasmPaused)
            liftIO (readTVarIO slots `shouldReturn` 1)
            liftIO (putMVar release () >> takeMVar completed)
            liftIO (readIORef count `shouldReturn` 1)
            liftIO (atomically (writeTVar steering False))
            resumed <- executeModelBatch True Map.empty session hooks (views registry) [ToolRequest "resume" "run_code_resume" (object ["run" .= paused.cmRunRef])]
            liftIO (map codeValue resumed.tbInvocations `shouldBe` [Just (Number 42)])
            liftIO (readIORef count `shouldReturn` 2)
            liftIO (readTVarIO slots `shouldReturn` 0)
            other <- newExecutionSession Nothing
            denied <- controlProgram other True paused.cmRunRef
            liftIO (outcomeName denied.tiOutcome `shouldBe` "rejected")
          )
          `Eff.finally` closeExecutionSession session

  it "cancels a paused program, joins its tools and records unfinished effects" $ do
    target <- atomically (Events.newNode >>= Events.newTask)
    entered <- newEmptyMVar
    release <- newEmptyMVar
    ended <- newEmptyMVar
    steering <- newTVarIO False
    let runner value = liftIO ((putMVar entered () >> takeMVar release >> pure (Right value)) `Exception.finally` putMVar ended ())
        hooks = noJournal {ehInterrupt = readTVar steering >>= check, ehEvents = pure (Just target)}
    registry <- checked [echoDefinition {tdAwait = AsyncTool}] [echoTool {toolRunner = LegacyRunner runner}]
    Async.withAsync (takeMVar entered >> atomically (writeTVar steering True)) $ \_ ->
      runEff . runConcurrent . runTools registry $ do
        session <- newExecutionSession Nothing
        ( do
            paused <- runJavaScript session hooks (views registry) "await tools.echo({value:1}); return 'unreachable';"
            liftIO (paused.cmExit `shouldBe` WasmPaused)
            cancelled <- controlProgram session False paused.cmRunRef
            liftIO (outcomeName cancelled.tiOutcome `shouldBe` "outcome-unknown")
            liftIO (timeout 1000000 (takeMVar ended) `shouldReturn` Just ())
            liftIO $ programEvents target `shouldReturn` [(outcomeEnvelope (codeModeInvocation paused).tiOutcome, []), (outcomeEnvelope cancelled.tiOutcome, [])]
            stale <- controlProgram session True paused.cmRunRef
            liftIO (outcomeName stale.tiOutcome `shouldBe` "rejected")
          )
          `Eff.finally` closeExecutionSession session

  it "cancels a paused guest when its owning task ends" $ do
    target <- atomically (Events.newNode >>= Events.newTask)
    steering <- newTVarIO True
    registry <- checked [echoDefinition {tdAwait = AsyncTool}] [echoTool]
    finished <- timeout 3000000 . runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      paused <- runJavaScript session noJournal {ehInterrupt = readTVar steering >>= check, ehEvents = pure (Just target)} (views registry) "return await tools.echo({value:1});"
      liftIO (paused.cmExit `shouldBe` WasmPaused)
      liftIO (paused.cmSubmittedCalls `shouldBe` 0)
      liftIO (atomically (Events.tryFinish target) `shouldReturn` True)
      closeExecutionSession session
      result <- controlProgram session True paused.cmRunRef
      liftIO (outcomeName result.tiOutcome `shouldBe` "rejected")
      liftIO $ programEvents target `shouldReturn` [(outcomeEnvelope (codeModeInvocation paused).tiOutcome, [])]
    finished `shouldBe` Just ()

  it "records a host admission exception before waking and failing the parent await" $ do
    target <- atomically (Events.newNode >>= Events.newTask)
    registry <- checked [echoDefinition] [echoTool]
    let failure = userError "guest admission failed"
        hooks = noJournal {ehEvents = pure (Just target), ehAcquireGuest = liftIO (Exception.throwIO failure)}
        run = runEff . runConcurrent . runTools registry $ do
          session <- newExecutionSession Nothing
          runJavaScript session hooks (views registry) "return 42;"
    timeout 3000000 run `shouldThrow` anyIOException
    programEvents target `shouldReturn` [(outcomeEnvelope (ToolOutcomeUnknown (ToolFault "interrupted" (T.pack (show failure)) RetryUnsafe)), [])]

  it "yields the parent executor while cancellation waits for leaf cleanup" $ do
    node <- Node.newExecutor
    parent <- atomically (Node.registerTask node (AgentTurnId 1) Node.NewRequest)
    target <- atomically (Events.newNode >>= Events.newTask)
    entered <- newEmptyMVar
    blocked <- newEmptyMVar
    cleanupStarted <- newEmptyMVar
    cleanupRelease <- newEmptyMVar
    peerReady <- newEmptyMVar
    steering <- newTVarIO False
    let runner value =
          liftIO $
            (putMVar entered () >> takeMVar blocked >> pure (Right value))
              `Exception.finally` (putMVar cleanupStarted () >> takeMVar cleanupRelease)
        hooks = noJournal {ehActor = pure (Just parent), ehEvents = pure (Just target), ehInterrupt = readTVar steering >>= check}
    registry <- checked [echoDefinition {tdAwait = AsyncTool}] [echoTool {toolRunner = LegacyRunner runner}]
    Async.withAsync (takeMVar entered >> atomically (writeTVar steering True)) $ \_ ->
      Async.withAsync
        ( do
            peer <- takeMVar peerReady
            takeMVar cleanupStarted
            timeout 1000000 (Node.enter peer) `shouldReturn` Just True
            putMVar cleanupRelease ()
            atomically (Node.closeTask peer)
        )
        $ \peerWorker -> do
          finished <- timeout 3000000 . runEff . runConcurrent . runTools registry $ do
            session <- newExecutionSession Nothing
            paused <- runJavaScript session hooks (views registry) "await tools.echo({value:1}); return 'unreachable';"
            liftIO (paused.cmExit `shouldBe` WasmPaused)
            peer <- liftIO (atomically (Node.registerTask node (AgentTurnId 2) Node.NewRequest))
            liftIO (putMVar peerReady peer)
            cancelled <- controlProgram session False paused.cmRunRef
            liftIO (outcomeName cancelled.tiOutcome `shouldBe` "outcome-unknown")
            liftIO (Async.wait peerWorker)
            closeExecutionSession session
          finished `shouldBe` Just ()

  it "rejects run_code over its guest limit before any guest work" $ do
    registry <- checked [echoDefinition] [echoTool]
    result <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      executeModelBatch True Map.empty session noJournal {ehAcquireGuest = pure Nothing} (views registry) [ToolRequest "child" "run_code" (object ["code" .= ("return await tools.echo({value:1});" :: Text)])]
    map (outcomeName . (.tiOutcome)) result.tbInvocations `shouldBe` ["rejected"]
  it "cannot register run_code as a leaf runner that would recursively acquire the gate" $ do
    case buildToolRegistry [echoDefinition {tdRef = ToolRef "run_code"}] [echoTool {toolName = "run_code"}] of
      Left (InvalidToolMetadata (ToolRef "run_code") _) -> pure ()
      _ -> expectationFailure "orchestration entry was accepted as a leaf"

  it "runs async bodies with real tool values and returns selected JSON" $ do
    result <- simple "const rows = []; for (let n = 1; n <= 3; n++) rows.push((await tools.echo({value:n})).value); return {sum:rows.reduce((a,b)=>a+b), text:'中文 😀'};"
    result.cmExit `shouldBe` WasmCompleted
    result.cmOutput `shouldBe` Just (object ["sum" .= (6 :: Int), "text" .= ("中文 😀" :: Text)])
    map (.ccOutcome) result.cmCalls `shouldBe` replicate 3 "succeeded"

  it "runs the context navigation manual with unchanged read/next objects and lossless IDs" $ do
    manual <- TIO.readFile "skills/codemode.md"
    let (_, section) = T.breakOn "## 翻聊天上下文" manual
        source = fst (T.breakOn "```" (T.drop (T.length "```javascript\n") (snd (T.breakOn "```javascript\n" section))))
        ref = "message:9007199254740993" :: Text
        first = object ["ref" .= ref]
        next = object ["cursor" .= ("opaque-not-a-number" :: Text)]
        item = object ["ref" .= ref, "text" .= ("原文" :: Text), "more" .= Null]
        search _ = pure (Right (object ["results" .= [object ["read" .= first]]]))
        readPage args
          | args == first = pure (Right (object ["items" .= [item], "next" .= next]))
          | args == next = pure (Right (object ["items" .= [item], "next" .= Null]))
          | otherwise = pure (Left "continuation was changed")
        definitions = [echoDefinition {tdRef = ToolRef name} | name <- ["context_search", "context_read"]]
        schema = object ["type" .= ("object" :: Text)]
    registry <- checked definitions [legacyTool "context_search" "search" schema search, legacyTool "context_read" "read" schema readPage]
    result <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      runJavaScript session noJournal (views registry) source
    result.cmExit `shouldBe` WasmCompleted
    result.cmOutput `shouldBe` Just (object ["rows" .= [item, item], "next" .= Null])
    length result.cmCalls `shouldBe` 3

  it "runs the web manual's browsing program as written" $ do
    manual <- TIO.readFile "skills/web.md"
    let (_, section) = T.breakOn "# 多步浏览写成程序" manual
        source = fst (T.breakOn "```" (T.drop (T.length "```javascript\n") (snd (T.breakOn "```javascript\n" section))))
    source `shouldSatisfy` T.isInfixOf "max.raw(\"browser\""
    -- A stateful page: the first address lands on a redirected plans page,
    -- the second on the pricing table the program is meant to parse.
    current <- newIORef ("" :: Text)
    let page url body = String ("Outcome: open ok HTTP 200\nPage: " <> url <> " | Title\nPosition: 0,0 viewport 1280x800 pageHeight 900\nContent:\n" <> body)
        browse args = case args of
          Object fields
            | Just (String "open") <- KM.lookup "action" fields,
              Just (String url) <- KM.lookup "url" fields -> do
                let docs = "docs." `T.isInfixOf` url
                liftIO (modifyIORef' current (const (if docs then "docs" else "plans")))
                pure (Right (page (if docs then "https://docs.example.com/pricing" else "https://example.com/ja-JP/plans") "..."))
            | Just (String "read") <- KM.lookup "action" fields -> do
                shown <- liftIO (readIORef current)
                pure . Right . page "?" $
                  if shown == "docs" then "Prices per 1M tokens.\nmodel-a\n$10.00\n$1.00\n$12.50\n$50.00\nmodel-b\n$2.00" else "Consumer plans\nPlus"
          _ -> pure (Left "unexpected browser call")
        definition = echoDefinition {tdRef = ToolRef "browser", tdEffects = Set.singleton (EffectWrite "browser.session"), tdParallelism = SequentialOnly, tdRetryClass = RetryUnsafe, tdFailuresPrecedeEffects = False}
    registry <- checked [definition] [legacyTool "browser" "browser" (object ["type" .= ("object" :: Text)]) browse]
    result <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      runJavaScript session noJournal (views registry) source
    result.cmExit `shouldBe` WasmCompleted
    result.cmOutput
      `shouldBe` Just
        ( object
            [ "source" .= ("https://docs.example.com/pricing" :: Text),
              "rows" .= object ["model-a" .= (["$10.00", "$1.00", "$12.50", "$50.00"] :: [Text])],
              "tried" .= [object ["url" .= ("https://example.com/pricing" :: Text), "landed" .= ("https://example.com/ja-JP/plans" :: Text)]]
            ]
        )
    map (.ccTool) result.cmCalls `shouldBe` ["browser", "browser", "browser", "browser"]

  it "runs the web manual's paging loop against the real read projection" $ do
    manual <- TIO.readFile "skills/web.md"
    let (_, section) = T.breakOn "# 多步浏览写成程序" manual
        blocks = drop 1 (T.splitOn "```javascript\n" section)
        source = case blocks of
          _ : paging : _ -> fst (T.breakOn "```" paging)
          _ -> ""
        document = T.unlines (concat [["## Section " <> T.pack (show n), T.replicate 30 (T.pack (show n) <> " ")] | n <- [1 :: Int .. 1200]])
        -- The browser returns a window; Max's projection decides what fits.
        browse args = case args of
          Object fields
            | Just (String "read") <- KM.lookup "action" fields -> do
                let offset = case KM.lookup "offset" fields of Just (Number n) -> truncate n; _ -> 0
                    window = T.take 30000 (T.drop offset document)
                    end = offset + T.length window
                    payload = object ["structuredContent" .= object ["url" .= ("https://example.test/README.md" :: Text), "text" .= window, "textRange" .= object ["offset" .= offset, "end" .= end, "more" .= (end < T.length document)]]]
                pure (Right (browserView (browserBudget "read" args) "read" payload))
          _ -> pure (Left "unexpected browser call")
        definition = echoDefinition {tdRef = ToolRef "browser", tdEffects = Set.singleton (EffectWrite "browser.session"), tdParallelism = SequentialOnly, tdRetryClass = RetryUnsafe, tdFailuresPrecedeEffects = False}
    source `shouldSatisfy` T.isInfixOf "offset"
    registry <- checked [definition] [legacyTool "browser" "browser" (object ["type" .= ("object" :: Text)]) browse]
    result <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      runJavaScript session noJournal (views registry) source
    result.cmExit `shouldBe` WasmCompleted
    result.cmOutput `shouldBe` Just (object ["chars" .= T.length document, "headings" .= ["## Section " <> T.pack (show n) | n <- [1 :: Int .. 1200]]])
    length result.cmCalls `shouldSatisfy` (> 1)

  it "pages large Unicode results without a second effect or budget charge" $ do
    count <- newIORef (0 :: Int)
    let payload = T.replicate 20000 "中文😀\"\\\n"
        runner = echoTool {toolRunner = LegacyRunner $ \_ -> liftIO (modifyIORef' count (+ 1)) >> pure (Right (object ["text" .= payload]))}
    registry <- checked [echoDefinition] [runner]
    (result, following) <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession (Just 1)
      result <- runJavaScript session noJournal (views registry) "const value = await tools.echo({value:1}); return {length:[...value.text].length, tail:value.text.slice(-7)};"
      following <- executeToolBatch session noJournal (views registry) [ToolRequest "native" "echo" (object ["value" .= (2 :: Int)])]
      pure (result, following)
    result.cmExit `shouldBe` WasmCompleted
    result.cmOutput `shouldBe` Just (object ["length" .= (120000 :: Int), "tail" .= ("中文😀\"\\\n" :: Text)])
    length result.cmCalls `shouldBe` 1
    following.tbOverBudget `shouldBe` True
    readIORef count `shouldReturn` 1

  it "submits calls awaited together as one parallel batch and keeps input order" $ do
    first <- newEmptyMVar
    second <- newEmptyMVar
    let runner =
          echoTool
            { toolRunner = LegacyRunner $ \value -> do
                liftIO $
                  if value == object ["value" .= (1 :: Int)]
                    then putMVar first () >> takeMVar second
                    else putMVar second () >> takeMVar first
                pure (Right value)
            }
    registry <- checked [echoDefinition] [runner]
    result <- timeout 30000000 . runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession (Just 2)
      runJavaScript session noJournal (views registry) "return await Promise.all([1,2].map(value => tools.echo({value})));"
    fmap (.cmExit) result `shouldBe` Just WasmCompleted
    fmap (.cmOutput) result `shouldBe` Just (Just (toValue [object ["value" .= (1 :: Int)], object ["value" .= (2 :: Int)]]))

  it "keeps max.batch as Promise.all over raw outcomes" $ do
    result <- simple "return (await max.batch([1,2].map(value => ({tool:'echo',args:{value}})))).map(max.value);"
    result.cmExit `shouldBe` WasmCompleted
    result.cmOutput `shouldBe` Just (toValue [object ["value" .= (1 :: Int)], object ["value" .= (2 :: Int)]])

  it "runs calls awaited one after another as separate batches" $ do
    result <- simple "const a = await tools.echo({value:1}); const b = await tools.echo({value:a.value + 1}); return b.value;"
    result.cmOutput `shouldBe` Just (Number 2)
    length result.cmCalls `shouldBe` 2

  it "names the missing await instead of reading undefined" $ do
    result <- simple "const value = tools.echo({value:1}); return value.value;"
    result.cmExit `shouldSatisfy` trapped
    result.cmOutput `shouldSatisfy` maybe False (T.isInfixOf "await" . T.pack . show)

  it "discards calls still in the outbox when the program returns" $ do
    result <- simple "tools.echo({value:1}); return 2;"
    result.cmExit `shouldBe` WasmCompleted
    result.cmOutput `shouldBe` Just (Number 2)
    map (.ccOutcome) result.cmCalls `shouldBe` []

  it "reserves the shared budget per call before launching futures" $ do
    registry <- checked [echoDefinition] [echoTool]
    (result, later) <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession (Just 1)
      result <- runJavaScript session noJournal (views registry) "return (await max.batch([1,2].map(value => ({tool:'echo',args:{value}})))).map(x => x.outcome);"
      later <- executeToolBatch session noJournal (views registry) [ToolRequest "native" "echo" (object ["value" .= (1 :: Int)])]
      pure (result, later)
    result.cmOverBudget `shouldBe` True
    result.cmOutput `shouldBe` Just (toValue [String "succeeded", String "rejected"])
    map (outcomeName . (.tiOutcome)) later.tbInvocations `shouldBe` ["rejected"]

  it "retains fault classification in both raw outcomes and ToolError" $ do
    result <- simple "const raw = await max.raw('echo', {}); try {await tools.echo({});} catch (error) {return [raw.outcome, error.outcome, error.code, error.retry];}"
    result.cmExit `shouldBe` WasmCompleted
    result.cmOutput `shouldBe` Just (toValue (map String ["rejected", "rejected", "invalid_arguments", "safe"]))
    uncaught <- simple "return await tools.echo({});"
    uncaught.cmSubmittedCalls `shouldBe` 1
    map (.ccOutcome) uncaught.cmCalls `shouldBe` ["rejected"]
    outcomeName (codeModeInvocation uncaught).tiOutcome `shouldBe` "failed-before-effect"

  it "keeps committed receipts when later JavaScript throws" $ do
    count <- newIORef (0 :: Int)
    let definition = echoDefinition {tdEffects = Set.singleton (EffectWrite "test"), tdRetryClass = RetryUnsafe, tdParallelism = SequentialOnly, tdFailuresPrecedeEffects = False}
        runner = echoTool {toolRunner = LegacyRunner $ \value -> liftIO (modifyIORef' count (+ 1)) >> pure (Right value)}
    registry <- checked [definition] [runner]
    result <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      runJavaScript session noJournal (views registry) "await tools.echo({value:1}); throw new Error('after commit');"
    result.cmExit `shouldSatisfy` trapped
    map (.ccOutcome) result.cmCalls `shouldBe` ["committed"]
    result.cmOutput `shouldBe` Just (object ["error" .= ("Error: after commit" :: Text)])
    readIORef count `shouldReturn` 1

  it "has no ambient APIs or raw bridge, and cannot call hidden or recursive tools" $ do
    result <- simple "return ['fetch','require','process','console','setTimeout','Date','__maxCall'].map(x => typeof globalThis[x]).concat(typeof Math.random);"
    result.cmOutput `shouldBe` Just (toValue (replicate 8 (String "undefined")))
    forM_ ["return max.raw('hidden',{});", "return max.raw('run_code',{code:'return 1'});"] $ \source -> do
      rejected <- simple source
      rejected.cmExit `shouldSatisfy` trapped
      rejected.cmCalls `shouldBe` []

  it "isolates globals between runs" $ do
    _ <- simple "globalThis.leaked = 'secret'; return 1;"
    result <- simple "return globalThis.leaked;"
    result.cmOutput `shouldBe` Just Null

  it "fails syntax errors, unresolved promises, unhandled rejections and invalid output" $ do
    forM_
      [ "return (",
        "await new Promise(() => {});",
        "Promise.reject(new Error('floating')); return 1;",
        "return 1n;",
        "const a = {}; a.a = a; return a;",
        "return 'x'.repeat(70000);"
      ]
      $ \source -> do
        result <- simple source
        result.cmExit `shouldSatisfy` trapped
        result.cmCalls `shouldBe` []
        outcomeName (codeModeInvocation result).tiOutcome `shouldBe` "failed-before-effect"

  it "drains promise jobs but discards their unawaited outbox at return" $ do
    result <- simple "const value = Promise.reject('handled'); value.catch(() => {}); Promise.resolve().then(() => tools.echo({value:1})); return 2;"
    result.cmExit `shouldBe` WasmCompleted
    result.cmOutput `shouldBe` Just (Number 2)
    length result.cmCalls `shouldBe` 0

  it "interrupts unbounded JavaScript with guest fuel" $ do
    registry <- checked [echoDefinition] [echoTool]
    result <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      runWasmProgram session noJournal (views registry) javaScriptLimits {wlFuel = 10000000} (javaScriptProgram (views registry) "for (;;) {}")
    result.cmExit `shouldSatisfy` trapped

  it "returns Promise.race's first completion and cancels remaining calls at return" $ do
    entered <- newEmptyMVar
    blocked <- newEmptyMVar
    ended <- newEmptyMVar
    let runner args = liftIO $ case valueOf args of
          Just (Number 1) -> takeMVar entered >> pure (Right args)
          _ -> (putMVar entered () >> takeMVar blocked >> pure (Right args)) `Exception.finally` putMVar ended ()
    registry <- checked [echoDefinition] [echoTool {toolRunner = LegacyRunner runner}]
    result <- timeout 3000000 . runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      runJavaScript session noJournal (views registry) "return await Promise.race([tools.echo({value:1}), tools.echo({value:2})]);"
    fmap (.cmOutput) result `shouldBe` Just (Just (object ["value" .= (1 :: Int)]))
    timeout 1000000 (takeMVar ended) `shouldReturn` Just ()
    fmap (map (.ccOutcome) . (.cmCalls)) result `shouldBe` Just ["succeeded", "outcome-unknown"]

  it "max.race cancels a loser before the program continues with another tool" $ do
    entered <- newEmptyMVar
    blocked <- newEmptyMVar
    ended <- newEmptyMVar
    let runner args = liftIO $ case valueOf args of
          Just (Number 1) -> takeMVar entered >> pure (Right args)
          Just (Number 2) -> (putMVar entered () >> takeMVar blocked >> pure (Right args)) `Exception.finally` putMVar ended ()
          _ -> takeMVar ended >> pure (Right args)
    registry <- checked [echoDefinition] [echoTool {toolRunner = LegacyRunner runner}]
    result <- timeout 3000000 . runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      runJavaScript session noJournal (views registry) "await max.race([tools.echo({value:1}), tools.echo({value:2})]); return await tools.echo({value:3});"
    fmap (.cmOutput) result `shouldBe` Just (Just (object ["value" .= (3 :: Int)]))

  it "Promise.race leaves its loser available to await later" $ do
    entered <- newEmptyMVar
    release <- newEmptyMVar
    let runner args = liftIO $ case valueOf args of
          Just (Number 1) -> takeMVar entered >> pure (Right args)
          Just (Number 2) -> putMVar entered () >> takeMVar release >> pure (Right args)
          _ -> putMVar release () >> pure (Right args)
    registry <- checked [echoDefinition] [echoTool {toolRunner = LegacyRunner runner}]
    result <- timeout 3000000 . runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      runJavaScript session noJournal (views registry) "const p = tools.echo({value:2}); await Promise.race([tools.echo({value:1}), p]); await tools.echo({value:3}); return await p;"
    fmap (.cmOutput) result `shouldBe` Just (Just (object ["value" .= (2 :: Int)]))

  it "starts each pipeline's next call before unrelated searches finish" $ do
    agentStarted <- newEmptyMVar
    let runner args = liftIO $ case valueOf args of
          Just (Number 2) -> takeMVar agentStarted >> pure (Right args)
          Just (Number 11) -> putMVar agentStarted () >> pure (Right args)
          _ -> pure (Right args)
    registry <- checked [echoDefinition] [echoTool {toolRunner = LegacyRunner runner}]
    result <- timeout 3000000 . runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      runJavaScript session noJournal (views registry) "return await Promise.all([1,2].map(async value => { const r = await tools.echo({value}); return (await tools.echo({value:r.value+10})).value; }));"
    fmap (.cmOutput) result `shouldBe` Just (Just (toValue [Number 11, Number 12]))

  it "cancels an outbox call once and provides a safe rejection without effects" $ do
    result <- simple "const p=max.raw('echo',{value:1}); max.cancel(p); max.cancel(p); return await p;"
    result.cmExit `shouldBe` WasmCompleted
    result.cmCalls `shouldBe` []
    result.cmOutput `shouldBe` Just (object ["outcome" .= ("rejected" :: Text), "error" .= object ["code" .= ("cancelled" :: Text), "message" .= ("call cancelled" :: Text), "retry" .= ("safe" :: Text)]])

  it "supports sleep futures without exposing a clock" $ do
    result <- simple "await max.sleep(1); return typeof Date;"
    result.cmOutput `shouldBe` Just (String "undefined")
    map (.ccTool) result.cmCalls `shouldBe` ["$sleep"]

  it "bounds in-flight calls and drains all queued calls without a batch barrier" $ do
    result <- simple "return (await Promise.all(Array.from({length:130}, (_,value) => tools.echo({value})))).map(x=>x.value);"
    result.cmExit `shouldBe` WasmCompleted
    result.cmOutput `shouldBe` Just (toJSON ([0 .. 129] :: [Int]))
    length result.cmCalls `shouldBe` 130

  it "refuses the 4097th guest call before its effect across multiple outbox drains" $ do
    effects <- newIORef (0 :: Int)
    registry <- checked [echoDefinition] [echoTool {toolRunner = LegacyRunner $ \args -> liftIO (atomicModifyIORef' effects (\n -> (n + 1, ()))) >> pure (Right args)}]
    result <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      runJavaScript session noJournal (views registry) "const r=await Promise.all(Array.from({length:4097},(_,value)=>max.raw('echo',{value}))); return {succeeded:r.filter(x=>x.outcome==='succeeded').length,last:r[4096]};"
    result.cmExit `shouldBe` WasmCompleted
    result.cmOutput `shouldBe` Just (object ["succeeded" .= (4096 :: Int), "last" .= object ["outcome" .= ("rejected" :: Text), "error" .= object ["code" .= ("guest_call_limit" :: Text), "message" .= ("program leaf call limit exceeded" :: Text), "retry" .= ("safe" :: Text)]]])
    result.cmSubmittedCalls `shouldBe` 4097
    readIORef effects `shouldReturn` 4096

  it "delivers a 4 MiB outcome but refuses one extra byte without replaying its effect" $ do
    effects <- newIORef (0 :: Int)
    let overhead = fromIntegral (LBS.length (encode (outcomeEnvelope (ToolSucceeded (String "")))))
        chars = 4 * 1024 * 1024 - overhead
        runner args = do
          liftIO (atomicModifyIORef' effects (\n -> (n + 1, ())))
          pure (Right (String (T.replicate (chars + if valueOf args == Just (Number 2) then 1 else 0) "x")))
    registry <- checked [echoDefinition] [echoTool {toolRunner = LegacyRunner runner}]
    result <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      runJavaScript session noJournal (views registry) "const first=await tools.echo({value:1}); const second=await max.raw('echo',{value:2}); return {chars:first.length,second};"
    result.cmExit `shouldBe` WasmCompleted
    result.cmOutput `shouldBe` Just (object ["chars" .= chars, "second" .= object ["outcome" .= ("outcome-unknown" :: Text), "error" .= object ["code" .= ("result_too_large" :: Text), "message" .= ("tool result exceeds 4 MiB; do not replay effects" :: Text), "retry" .= ("unsafe" :: Text)]]])
    readIORef effects `shouldReturn` 2

  it "delivers more than one resume worth of large outcomes without losing any" $ do
    let payload = T.replicate (3 * 1024 * 1024) "x"
    registry <- checked [echoDefinition] [echoTool {toolRunner = LegacyRunner $ \args -> pure (Right (object ["arg" .= args, "text" .= payload]))}]
    result <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      runJavaScript session noJournal (views registry) "return (await Promise.all([1,2,3,4,5,6].map(value=>tools.echo({value})))).map(x=>[x.arg.value,x.text.length]);"
    result.cmExit `shouldBe` WasmCompleted
    result.cmOutput `shouldBe` Just (toJSON [[n, 3 * 1024 * 1024] | n <- [1 .. 6 :: Int]])

  it "rejects hidden, mixed and oversized model submissions before any effect" $ do
    count <- newIORef (0 :: Int)
    registry <- checked [echoDefinition] [echoTool {toolRunner = LegacyRunner $ \value -> liftIO (modifyIORef' count (+ 1)) >> pure (Right value)}]
    forM_
      [ (False, [code "return 1"]),
        (True, [code "return 1", ToolRequest "leaf" "echo" (object ["value" .= (1 :: Int)])]),
        (True, [code (T.replicate 65537 "x")]),
        (True, [ToolRequest "bad-resume" "run_code_resume" (object ["code" .= ("return await tools.echo({value:1});" :: Text)])]),
        (True, [ToolRequest "bad-cancel" "run_code_cancel" (object ["code" .= ("return 1" :: Text)])]),
        (True, [ToolRequest "bad-wait" "execution_wait" (object ["code" .= ("return 1" :: Text)])])
      ]
      $ \(enabled, calls) -> do
        result <- runEff . runConcurrent . runTools registry $ do
          session <- newExecutionSession Nothing
          executeModelBatch enabled Map.empty session noJournal (views registry) calls
        map (outcomeName . (.tiOutcome)) result.tbInvocations `shouldBe` replicate (length calls) "rejected"
    readIORef count `shouldReturn` 0
  where
    code :: Text -> ToolRequest
    code source = ToolRequest "model-code" "run_code" (object ["code" .= source])

codeValue :: ToolInvocation -> Maybe Value
codeValue invocation = case invocation.tiOutcome of
  ToolSucceeded (Object fields) -> KM.lookup "value" fields
  _ -> Nothing

guestEvents :: Events.Task -> STM [Text]
guestEvents target = do
  snapshot <- Events.readObservations target
  pure [reference | Events.GuestReady reference <- NodeLog.deliveredBetween (Events.observationOwner target) (NodeLog.logCursor NodeLog.emptyLog) (NodeLog.logCursor snapshot) snapshot]

programEvents :: Events.Task -> IO [(Value, [InlineMedia])]
programEvents target = atomically $ do
  snapshot <- Events.readObservations target
  let events = NodeLog.deliveredBetween (Events.observationOwner target) (NodeLog.logCursor NodeLog.emptyLog) (NodeLog.logCursor snapshot) snapshot
  pure [(value, media) | Events.Settled _ value media <- events]

valueOf :: Value -> Maybe Value
valueOf = \case
  Object fields -> KM.lookup "value" fields
  _ -> Nothing

objectiveOf :: Value -> Maybe Value
objectiveOf = \case
  Object fields -> KM.lookup "objective" fields
  _ -> Nothing

simple :: Text -> IO CodeModeResult
simple source = do
  registry <- checked [echoDefinition] [echoTool]
  runEff . runConcurrent . runTools registry $ do
    session <- newExecutionSession Nothing
    runJavaScript session noJournal (views registry) source

checked :: [ToolDefinition] -> [Tool es] -> IO (ToolRegistry es)
checked definitions = either (fail . show) pure . buildToolRegistry definitions

views :: ToolRegistry es -> [CatalogTool]
views = catalogTools . registryCatalog

toValue :: [Value] -> Value
toValue = toJSON

trapped :: WasmExit -> Bool
trapped WasmTrapped {} = True
trapped _ = False
