module Max.Skill.AuthoringSpec (spec) where

import Control.Monad ((>=>))
import Data.Aeson
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import ExecutionFixture
import Max.Effects.Tools
import Max.Skill.Authoring
import Max.Skill.Package
import Max.Skill.Validation
import Max.Tool.Catalog (catalogTools)
import Test.Hspec

spec :: Spec
spec = describe "isolated skill fixture validation" $ do
  it "runs real JS against fixture data using the shared host executor" $ do
    validateFixtures catalog draft `shouldReturn` ValidationReport []
  it "validates phase and agent fixtures without any live child or database runner" $ do
    let child = object ["objective" .= ("bounded research" :: Text), "profile" .= ("research" :: Text)]
        result = object ["findings" .= ("verified" :: Text)]
        workflow = Workflow "delegate" "max.phase('research'); return agent({objective:'bounded research',profile:'research'});" contract (object ["type" .= ("object" :: Text), "additionalProperties" .= True]) ["task_start", "task_progress"]
        content = draft.dvContent {dcPackage = SkillPackage [] (Map.singleton "run" workflow), dcFixtures = [Fixture "run" args [FixtureCall "phase" (String "research") (Right Null), FixtureCall "agent" child (Right result)] result]}
        available = [entry {ctDefinition = entry.ctDefinition {tdRef = ToolRef name}} | entry <- catalog, name <- ["task_start", "task_progress"]]
    validateFixtures available (DraftVersion 1 content) `shouldReturn` ValidationReport []
    validateDraft content {dcPackage = SkillPackage [] (Map.singleton "run" workflow {wfTools = []})} `shouldSatisfy` isLeft
  it "records unexpected calls even if the guest catches the error" $ do
    let bad = change "try { tools.echo({value:9}); } catch (_) {} return args;" draft
    report <- validateFixtures catalog bad
    report `shouldSatisfy` (not . validationPassed)
  it "rejects unused calls, wrong outputs and invalid tool arguments" $ do
    mapM_
      (validateFixtures catalog >=> (`shouldSatisfy` (not . validationPassed)))
      [ change "return args;" draft,
        change "tools.echo(args); return {value:9};" draft,
        draft {dvContent = draft.dvContent {dcFixtures = [fixture {fxCalls = [FixtureCall "echo" (object []) (Right args)]}]}}
      ]
  it "executes simulated failures without admitting application runners" $ do
    let failed =
          (change "try { tools.echo(args); } catch (e) { return {value: e.name === 'ToolError' ? 3 : 0}; }" draft)
            { dvContent = (change "try { tools.echo(args); } catch (e) { return {value: e.name === 'ToolError' ? 3 : 0}; }" draft).dvContent {dcFixtures = [fixture {fxCalls = [FixtureCall "echo" args (Left "offline")]}]}
            }
    validateFixtures catalog failed `shouldReturn` ValidationReport []
  it "bounds infinite loops and rejects malformed JavaScript" $ do
    mapM_ (\source -> validateFixtures catalog (change source draft) >>= (`shouldSatisfy` (not . validationPassed))) ["while (true) {}", "return {;"]
  it "requires fixtures for every entry and rejects NUL in JSON keys" $ do
    validateDraft draft.dvContent {dcFixtures = []} `shouldSatisfy` isLeft
    validateDraft draft.dvContent {dcFixtures = [fixture {fxArgs = object ["bad\0key" .= True]}]} `shouldSatisfy` isLeft
  it "rejects unknown fields instead of silently weakening fixture expectations" $ do
    fromJSON @Fixture (object ["entry" .= ("run" :: Text), "args" .= args, "calls" .= ([] :: [Value]), "expected" .= args, "typo" .= True]) `shouldSatisfy` \case Error _ -> True; _ -> False
  it "uses deterministic batch submission order for read-only fixture tools" $ do
    let source = "const r = max.batch([{tool:'echo',args},{tool:'echo',args:{value:4}}]); return max.value(r[1]);"
        d = change source draft
        f = fixture {fxCalls = [FixtureCall "echo" args (Right args), FixtureCall "echo" (object ["value" .= (4 :: Int)]) (Right (object ["value" .= (4 :: Int)]))], fxExpected = object ["value" .= (4 :: Int)]}
    validateFixtures catalog d {dvContent = d.dvContent {dcFixtures = [f]}} `shouldReturn` ValidationReport []
  it "classifies simulated write failures by the real effect declaration" $ do
    let writes = [t {ctDefinition = t.ctDefinition {tdEffects = Set.singleton (EffectWrite "test"), tdRetryClass = RetryUnsafe, tdParallelism = SequentialOnly, tdFailuresPrecedeEffects = False}} | t <- catalog]
        d = change "try { tools.echo(args); } catch (e) { return {value: e.outcome === 'outcome-unknown' ? 3 : 0}; }" draft
    validateFixtures writes d {dvContent = d.dvContent {dcFixtures = [fixture {fxCalls = [FixtureCall "echo" args (Left "lost reply")]}]}} `shouldReturn` ValidationReport []

catalog :: [CatalogTool]
catalog = either (error . show) (catalogTools . registryCatalog) (buildToolRegistry [echoDefinition] [echoTool])

args :: Value
args = object ["value" .= (3 :: Int)]

contract :: Value
contract = object ["type" .= ("object" :: Text), "properties" .= object ["value" .= object ["type" .= ("integer" :: Text)]], "required" .= (["value"] :: [Text]), "additionalProperties" .= False]

fixture :: Fixture
fixture = Fixture "run" args [FixtureCall "echo" args (Right args)] args

draft :: DraftVersion
draft = DraftVersion 1 (DraftContent "demo" "description" "instructions" (SkillPackage [] (Map.singleton "run" (Workflow "echo" "return tools.echo(args);" contract contract ["echo"]))) [fixture])

change :: Text -> DraftVersion -> DraftVersion
change source d = d {dvContent = d.dvContent {dcPackage = d.dvContent.dcPackage {spWorkflows = Map.map (\w -> w {wfSource = source}) d.dvContent.dcPackage.spWorkflows}}}
