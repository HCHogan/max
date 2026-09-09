module Max.SkillWorkflowSpec (spec) where

import Control.Concurrent.Async (concurrently)
import Control.Exception (SomeException, try)
import Data.Aeson (Value, object, (.=))
import Data.Either (isLeft, isRight)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Only (..))
import Effectful (runEff)
import Effectful.PostgreSQL (query)
import Helpers (truncateAll, withDb)
import Max.DB.Connection (DbPool)
import Max.DB.Transaction (withTransaction)
import Max.Effects.ToolControl (runToolControl)
import Max.Effects.Tools (Tool (..))
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..), noAdvertisedCaps)
import Max.Skill.Package
import Max.Skills
import Max.Tool.Bundles (SkillLoad (..))
import Max.Tool.Control (LoopControl, controlSkillLoads)
import Max.ToolContext
import Max.Tools.Skills (skillToolsFor)
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec hiding (context)

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "versioned skill persistence and loading" $ do
  it "round trips packages and appends old content without changing a loaded revision" $ do
    registry <- newSkillRegistry
    let contract = object ["type" .= ("object" :: Text), "additionalProperties" .= True]
        workflow = Workflow "compute" "return args;" contract contract []
        package = SkillPackage [] (Map.singleton "compute" workflow)
    Right first <- withDb pool (createSkill registry (new "saved" []) {nsPackage = package})
    (_, control) <- load registry context "saved"
    let pinned = controlSkillLoads control
    Right second <- withDb pool (updateSkillAtRevision registry first.skillId (Just 1) (\s -> s {skillBody = "second instructions", skillPackage = emptyPackage}))
    second.skillRevision `shouldBe` 2
    versions <- withDb pool $ query "SELECT revision,snapshot->>'body' FROM skill_versions WHERE skill_id=? ORDER BY revision" (Only first.skillId)
    versions `shouldBe` [(1 :: Int, "instructions" :: Text), (2, "second instructions")]
    (_, repeated) <- load registry (withToolSkillLoads pinned context) "saved"
    controlSkillLoads repeated `shouldBe` []
    map (.slInstructions) pinned `shouldSatisfy` any (T.isInfixOf "saved/compute")
    sources <- withDb pool $ query "SELECT snapshot->'package'->'workflows'->'compute'->>'source' FROM skill_versions WHERE skill_id=? AND revision=1" (Only first.skillId)
    sources `shouldBe` [Only ("return args;" :: Text)]
    restarted <- newSkillRegistry
    _ <- withDb pool (loadSkills restarted)
    lookupSkill restarted (GroupId 7777) "saved" `shouldReturn` Just second

  it "rejects concurrent stale writers across separate registry instances" $ do
    firstRegistry <- newSkillRegistry
    Right skill <- withDb pool (createSkill firstRegistry (new "race" []))
    secondRegistry <- newSkillRegistry
    _ <- withDb pool (loadSkills secondRegistry)
    let change registry body = withDb pool (updateSkillAtRevision registry skill.skillId (Just 1) (\s -> s {skillBody = body}))
    (a, b) <- concurrently (change firstRegistry "first") (change secondRegistry "second")
    length (filter isRight [a, b]) `shouldBe` 1
    length (filter (== Left "skill revision conflict") [a, b]) `shouldBe` 1
    rows <- withDb pool $ query "SELECT count(*) FROM skill_versions WHERE skill_id=?" (Only skill.skillId)
    rows `shouldBe` [Only (2 :: Int)]

  it "keeps the cache unchanged when mutation would publish before an outer commit" $ do
    registry <- newSkillRegistry
    Right skill <- withDb pool (createSkill registry (new "nested" []))
    result <- try @SomeException $ withDb pool (withTransaction (updateSkill registry skill.skillId (\s -> s {skillBody = "must not publish"})))
    result `shouldSatisfy` isLeft
    lookupSkill registry (GroupId 7777) "nested" `shouldReturn` Just skill

  it "loads a diamond dependency graph once in dependency order" $ do
    registry <- newSkillRegistry
    mapM_
      (\(name, dependencies) -> withDb pool (createSkill registry (new name dependencies)) >>= (`shouldSatisfy` isRight))
      [("shared", []), ("left", ["shared"]), ("right", ["shared"]), ("root", ["left", "right"])]
    (result, control) <- load registry context "root"
    result `shouldSatisfy` isRight
    map (.slName) (controlSkillLoads control) `shouldBe` ["shared", "left", "right", "root"]

  it "rejects cycles and missing dependencies without partial activation" $ do
    registry <- newSkillRegistry
    mapM_
      (\(name, dependencies) -> withDb pool (createSkill registry (new name dependencies)) >>= (`shouldSatisfy` isRight))
      [("cycle-a", ["cycle-b"]), ("cycle-b", ["cycle-a"]), ("missing", ["absent"])]
    mapM_
      ( \name -> do
          (result, control) <- load registry context name
          result `shouldSatisfy` isLeft
          controlSkillLoads control `shouldBe` []
      )
      ["cycle-a", "missing"]

  it "does not resolve dependencies from another group" $ do
    registry <- newSkillRegistry
    Right _ <- withDb pool (createSkill registry (new "private-dependency" []) {nsGroup = Just 8888})
    Right _ <- withDb pool (createSkill registry (new "group-work" ["private-dependency"]))
    (result, control) <- load registry context "group-work"
    result `shouldSatisfy` isLeft
    controlSkillLoads control `shouldBe` []

  it "rejects package names that cannot be addressed by skill/entry" $ do
    registry <- newSkillRegistry
    result <- withDb pool (createSkill registry (new "invalid/name" ["web"]))
    result `shouldSatisfy` isLeft

  it "rejects NUL rather than rewriting saved source or instruction content" $ do
    registry <- newSkillRegistry
    result <- withDb pool (createSkill registry (new "nul" []) {nsBody = "bad\0source"})
    result `shouldSatisfy` isLeft
    lookupSkill registry (GroupId 7777) "nul" `shouldReturn` Nothing

new :: Text -> [Text] -> NewSkill
new name dependencies = NewSkill name (Just 7777) "description" "instructions" True (Just 2) (SkillPackage dependencies Map.empty)

context :: ToolContext
context =
  mkToolContext
    (TurnIdentity (GroupId 7777) (CanonicalMessageId 1) (UserId 2) (UserId 3) (PrincipalId 2) Nothing Nothing)
    (TurnCapabilities False False True noAdvertisedCaps False Map.empty Nothing False)

load :: SkillRegistry -> ToolContext -> Text -> IO (Either Text Value, LoopControl)
load registry current name = case skillToolsFor registry current (const (pure (Right Nothing))) Right of
  [runner] -> runEff (runToolControl (runner.toolRun (object ["name" .= (name :: Text)])))
  _ -> fail "missing loader"
