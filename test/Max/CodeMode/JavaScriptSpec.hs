module Max.CodeMode.JavaScriptSpec (spec) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM_)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (liftIO, runEff)
import Effectful.Concurrent (runConcurrent)
import ExecutionFixture
import Max.CodeMode.Execution
import Max.CodeMode.JavaScript
import Max.CodeMode.Model (executeModelBatch)
import Max.CodeMode.Wasm
import Max.Effects.ToolControl (finishExecution, runToolControl)
import Max.Effects.Tools
import Max.Execution.Tools
import Max.Tool.Catalog (catalogTools)
import Max.Tool.Control (LoopControl (..))
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "JavaScript SDK in embedded Wasm" $ do
  it "cannot register run_code as a leaf runner that would recursively acquire the gate" $ do
    case buildToolRegistry [echoDefinition {tdRef = ToolRef "run_code"}] [echoTool {toolName = "run_code"}] of
      Left (InvalidToolMetadata (ToolRef "run_code") _) -> pure ()
      _ -> expectationFailure "orchestration entry was accepted as a leaf"

  it "runs async bodies with real tool values and returns selected JSON" $ do
    result <- simple "const rows = []; for (let n = 1; n <= 3; n++) rows.push((await tools.echo({value:n})).value); return {sum:rows.reduce((a,b)=>a+b), text:'中文 😀'};"
    result.cmExit `shouldBe` WasmCompleted
    result.cmOutput `shouldBe` Just (object ["sum" .= (6 :: Int), "text" .= ("中文 😀" :: Text)])
    map (.ccOutcome) result.cmCalls `shouldBe` replicate 3 "succeeded"

  it "pages large Unicode results without a second effect or budget charge" $ do
    count <- newIORef (0 :: Int)
    let payload = T.replicate 20000 "中文😀\"\\\n"
        runner = echoTool {toolRun = \_ -> liftIO (modifyIORef' count (+ 1)) >> pure (Right (object ["text" .= payload]))}
    registry <- checked [echoDefinition] [runner]
    (result, following) <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession (Just 1)
      result <- runJavaScript session noJournal (views registry) "const value = tools.echo({value:1}); return {length:[...value.text].length, tail:value.text.slice(-7)};"
      following <- executeToolBatch session noJournal (views registry) [ToolRequest "native" "echo" (object ["value" .= (2 :: Int)])]
      pure (result, following)
    result.cmExit `shouldBe` WasmCompleted
    result.cmOutput `shouldBe` Just (object ["length" .= (120000 :: Int), "tail" .= ("中文😀\"\\\n" :: Text)])
    length result.cmCalls `shouldBe` 1
    following.tbOverBudget `shouldBe` True
    readIORef count `shouldReturn` 1

  it "uses the shared parallel batch scheduler and keeps input order" $ do
    first <- newEmptyMVar
    second <- newEmptyMVar
    let runner =
          echoTool
            { toolRun = \value -> do
                liftIO $
                  if value == object ["value" .= (1 :: Int)]
                    then putMVar first () >> takeMVar second
                    else putMVar second () >> takeMVar first
                pure (Right value)
            }
    registry <- checked [echoDefinition] [runner]
    result <- timeout 30000000 . runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession (Just 2)
      runJavaScript session noJournal (views registry) "return max.batch([1,2].map(value => ({tool:'echo',args:{value}}))).map(max.value);"
    fmap (.cmExit) result `shouldBe` Just WasmCompleted
    fmap (.cmOutput) result `shouldBe` Just (Just (toValue [object ["value" .= (1 :: Int)], object ["value" .= (2 :: Int)]]))

  it "rejects a batch atomically when the shared call budget is too small" $ do
    registry <- checked [echoDefinition] [echoTool]
    (result, later) <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession (Just 1)
      result <- runJavaScript session noJournal (views registry) "return max.batch([1,2].map(value => ({tool:'echo',args:{value}}))).map(x => x.outcome);"
      later <- executeToolBatch session noJournal (views registry) [ToolRequest "native" "echo" (object ["value" .= (1 :: Int)])]
      pure (result, later)
    result.cmOverBudget `shouldBe` True
    result.cmOutput `shouldBe` Just (toValue [String "rejected", String "rejected"])
    map (outcomeName . (.tiOutcome)) later.tbInvocations `shouldBe` ["succeeded"]

  it "retains fault classification in both raw outcomes and ToolError" $ do
    result <- simple "const raw = max.raw('echo', {}); try {tools.echo({});} catch (error) {return [raw.outcome, error.outcome, error.code, error.retry];}"
    result.cmExit `shouldBe` WasmCompleted
    result.cmOutput `shouldBe` Just (toValue (map String ["rejected", "rejected", "invalid_arguments", "safe"]))
    uncaught <- simple "return tools.echo({});"
    uncaught.cmSubmittedCalls `shouldBe` 1
    map (.ccOutcome) uncaught.cmCalls `shouldBe` ["rejected"]
    outcomeName (codeModeInvocation uncaught).tiOutcome `shouldBe` "failed-before-effect"

  it "keeps committed receipts when later JavaScript throws" $ do
    count <- newIORef (0 :: Int)
    let definition = echoDefinition {tdEffects = Set.singleton (EffectWrite "test"), tdRetryClass = RetryUnsafe, tdParallelism = SequentialOnly, tdFailuresPrecedeEffects = False}
        runner = echoTool {toolRun = \value -> liftIO (modifyIORef' count (+ 1)) >> pure (Right value)}
    registry <- checked [definition] [runner]
    result <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      runJavaScript session noJournal (views registry) "tools.echo({value:1}); throw new Error('after commit');"
    result.cmExit `shouldSatisfy` trapped
    map (.ccOutcome) result.cmCalls `shouldBe` ["committed"]
    result.cmOutput `shouldBe` Just (object ["error" .= ("Error: after commit" :: Text)])
    readIORef count `shouldReturn` 1

  it "stops at host finish and suppresses conflicting batch work" $ do
    count <- newIORef (0 :: Int)
    let done = echoTool {toolName = "done", toolRun = \args -> finishExecution (Just "finished") >> pure (Right args)}
        finish = echoDefinition {tdRef = ToolRef "done", tdCallMode = FinishCall, tdParallelism = SequentialOnly}
        runner = echoTool {toolRun = \value -> liftIO (modifyIORef' count (+ 1)) >> pure (Right value)}
    registry <- checked [echoDefinition, finish] [runner, done]
    result <- runEff . runConcurrent . runToolsWithControl runToolControl registry $ do
      session <- newExecutionSession Nothing
      runJavaScript session noJournal (views registry) "max.batch([{tool:'echo',args:{value:1}},{tool:'done',args:{value:2}}]); tools.echo({value:3}); throw new Error('unreachable');"
    result.cmExit `shouldBe` WasmHostStopped
    result.cmControl `shouldBe` FinishLoop (Just "finished")
    map (.ccOutcome) result.cmCalls `shouldBe` ["rejected", "succeeded"]
    readIORef count `shouldReturn` 0

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
    registry <- checked [echoDefinition] [echoTool {toolRun = \value -> liftIO (takeMVar blocked) >> pure (Right value)}]
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
    registry <- checked [echoDefinition] [echoTool {toolRun = \value -> liftIO (modifyIORef' count (+ 1)) >> pure (Right value)}]
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
