module Max.SkillAuthoringSpec (spec) where

import Control.Concurrent.Async (concurrently)
import Control.Monad (void)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Either (isLeft, isRight)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Effectful (runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.PostgreSQL (execute, query)
import ExecutionFixture (echoDefinition, echoTool, noJournal)
import Helpers (truncateAll, withDb)
import Max.CodeMode.JavaScript (javaScriptRuntimeVersion)
import Max.CodeMode.Model (executeModelBatch)
import Max.DB.Connection (DbPool)
import Max.DB.Task (claimFrontend)
import Max.DB.TaskSpec (seed)
import Max.DB.Transaction (withTransaction)
import Max.Effects.ToolControl (runToolControl)
import Max.Effects.Tools
import Max.Execution.Tools
import Max.Platform.Types (noAdvertisedCaps)
import Max.Skill.Authoring
import Max.Skill.Package
import Max.Skill.ToolRuntime (skillAuthoringToolsWithDatabase)
import Max.Skill.Workflow (bindWorkflowContracts)
import Max.Skills
import Max.Tool.Bundles (toolVisible)
import Max.Tool.Catalog (catalogTools)
import Max.Tool.Control (controlSkillLoads)
import Max.ToolContext
import Max.Tools.Skills (skillToolsFor)
import Max.Turn.Types
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec hiding (context)

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "model skill authoring lifecycle" $ do
  it "persists validation evidence independently of draft revision and rejects drift after restart" $ do
    (registry, context) <- setup pool
    Right _ <- call pool registry context "skill_save" (saveArgs draft 0)
    Right _ <- call pool registry context "skill_save" (saveArgs draft 1)
    Right checked <- call pool registry context "skill_validate" (reference 2)
    let proof = field "validation_id" checked
    Right _ <- call pool registry context "skill_publish" (object ["name" .= draft.dcName, "revision" .= (2 :: Int), "validation_id" .= proof, "expected_revision" .= (0 :: Int)])
    restarted <- newSkillRegistry
    _ <- withDb pool (loadSkills restarted)
    Just published <- lookupSkill restarted (GroupId 900) draft.dcName
    published.skillRevision `shouldBe` 1
    published.skillEvidence `shouldSatisfy` \case ValidatedSkill _ -> True; _ -> False
    _ <- load restarted context draft.dcName
    [loader] <- pure (skillToolsFor restarted context (const (pure (Right Nothing))) (bindWorkflowContracts "changed-runtime" (toolSkillLoads context) []))
    (rejected, control) <- runEff (runToolControl (loader.toolRun (object ["name" .= draft.dcName])))
    rejected `shouldSatisfy` isLeft
    controlSkillLoads control `shouldBe` []
    -- Admin changes preserve the certificate, including across cache reload.
    Right _ <- withDb pool (updateSkill restarted published.skillId (\s -> s {skillBody = "changed instructions"}))
    _ <- withDb pool (loadSkills restarted)
    [changed] <- pure (skillToolsFor restarted context (const (pure (Right Nothing))) (bindWorkflowContracts javaScriptRuntimeVersion (toolSkillLoads context) []))
    (stale, activation) <- runEff (runToolControl (changed.toolRun (object ["name" .= draft.dcName])))
    stale `shouldSatisfy` isLeft
    controlSkillLoads activation `shouldBe` []

  it "loads the complete authoring bundle and saves, validates, publishes and runs a workflow" $ do
    (registry, context) <- setup pool
    mapM_ (\name -> toolVisible Map.empty name `shouldBe` False) ["skill_save", "skill_inspect", "skill_validate", "skill_publish"]
    mapM_ (\name -> toolVisible (toolSkillLoads context) name `shouldBe` True) ["skill_save", "skill_inspect", "skill_validate", "skill_publish"]
    call pool registry context "skill_save" (saveArgs draft 0) >>= (`shouldSatisfy` isRight)
    lookupSkill registry (GroupId 900) "double-value" `shouldReturn` Nothing
    proof <- validate pool registry context
    result <- call pool registry context "skill_publish" (publishArgs proof 0)
    result `shouldSatisfy` isRight
    Just published <- lookupSkill registry (GroupId 900) "double-value"
    published.skillRevision `shouldBe` 1
    loaded <- load registry context "double-value"
    emptyRegistry <- either (fail . show) pure (buildToolRegistry [] [])
    executed <- runEff . runConcurrent . runTools emptyRegistry $ do
      session <- newExecutionSession Nothing
      executeModelBatch True (toolSkillLoads loaded) session noJournal [] [ToolRequest "saved" "run_code" (object ["workflow" .= ("double-value/run" :: Text), "args" .= object ["value" .= (4 :: Int)]])]
    map (outcomeName . (.tiOutcome)) executed.tbInvocations `shouldBe` ["succeeded"]
    rows <- withDb pool (query "SELECT (SELECT count(*) FROM skill_versions),(SELECT count(*) FROM skill_publications)" ())
    rows `shouldBe` [(1 :: Int, 1 :: Int)]
    inspect <- call pool registry context "skill_inspect" (object ["name" .= ("double-value" :: Text), "revision" .= (1 :: Int)])
    inspect `shouldSatisfy` isRight

  it "serializes concurrent draft and publication revisions across registries" $ do
    (registry, context) <- setup pool
    (a, b) <- concurrently (call pool registry context "skill_save" (saveArgs draft 0)) (call pool registry context "skill_save" (saveArgs draft 0))
    length (filter isRight [a, b]) `shouldBe` 1
    proof <- validate pool registry context
    other <- newSkillRegistry
    _ <- withDb pool (loadSkills other)
    (first, second) <- concurrently (call pool registry context "skill_publish" (publishArgs proof 0)) (call pool other context "skill_publish" (publishArgs proof 0))
    length (filter isRight [first, second]) `shouldBe` 1
    length (filter isLeft [first, second]) `shouldBe` 1

  it "fences publication and report recording after the caller expires" $ do
    (registry, context) <- setup pool
    Right _ <- call pool registry context "skill_save" (saveArgs draft 0)
    proof <- validate pool registry context
    void $ withDb pool (execute "UPDATE conversation_frontends SET lease_until=now()-interval '1 second'" ())
    call pool registry context "skill_publish" (publishArgs proof 0) >>= (`shouldSatisfy` isLeft)
    call pool registry context "skill_validate" (reference 1) >>= (`shouldSatisfy` isLeft)
    lookupSkill registry (GroupId 900) "double-value" `shouldReturn` Nothing

  it "keeps draft references group-scoped and builtin names protected" $ do
    (registry, context) <- setup pool
    Right _ <- call pool registry context "skill_save" (saveArgs draft 0)
    (_, outside) <- setupAt pool 901
    call pool registry outside "skill_validate" (reference 1) >>= (`shouldSatisfy` isLeft)
    mapM_ (\name -> call pool registry context "skill_save" (saveArgs draft {dcName = name} 0) >>= (`shouldSatisfy` isLeft)) ["web", "codemode", "skill-authoring", "learned-task-1"]

  it "cannot overwrite an admin skill or a head changed through the admin API" $ do
    (registry, context) <- setup pool
    Right _ <- call pool registry context "skill_save" (saveArgs draft 0)
    proof <- validate pool registry context
    Right _ <- call pool registry context "skill_publish" (publishArgs proof 0)
    Just published <- lookupSkill registry (GroupId 900) "double-value"
    Right _ <- withDb pool (updateSkill registry published.skillId (\s -> s {skillBody = "admin correction"}))
    call pool registry context "skill_publish" (publishArgs proof 2) >>= (`shouldSatisfy` isLeft)

  it "rejects reports from another draft and failed fixtures without publishing" $ do
    (registry, context) <- setup pool
    Right _ <- call pool registry context "skill_save" (saveArgs draft 0)
    proof <- validate pool registry context
    let changed = draft {dcBody = "new instructions"}
    Right _ <- call pool registry context "skill_save" (saveArgs changed 1)
    Right inspected <- call pool registry context "skill_inspect" (reference 2)
    field "fields" (field "diff" (field "changes_from_previous" inspected)) `shouldBe` toJSON (["body"] :: [Text])
    call pool registry context "skill_publish" (object ["name" .= ("double-value" :: Text), "revision" .= (2 :: Int), "validation_id" .= proof, "expected_revision" .= (0 :: Int)]) >>= (`shouldSatisfy` isLeft)
    let bad = draft {dcPackage = draft.dcPackage {spWorkflows = Map.map (\w -> w {wfSource = "return {value:0};"}) draft.dcPackage.spWorkflows}}
    Right _ <- call pool registry context "skill_save" (saveArgs bad 2)
    Right report <- call pool registry context "skill_validate" (reference 3)
    let badProof = field "validation_id" report
    call pool registry context "skill_publish" (object ["name" .= ("double-value" :: Text), "revision" .= (3 :: Int), "validation_id" .= badProof, "expected_revision" .= (0 :: Int)]) >>= (`shouldSatisfy` isLeft)

  it "rejects a changed dependency or tool contract after validation" $ do
    (registry, context) <- setup pool
    Right helper <- withDb pool (createSkill registry (NewSkill "helper" (Just 900) "helper instructions" "original" True Nothing emptyPackage))
    loaded <- load registry context "helper"
    let dependent = draft {dcPackage = draft.dcPackage {spDependencies = ["helper"]}}
    Right _ <- call pool registry loaded "skill_save" (saveArgs dependent 0)
    proof <- validate pool registry loaded
    Right _ <- withDb pool (updateSkill registry helper.skillId (\s -> s {skillBody = "changed"}))
    call pool registry loaded "skill_publish" (publishArgs proof 0) >>= (`shouldSatisfy` isLeft)
    let withEcho = draft {dcPackage = draft.dcPackage {spWorkflows = Map.map (\w -> w {wfSource = "return tools.echo(args);", wfTools = ["echo"]}) draft.dcPackage.spWorkflows}, dcFixtures = [Fixture "run" (object ["value" .= (3 :: Int)]) [FixtureCall "echo" (object ["value" .= (3 :: Int)]) (Right (object ["value" .= (6 :: Int)]))] (object ["value" .= (6 :: Int)])]}
        catalog = either (error . show) (catalogTools . registryCatalog) (buildToolRegistry [echoDefinition] [echoTool])
        invoke current name args = case find ((== name) . (.toolName)) (skillAuthoringToolsWithDatabase registry context (Right current)) of
          Just runner -> withDb pool (runner.toolRun args)
          Nothing -> fail "missing tool"
    Right _ <- call pool registry context "skill_save" (saveArgs withEcho 1)
    Right report <- invoke catalog "skill_validate" (reference 2)
    field "report" report `shouldBe` object ["passed" .= True, "failures" .= ([] :: [Text])]
    let changed = [t {ctSchemaHash = SchemaHash "changed"} | t <- catalog]
    invoke changed "skill_publish" (object ["name" .= ("double-value" :: Text), "revision" .= (2 :: Int), "validation_id" .= field "validation_id" report, "expected_revision" .= (0 :: Int)]) >>= (`shouldSatisfy` isLeft)

  it "requires loaded dependencies and rejects dependency cycles" $ do
    (registry, context) <- setup pool
    let web = draft {dcPackage = draft.dcPackage {spDependencies = ["web"]}}
    Right _ <- call pool registry context "skill_save" (saveArgs web 0)
    call pool registry context "skill_validate" (reference 1) >>= (`shouldSatisfy` isLeft)
    let cyclic = draft {dcPackage = draft.dcPackage {spDependencies = ["double-value"]}}
    Right _ <- call pool registry context "skill_save" (saveArgs cyclic 1)
    call pool registry context "skill_validate" (reference 2) >>= (`shouldSatisfy` isLeft)

  it "does not publish the cache inside an enclosing transaction" $ do
    (registry, context) <- setup pool
    Right _ <- call pool registry context "skill_save" (saveArgs draft 0)
    proof <- validate pool registry context
    runner <- maybe (fail "missing publication tool") pure (find ((== "skill_publish") . (.toolName)) (skillAuthoringToolsWithDatabase registry context (Right [])))
    withDb pool (withTransaction (runner.toolRun (publishArgs proof 0))) `shouldThrow` anyException
    lookupSkill registry (GroupId 900) "double-value" `shouldReturn` Nothing

setup :: DbPool -> IO (SkillRegistry, ToolContext)
setup pool = setupAt pool 900

setupAt :: DbPool -> Integer -> IO (SkillRegistry, ToolContext)
setupAt pool group = do
  (turn, message, actor) <- seed pool (fromInteger group) 1
  withDb pool (claimFrontend turn) `shouldReturn` True
  output <- newTurnOutputContext turn
  registry <- newSkillRegistry
  let context = mkToolContext (TurnIdentity (GroupId (fromInteger group)) message (UserId 1) (UserId 3) actor Nothing (Just output)) (TurnCapabilities False False True noAdvertisedCaps False Map.empty Nothing False)
  loaded <- load registry context "skill-authoring"
  pure (registry, loaded)

load :: SkillRegistry -> ToolContext -> Text -> IO ToolContext
load registry context name = case skillToolsFor registry context (const (pure (Right Nothing))) (bindWorkflowContracts javaScriptRuntimeVersion (toolSkillLoads context) []) of
  [runner] -> do
    (result, control) <- runEff (runToolControl (runner.toolRun (object ["name" .= name])))
    result `shouldSatisfy` isRight
    pure (withToolSkillLoads (controlSkillLoads control) context)
  _ -> fail "missing loader"

call :: DbPool -> SkillRegistry -> ToolContext -> Text -> Value -> IO (Either Text Value)
call pool registry context name args = case find ((== name) . (.toolName)) (skillAuthoringToolsWithDatabase registry context (Right [])) of
  Nothing -> fail "missing authoring tool"
  Just runner -> withDb pool (runner.toolRun args)

validate :: DbPool -> SkillRegistry -> ToolContext -> IO Value
validate pool registry context = do
  Right result <- call pool registry context "skill_validate" (reference 1)
  field "report" result `shouldBe` object ["passed" .= True, "failures" .= ([] :: [Text])]
  pure (field "validation_id" result)

reference :: Integer -> Value
reference revision = object ["name" .= ("double-value" :: Text), "revision" .= revision]

saveArgs :: DraftContent -> Integer -> Value
saveArgs content expected = object ["draft" .= content, "expected_revision" .= expected]

publishArgs :: Value -> Integer -> Value
publishArgs proof expected = object ["name" .= ("double-value" :: Text), "revision" .= (1 :: Int), "validation_id" .= proof, "expected_revision" .= expected]

field :: Key -> Value -> Value
field key (Object fields) = fromMaybe Null (KM.lookup key fields)
field _ _ = Null

draft :: DraftContent
draft = DraftContent "double-value" "double an integer" "run double-value/run with value" (SkillPackage [] (Map.singleton "run" (Workflow "double" "return {value:args.value*2};" contract contract []))) [Fixture "run" (object ["value" .= (3 :: Int)]) [] (object ["value" .= (6 :: Int)])]

contract :: Value
contract = object ["type" .= ("object" :: Text), "properties" .= object ["value" .= object ["type" .= ("integer" :: Text)]], "required" .= (["value"] :: [Text]), "additionalProperties" .= False]
