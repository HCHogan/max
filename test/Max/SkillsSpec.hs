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
  it "ships self-knowledge plus the two docs-backed skills" $ do
    reg <- newSkillRegistry
    skills <- skillsForGroup reg (GroupId 7777)
    map (.skillName) skills
      `shouldContain` ["self-architecture", "self-features", "self-knowledge"]

  it "gives builtins negative ids, a one-line description, and a body" $ do
    reg <- newSkillRegistry
    Just sk <- lookupSkill reg (GroupId 7777) "self-knowledge"
    sk.skillId `shouldSatisfy` (< 0)
    sk.skillGroup `shouldBe` Nothing
    sk.skillDescription `shouldNotSatisfy` T.null
    sk.skillDescription `shouldNotSatisfy` T.any (== '\n')
    sk.skillBody `shouldSatisfy` T.isInfixOf "NapCat"

  -- The command section is the live !help text, spliced at registry
  -- init — the placeholder must be gone and a real verb present.
  it "splices {{commands}} with the !help text" $ do
    reg <- newSkillRegistry
    Just sk <- lookupSkill reg (GroupId 7777) "self-knowledge"
    sk.skillBody `shouldNotSatisfy` T.isInfixOf "{{commands}}"
    sk.skillBody `shouldSatisfy` T.isInfixOf "!feedback"
