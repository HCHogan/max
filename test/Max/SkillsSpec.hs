module Max.SkillsSpec (spec) where

import Data.Text qualified as T
import Max.Skills (Skill (..), lookupSkill, newSkillRegistry, skillsForGroup)
import OneBot.Types (GroupId (..))
import Test.Hspec

-- The DB side needs Postgres and lives with the other integration
-- specs; what a fresh registry ships with — the builtins baked from
-- @skills/@ — is testable right here, and catches a malformed
-- skill file at CI time instead of as a silently missing skill.
spec :: Spec
spec = describe "Max.Skills builtins" $ do
  it "ships the manuals, merged self-knowledge, and docs-backed architecture" $ do
    reg <- newSkillRegistry
    skills <- skillsForGroup reg (GroupId 7777)
    map (.skillName) skills
      `shouldContain` ["office", "sandbox", "self-architecture", "self-knowledge", "web"]
    map (.skillName) skills `shouldNotContain` ["self-features"]

  it "gives builtins negative ids, a one-line description, and a body" $ do
    reg <- newSkillRegistry
    Just sk <- lookupSkill reg (GroupId 7777) "self-knowledge"
    sk.skillId `shouldSatisfy` (< 0)
    sk.skillGroup `shouldBe` Nothing
    sk.skillDescription `shouldNotSatisfy` T.null
    sk.skillDescription `shouldNotSatisfy` T.any (== '\n')
    sk.skillBody `shouldSatisfy` T.isInfixOf "NapCat"

  -- Behaviour and commands are single-sourced from docs/features.md and live
  -- !help respectively; both placeholders must be gone at registry init.
  it "splices the behaviour reference and live !help text" $ do
    reg <- newSkillRegistry
    Just sk <- lookupSkill reg (GroupId 7777) "self-knowledge"
    sk.skillBody `shouldNotSatisfy` T.isInfixOf "{{commands}}"
    sk.skillBody `shouldNotSatisfy` T.isInfixOf "{{features}}"
    sk.skillBody `shouldSatisfy` T.isInfixOf "!feedback"
    sk.skillBody `shouldSatisfy` T.isInfixOf "P1/P2/P3/P4"
    T.length sk.skillBody `shouldSatisfy` (< 49152)
