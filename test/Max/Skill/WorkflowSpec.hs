module Max.Skill.WorkflowSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Either (isLeft)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Concurrent (runConcurrent)
import ExecutionFixture
import Max.CodeMode.Execution
import Max.CodeMode.JavaScript
import Max.CodeMode.Model
import Max.Effects.ToolControl (runToolControl)
import Max.Effects.Tools
import Max.Execution.Tools
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..), noAdvertisedCaps)
import Max.Skill.Contract
import Max.Skill.Package
import Max.Skill.Workflow
import Max.Skills
import Max.Tool.Bundles
import Max.Tool.Catalog (catalogTools)
import Max.Tool.Control (controlSkillLoads)
import Max.ToolContext
import Max.Tools.Skills (skillToolsFor)
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec hiding (context)

spec :: Spec
spec = describe "saved skill workflows" $ do
  it "validates nested contracts and rejects unsupported schema semantics" $ do
    let schema = object ["type" .= ("array" :: Text), "items" .= inputContract, "maxItems" .= (2 :: Int)]
    validateContract schema `shouldBe` Right ()
    validateValue schema (toJSON [object ["value" .= (3 :: Int)]]) `shouldBe` Right ()
    forM_ [toJSON [object ["value" .= ("wrong" :: Text)]], toJSON [object ["value" .= (3 :: Int), "extra" .= True]], toJSON (replicate 3 (object ["value" .= (1 :: Int)]))] $ \args ->
      validateValue schema args `shouldSatisfy` isLeft
    validateContract (object ["type" .= ("string" :: Text), "pattern" .= (".*" :: Text)]) `shouldSatisfy` isLeft

  it "pins source and the host contract, rejecting changed or unavailable tools" $ do
    registry <- checked [echoDefinition] [echoTool]
    loads <- pin (views registry) baseWorkflow
    let resolve catalog = resolveWorkflow loads catalog "demo/run" arguments
    resolve (views registry) `shouldSatisfy` either (const False) (const True)
    resolve [] `shouldSatisfy` isLeft
    resolve [entry {ctDefinition = entry.ctDefinition {tdRetryClass = RetryUnsafe}} | entry <- views registry] `shouldSatisfy` isLeft
    resolve [entry {ctSchemaHash = SchemaHash "changed"} | entry <- views registry] `shouldSatisfy` isLeft
    resolveWorkflow Map.empty (views registry) "demo/run" arguments `shouldSatisfy` isLeft
    changed <- pin (views registry) baseWorkflow {wfSource = "return {value:99};"}
    fmap (.slVersion) (Map.lookup "demo" changed) `shouldNotBe` fmap (.slVersion) (Map.lookup "demo" loads)

  it "runs pinned code with independent arguments and shares native leaf budget" $ do
    registry <- checked [echoDefinition] [echoTool]
    loads <- pin (views registry) baseWorkflow
    (saved, native) <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession (Just 1)
      saved <- executeModelBatch True loads session noJournal (views registry) [submission arguments]
      native <- executeToolBatch session noJournal (views registry) [ToolRequest "native" "echo" arguments]
      pure (saved, native)
    resultValue saved `shouldBe` Just arguments
    native.tbOverBudget `shouldBe` True

  it "rejects invalid saved arguments before any invocation" $ do
    count <- newIORef (0 :: Int)
    registry <- checked [echoDefinition] [echoTool {toolRun = \value -> liftIO (modifyIORef' count (+ 1)) >> pure (Right value)}]
    loads <- pin (views registry) baseWorkflow
    result <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      executeModelBatch True loads session noJournal (views registry) [submission (object ["value" .= ("not an integer" :: Text)])]
    map (outcomeName . (.tiOutcome)) result.tbInvocations `shouldBe` ["rejected"]
    readIORef count `shouldReturn` 0

  it "passes JSON arguments as data including __proto__ and source-like strings" $ do
    registry <- checked [] []
    let arbitraryObject = object ["type" .= ("object" :: Text), "additionalProperties" .= True]
        workflow = baseWorkflow {wfTools = [], wfSource = "return args;", wfInput = arbitraryObject, wfOutput = arbitraryObject}
        args = object ["__proto__" .= object ["polluted" .= True], "text" .= ("\"); tools.echo({value:9}); // 中文" :: Text)]
    loads <- pin [] workflow
    result <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      executeModelBatch True loads session noJournal [] [submission args]
    resultValue result `shouldBe` Just args

  it "enforces the selected catalog on the host even when guest SDK checks are bypassed" $ do
    count <- newIORef (0 :: Int)
    registry <- checked [echoDefinition] [echoTool {toolRun = \value -> liftIO (modifyIORef' count (+ 1)) >> pure (Right value)}]
    binary <- guestCalls [object ["tool" .= ("echo" :: Text), "args" .= arguments]] ""
    result <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      runWasmTools session noJournal [] javaScriptLimits binary
    map (.ccOutcome) result.cmCalls `shouldBe` ["rejected"]
    readIORef count `shouldReturn` 0

  it "keeps committed leaves when a saved output violates its contract" $ do
    count <- newIORef (0 :: Int)
    let definition = echoDefinition {tdEffects = Set.singleton (EffectWrite "test"), tdRetryClass = RetryUnsafe, tdParallelism = SequentialOnly}
    registry <- checked [definition] [echoTool {toolRun = \value -> liftIO (modifyIORef' count (+ 1)) >> pure (Right value)}]
    loads <- pin (views registry) baseWorkflow {wfSource = "tools.echo(args); return 'invalid';"}
    result <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      executeModelBatch True loads session noJournal (views registry) [submission arguments]
    map (outcomeName . (.tiOutcome)) result.tbInvocations `shouldBe` ["outcome-unknown"]
    readIORef count `shouldReturn` 1

  it "loads complete workflow dependencies and contracts without exposing source" $ do
    reg <- newSkillRegistry
    registry <- checked [echoDefinition {tdRef = ToolRef "web_search"}] [echoTool {toolName = "web_search"}]
    let load catalog = case skillToolsFor reg context (const (pure (Right Nothing))) (bindWorkflowContracts catalog) of
          [runner] -> runEff (runToolControl (runner.toolRun (object ["name" .= ("batch-search" :: Text)])))
          _ -> fail "missing loader"
    (value, control) <- load (views registry)
    let loads = controlSkillLoads control
    map (.slName) loads `shouldBe` ["web", "codemode", "batch-search"]
    case value of
      Right body -> do
        show body `shouldContain` "batch-search/search"
        show body `shouldNotContain` "const outcomes"
      Left err -> expectationFailure (T.unpack err)
    (missing, rejected) <- load []
    missing `shouldSatisfy` isLeft
    controlSkillLoads rejected `shouldBe` []

  it "executes the embedded batch search and retains failed queries" $ do
    reg <- newSkillRegistry
    Just skill <- lookupSkill reg (GroupId 7777) "batch-search"
    let runner = echoTool {toolName = "web_search", toolSchema = object ["type" .= ("object" :: Text)], toolRun = \value -> pure $ if field "query" value == Just (String "bad") then Left "search unavailable" else Right (object ["results" .= [object ["title" .= ("source" :: Text), "url" .= ("https://example.test" :: Text), "snippet" .= ("evidence" :: Text)]]])}
    registry <- checked [echoDefinition {tdRef = ToolRef "web_search"}] [runner]
    let workflow = skill.skillPackage.spWorkflows Map.! "search"
    result <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      runWasmProgram session noJournal (views registry) javaScriptLimits (workflowProgram (views registry) "batch-search/search" "test" workflow (object ["queries" .= (["good", "bad"] :: [Text]), "limit" .= (2 :: Int)]))
    outcomeName (codeModeInvocation result).tiOutcome `shouldBe` "succeeded"
    case result.cmOutput of
      Just (Array rows) -> map (field "outcome") (foldr (:) [] rows) `shouldBe` [Just (String "succeeded"), Just (String "failed-before-effect")]
      other -> expectationFailure (show other)

  it "executes fleet health without interpreting unavailable observations as healthy" $ do
    reg <- newSkillRegistry
    Just skill <- lookupSkill reg (GroupId 7777) "fleet-health"
    let overview = object ["hosts" .= [object ["host" .= ("h610" :: Text), "assessment" .= ("agent_unavailable" :: Text), "agent" .= object ["state" .= ("unavailable" :: Text), "failed_units" .= Null]]]]
        units = object ["hosts" .= [object ["host" .= ("h610" :: Text), "state" .= ("unavailable" :: Text), "units" .= Null]]]
        names = ["maxops_fleet_overview", "maxops_units_failed"]
        runners = [echoTool {toolName = name, toolSchema = object ["type" .= ("object" :: Text)], toolRun = const (pure (Right value))} | (name, value) <- zip names [overview, units]]
    registry <- checked [echoDefinition {tdRef = ToolRef name} | name <- names] runners
    let workflow = skill.skillPackage.spWorkflows Map.! "check"
    result <- runEff . runConcurrent . runTools registry $ do
      session <- newExecutionSession Nothing
      runWasmProgram session noJournal (views registry) javaScriptLimits (workflowProgram (views registry) "fleet-health/check" "test" workflow (object ["hosts" .= (["h610"] :: [Text])]))
    outcomeName (codeModeInvocation result).tiOutcome `shouldBe` "succeeded"
    case result.cmOutput >>= field "hosts" of
      Just (Array rows) -> map (field "failed_count") (foldr (:) [] rows) `shouldBe` [Just Null]
      other -> expectationFailure (show other)

inputContract :: Value
inputContract = object ["type" .= ("object" :: Text), "properties" .= object ["value" .= object ["type" .= ("integer" :: Text)]], "required" .= (["value"] :: [Text]), "additionalProperties" .= False]

arguments :: Value
arguments = object ["value" .= (7 :: Int)]

baseWorkflow :: Workflow
baseWorkflow = Workflow "echo" "return tools.echo(args);" inputContract inputContract ["echo"]

pin :: [CatalogTool] -> Workflow -> IO (Map.Map Text SkillLoad)
pin catalog workflow = do
  let package = SkillPackage [] (Map.singleton "run" workflow)
      load = SkillLoad "demo" "" "instructions" Nothing (Just (PinnedPackage 1 package Map.empty))
  loads <- either (fail . T.unpack) pure (bindWorkflowContracts catalog [load])
  pure (Map.fromList [(l.slName, l) | l <- loads])

submission :: Value -> ToolRequest
submission args = ToolRequest "saved" "run_code" (object ["workflow" .= ("demo/run" :: Text), "args" .= args])

checked :: [ToolDefinition] -> [Tool es] -> IO (ToolRegistry es)
checked definitions = either (fail . show) pure . buildToolRegistry definitions

views :: ToolRegistry es -> [CatalogTool]
views = catalogTools . registryCatalog

resultValue :: ToolBatch -> Maybe Value
resultValue batch = case batch.tbInvocations of
  [ToolInvocation (ToolSucceeded value) _] -> field "value" value
  _ -> Nothing

field :: Key -> Value -> Maybe Value
field name (Object o) = KM.lookup name o
field _ _ = Nothing

context :: ToolContext
context =
  mkToolContext
    (TurnIdentity (GroupId 7777) (CanonicalMessageId 1) (UserId 2) (UserId 3) (PrincipalId 2) Nothing Nothing)
    (TurnCapabilities False False True noAdvertisedCaps False Map.empty Nothing False)
