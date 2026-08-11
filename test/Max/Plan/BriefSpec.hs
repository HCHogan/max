-- | What a fork child is told, held to what it must and must not contain.
--
-- These are prose assertions, which is unusual and deliberate: the brief is the
-- entire interface between a plan and the model doing one of its subgoals, and
-- every line in it is there because a real model did something without it. The
-- tests name which line and why, so deleting one costs a red build and a
-- sentence explaining why the measurement no longer applies.
module Max.Plan.BriefSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Max.Plan.Brief
import Max.Plan.Drive (Dispatchable (..))
import Max.Plan.Reconcile (Desired (..))
import Max.Plan.Schema (PlanSchema (..))
import Max.Plan.Types
import Test.Hspec

goalNamed :: Text -> Goal
goalNamed objective =
  Goal
    { goalObjective = objective,
      goalExpected = SchemaText,
      goalAcceptance = [],
      goalBudget = emptyBudget {ebMaxCalls = 3},
      goalAuthority = Set.empty,
      goalResources = [],
      goalInputs = [],
      goalDeps = noDependencies,
      goalEvidence = [],
      goalAttempt = 0
    }

briefFor :: Goal -> [(Binder, Value)] -> Text
briefFor goal inputs =
  subgoalBrief
    7
    Dispatchable
      { dpDesired =
          Desired {dsNode = NodeId "turn:1:0/k0", dsBinder = Binder "child", dsGoal = goal, dsHash = ""},
        dpInputs = inputs
      }

spec :: Spec
spec = describe "the subgoal brief" $ do
  it "states the objective, the result type, and the ceiling" $ do
    let brief = briefFor (goalNamed "查一下燕大教务处") []
    brief `shouldSatisfy` T.isInfixOf "查一下燕大教务处"
    brief `shouldSatisfy` T.isInfixOf "text"
    brief `shouldSatisfy` T.isInfixOf "3 次工具调用"

  it "says the child's own words go nowhere" $
    -- Without it a child narrates its answer and returns nothing, which the
    -- parent reads as a failed subgoal and abandons the plan over.
    briefFor (goalNamed "随便") [] `shouldSatisfy` T.isInfixOf "subgoal_return"

  it "says which language to answer in" $ do
    -- Measured: two of nine live children answered a Chinese objective in
    -- English.  The value goes straight into a plan whose result a group reads,
    -- so the language it comes back in is part of the answer's shape.
    briefFor (goalNamed "随便") [] `shouldSatisfy` T.isInfixOf "语言"

  describe "what it hands over" $ do
    it "shows the values the subgoal asked for" $ do
      let brief = briefFor (goalNamed "按上面给的语言找框架") [(Binder "语言", String "Haskell")]
      brief `shouldSatisfy` T.isInfixOf "语言 = Haskell"

    it "shows text unquoted and everything else as JSON" $ do
      let brief =
            briefFor
              (goalNamed "随便")
              [(Binder "条", object ["n" .= (1 :: Int)]), (Binder "话", String "直接是这句")]
      -- A child reading @话 = "直接是这句"@ with the quotes is being shown an
      -- encoding rather than a value.
      brief `shouldSatisfy` T.isInfixOf "话 = 直接是这句"
      brief `shouldSatisfy` T.isInfixOf "条 = {\"n\":1}"

    it "leaves the whole block out when it asked for nothing" $ do
      -- An empty heading reads like something went missing.
      briefFor (goalNamed "随便") [] `shouldSatisfy` (not . T.isInfixOf "上面算好交给你的东西")

  it "says nothing about the plan it belongs to beyond its number" $ do
    -- ADR 002's isolation rule is what makes a fork worth paying for: no
    -- siblings, no parent objective, no conversation.  A brief that leaked any
    -- of them would turn the fan-out into an accumulation of context.
    let brief = briefFor (goalNamed "查甲") []
    brief `shouldSatisfy` T.isInfixOf "计划 #7"
    brief `shouldSatisfy` T.isInfixOf "你看不到上面在做什么"
