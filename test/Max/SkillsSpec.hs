module Max.SkillsSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Effectful (runEff)
import Max.Command.Version (buildIdentityLines)
import Max.Effects.ToolControl (runToolControl)
import Max.Effects.Tools (Tool (..))
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..), noAdvertisedCaps)
import Max.Skills (Skill (..), lookupSkill, newSkillRegistry, skillsForGroup)
import Max.Tool.Bundles (SkillLoad (..), toolVisible)
import Max.Tool.Control (controlSkillLoads)
import Max.ToolContext
import Max.Tools.Skills (skillToolsFor)
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec

-- The DB side needs Postgres and lives with the other integration
-- specs; what a fresh registry ships with — the builtins baked from
-- @skills/@ — is testable right here, and catches a malformed
-- skill file at CI time instead of as a silently missing skill.
spec :: Spec
spec = describe "Max.Skills builtins" $ do
  it "loads explicit dependencies once and keeps independent execution state" $ do
    registry <- newSkillRegistry
    let executionContext =
          mkToolContext
            (TurnIdentity (GroupId 7777) (CanonicalMessageId 1) (UserId 2) (UserId 3) (PrincipalId 2) Nothing Nothing)
            (TurnCapabilities False False True noAdvertisedCaps False Map.empty Nothing False)
        load current = case skillToolsFor registry current (const (pure (Right Nothing))) of
          [runner] -> runEff (runToolControl (runner.toolRun (object ["name" .= ("office" :: T.Text)])))
          _ -> fail "missing skill loader"
    (_, first) <- load executionContext
    let receipts = controlSkillLoads first
        loaded = withToolSkillLoads receipts executionContext
    map (.slName) receipts `shouldBe` ["sandbox", "office"]
    toolVisible (toolSkillLoads loaded) "sandbox_exec" `shouldBe` True
    toolVisible (toolSkillLoads loaded) "browser_navigate" `shouldBe` False
    toolVisible (toolSkillLoads executionContext) "sandbox_exec" `shouldBe` False
    (_, again) <- load loaded
    controlSkillLoads again `shouldBe` []

  it "ships the manuals and the single self-knowledge entry point" $ do
    reg <- newSkillRegistry
    skills <- skillsForGroup reg (GroupId 7777)
    map (.skillName) skills
      `shouldContain` ["office", "sandbox", "self-knowledge", "web"]
    -- Doc-mirror skills are retired: behaviour/architecture/design are
    -- read from the source snapshot via inspect_source, navigated by
    -- self-knowledge.
    map (.skillName) skills `shouldNotContain` ["self-features"]
    map (.skillName) skills `shouldNotContain` ["self-architecture"]

  it "gives builtins negative ids, a one-line description, and a body" $ do
    reg <- newSkillRegistry
    Just sk <- lookupSkill reg (GroupId 7777) "self-knowledge"
    sk.skillId `shouldSatisfy` (< 0)
    sk.skillGroup `shouldBe` Nothing
    sk.skillDescription `shouldNotSatisfy` T.null
    sk.skillDescription `shouldNotSatisfy` T.any (== '\n')
    sk.skillBody `shouldSatisfy` T.isInfixOf "NapCat"

  -- self-knowledge is a navigation map plus the two runtime-generated
  -- splices (!help, !version's build identity); everything else must be
  -- a pointer into the source snapshot, not doc content that would drift.
  it "splices live !help into the navigation map" $ do
    reg <- newSkillRegistry
    Just sk <- lookupSkill reg (GroupId 7777) "self-knowledge"
    sk.skillBody `shouldNotSatisfy` T.isInfixOf "{{commands}}"
    sk.skillBody `shouldSatisfy` T.isInfixOf "!feedback"
    sk.skillBody `shouldSatisfy` T.isInfixOf "inspect_source"
    sk.skillBody `shouldSatisfy` T.isInfixOf "docs/adr/"
    sk.skillBody `shouldSatisfy` T.isInfixOf "migrations/000_baseline.sql"
    T.length sk.skillBody `shouldSatisfy` (< 16384)

  -- Only the build-identity lines get spliced: they're fixed for the
  -- process, whereas uptime and the per-group tool/skill counts would
  -- be a boot-time snapshot the model quotes as current days later.
  it "splices this build's identity, not live status" $ do
    reg <- newSkillRegistry
    Just sk <- lookupSkill reg (GroupId 7777) "self-knowledge"
    sk.skillBody `shouldNotSatisfy` T.isInfixOf "{{version}}"
    -- Lines 1 and 3 are pure build facts, so they must appear verbatim;
    -- line 2 carries the host's distro name, which the spec can't know.
    case buildIdentityLines "(distro)" of
      [verLine, _osLine, ghcLine] -> do
        verLine `shouldSatisfy` T.isPrefixOf "🦈 max v"
        sk.skillBody `shouldSatisfy` T.isInfixOf verLine
        sk.skillBody `shouldSatisfy` T.isInfixOf ghcLine
      ls -> expectationFailure ("unexpected build identity: " <> show ls)
    sk.skillBody `shouldNotSatisfy` T.isInfixOf "⏱️ up"
    sk.skillBody `shouldNotSatisfy` T.isInfixOf "tools · "
