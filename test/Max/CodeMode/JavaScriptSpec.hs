module Max.CodeMode.JavaScriptSpec (spec) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM_)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Effectful (liftIO, runEff)
import Effectful.Concurrent (runConcurrent)
import ExecutionFixture
import Max.Browser.View (browserBudget, browserView)
import Max.CodeMode.Execution
import Max.CodeMode.JavaScript
import Max.CodeMode.Model (executeModelBatch)
import Max.CodeMode.Wasm
import Max.Effects.Tools
import Max.Execution.Tools
import Max.Execution.Workflow
import Max.Tool.Catalog (catalogTools)
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "JavaScript SDK in embedded Wasm" $ do
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
  it "stops guest execution when a waiting agent call returns for pending feedback" $ do
    count <- newIORef (0 :: Int)
    let definition = echoDefinition {tdRef = ToolRef "agent", tdParallelism = ParallelIndependent}
        runner _ = liftIO (modifyIORef' count (+ 1)) >> pure (Right (object ["agent" .= ("agent#1" :: Text), "feedback_pending" .= True]))
    registry <- checked [definition] [legacyTool "agent" "agent" (object ["type" .= ("object" :: Text)]) runner]
    result <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession (Just 3)
      runJavaScript session noJournal (views registry) "await agent({objective:'one',profile:'basic'}); await agent({objective:'two',profile:'basic'}); return 'unreachable';"
    result.cmExit `shouldBe` WasmHostStopped
    readIORef count `shouldReturn` 1
  it "rejects run_code for a leaf agent before any guest work" $ do
    let host = WorkflowHost (pure False)
    registry <- checked [echoDefinition] [echoTool]
    result <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      executeModelBatch True Map.empty session noJournal {ehWorkflow = Just host} (views registry) [ToolRequest "child" "run_code" (object ["code" .= ("return await tools.echo({value:1});" :: Text)])]
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

  it "still runs a call nobody awaited before publishing the result" $ do
    result <- simple "tools.echo({value:1}); return 2;"
    result.cmExit `shouldBe` WasmCompleted
    result.cmOutput `shouldBe` Just (Number 2)
    map (.ccOutcome) result.cmCalls `shouldBe` ["succeeded"]

  it "rejects a batch atomically when the shared call budget is too small" $ do
    registry <- checked [echoDefinition] [echoTool]
    (result, later) <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession (Just 1)
      result <- runJavaScript session noJournal (views registry) "return (await max.batch([1,2].map(value => ({tool:'echo',args:{value}})))).map(x => x.outcome);"
      later <- executeToolBatch session noJournal (views registry) [ToolRequest "native" "echo" (object ["value" .= (1 :: Int)])]
      pure (result, later)
    result.cmOverBudget `shouldBe` True
    result.cmOutput `shouldBe` Just (toValue [String "rejected", String "rejected"])
    map (outcomeName . (.tiOutcome)) later.tbInvocations `shouldBe` ["succeeded"]

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

  it "allows a caught rejection and still drains scheduled jobs before returning" $ do
    result <- simple "const value = Promise.reject('handled'); value.catch(() => {}); Promise.resolve().then(() => tools.echo({value:1})); return 2;"
    result.cmExit `shouldBe` WasmCompleted
    result.cmOutput `shouldBe` Just (Number 2)
    length result.cmCalls `shouldBe` 1

  it "interrupts unbounded JavaScript with guest fuel" $ do
    registry <- checked [echoDefinition] [echoTool]
    result <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      runWasmProgram session noJournal (views registry) javaScriptLimits {wlFuel = 10000000} (javaScriptProgram (views registry) "for (;;) {}")
    result.cmExit `shouldSatisfy` trapped

  it "does not call an interrupted host effect safe merely because its receipt is missing" $ do
    blocked <- newEmptyMVar
    registry <- checked [echoDefinition] [echoTool {toolRunner = LegacyRunner $ \value -> liftIO (takeMVar blocked) >> pure (Right value)}]
    result <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      runWasmProgram
        session
        noJournal
        (views registry)
        javaScriptLimits {wlTimeoutMicros = 5000000}
        (javaScriptProgram (views registry) "tools.echo({value:1});")
    result.cmExit `shouldBe` WasmTimedOut
    result.cmCalls `shouldBe` []
    result.cmSubmittedCalls `shouldBe` 1
    outcomeName (codeModeInvocation result).tiOutcome `shouldBe` "outcome-unknown"

  it "rejects hidden, mixed and oversized model submissions before any effect" $ do
    count <- newIORef (0 :: Int)
    registry <- checked [echoDefinition] [echoTool {toolRunner = LegacyRunner $ \value -> liftIO (modifyIORef' count (+ 1)) >> pure (Right value)}]
    forM_
      [ (False, [code "return 1"]),
        (True, [code "return 1", ToolRequest "leaf" "echo" (object ["value" .= (1 :: Int)])]),
        (True, [code (T.replicate 65537 "x")])
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
