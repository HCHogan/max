module Max.Plan.PromptSpec (spec) where

import Data.Foldable (traverse_)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Max.Effects.Tools (SchemaVersion (..), ToolRef (..))
import Max.Effects.Tools qualified as Tools
import Max.Plan.Parse (parseExpr, parsePlan, parseSchema)
import Max.Plan.Prompt
import Max.Plan.Schema (PlanSchema (..), SchemaField (..), renderSchema)
import Max.Plan.Types
import Max.Plan.Validate
import Test.Hspec

field :: Text -> PlanSchema -> SchemaField
field name schema = SchemaField {sfName = name, sfSchema = schema, sfRequired = True}

searchEntry :: CatalogEntry
searchEntry =
  CatalogEntry
    { ceRef = ToolRef "search_web",
      ceSchemaVersion = SchemaVersion 3,
      ceInput = SchemaObject [field "query" SchemaText, SchemaField {sfName = "limit", sfSchema = SchemaInt, sfRequired = False}],
      ceResult = SchemaArray (SchemaObject [field "title" SchemaText]),
      ceEffects = Set.singleton (EffRead (ExternalScope "web")),
      ceAuthorities = Set.empty
    }

replyEntry :: CatalogEntry
replyEntry =
  CatalogEntry
    { ceRef = ToolRef "reply",
      ceSchemaVersion = SchemaVersion 1,
      ceInput = SchemaObject [field "text" SchemaText],
      ceResult = SchemaObject [],
      ceEffects = Set.singleton (EffSend AudienceConversation),
      ceAuthorities = Set.singleton Tools.CurrentConversation
    }

budget :: EffectBudget
budget =
  EffectBudget
    { ebEffects = Set.fromList [EffRead (ExternalScope "web"), EffSend AudienceConversation],
      ebMaxCalls = 2,
      ebMaxSends = 1,
      ebMaxFanout = 8,
      ebMaxTokens = 4000,
      ebMaxWallClockMs = 20000
    }

goal :: Goal
goal =
  Goal
    { goalObjective = "回答群里那个问题",
      goalExpected = SchemaText,
      goalAcceptance = [],
      goalBudget = budget,
      goalAuthority = Set.singleton Tools.CurrentConversation,
      goalResources = [],
      goalInputs = [],
      goalDeps = noDependencies,
      goalEvidence = [],
      goalAttempt = 0
    }

env :: ValidationEnv
env =
  ValidationEnv
    { venCatalog = Map.fromList [(entry.ceRef, entry) | entry <- [searchEntry, replyEntry]],
      venVerifiers =
        Map.singleton
          "answers-question"
          VerifierEntry {veName = "answers-question", veVersion = 1, veAccepts = SchemaText},
      venHandles = Map.empty,
      venAdmittedVerifiers = Set.singleton "answers-question",
      venGoal = goal,
      venBindings = Map.empty,
      venCostCeiling = 100000
    }

-- | A fork child's goal: read-only, no authority, and narrower than the goal
-- above it in every dimension the kernel checks.
subgoal :: Goal
subgoal =
  goal
    { goalObjective = "查甲的资料",
      goalExpected = SchemaObject [field "name" SchemaText, field "bio" SchemaText],
      goalBudget =
        budget
          { ebEffects = Set.singleton (EffRead (ExternalScope "web")),
            ebMaxCalls = 1,
            ebMaxSends = 0
          },
      goalAuthority = Set.empty
    }

handle :: Text -> Bool -> ValueRef
handle name retained =
  ValueRef
    { vrHandle = name,
      vrSchema = SchemaText,
      vrScope = CurrentConversation,
      vrDigest = "sha256:0",
      vrLength = 12,
      vrRetained = retained
    }

spec :: Spec
spec = do
  -- The guide is a static string, so nothing but a test keeps it honest.
  describe "the guide only demonstrates syntax the parser accepts" $ do
    it "parses every complete plan it shows" $
      traverse_ (accepts parsePlan) guidePlans

    it "parses every expression it shows" $
      traverse_ (accepts parseExpr) guideExpressions

    it "parses every type it shows" $
      traverse_ (accepts parseSchema) guideTypes

    it "parses every condition it shows, in the position it shows them in" $
      traverse_
        (\fragment -> accepts parsePlan ("if " <> fragment <> " { done \"a\" } else { done \"b\" }"))
        guidePredicates

    it "is still right that a bare value is not a condition" $
      -- The guide says `if hits { … }` is wrong.  If the parser ever started
      -- accepting it, the guide would be teaching a superstition.
      parsePlan "let hits = search_web@3({ query: \"q\" })\nif hits { done \"y\" } else { done \"n\" }"
        `shouldSatisfy` isLeft

  describe "the guide's worked examples are admissible, not merely parseable" $
    it "admits every plan it shows" $
      -- Narrowing, the admitted verifier and declassification all have to line
      -- up for the hole example; it is the one most likely to rot silently.
      traverse_ isAdmissible guidePlans

  describe "types round-trip between what is shown and what is accepted" $
    it "reparses every schema the catalog section renders" $
      sequence_
        [ parseSchema (renderSchema schema) `shouldBe` Right schema
          | entry <- Map.elems env.venCatalog,
            schema <- [entry.ceInput, entry.ceResult]
        ]

  describe "the catalog section" $ do
    it "lists each tool with the version the plan must name" $ do
      let rendered = catalogSection env
      rendered `shouldSatisfy` T.isInfixOf "search_web@3"
      rendered `shouldSatisfy` T.isInfixOf "reply@1"

    it "shows an optional parameter as optional rather than as required" $
      catalogSection env `shouldSatisfy` T.isInfixOf "{query: text, limit?: int}"

    it "says so plainly when there are no tools at all" $
      catalogSection env {venCatalog = Map.empty}
        `shouldSatisfy` T.isInfixOf "没有工具可用"

  describe "the goal section" $ do
    it "states the ceilings the kernel will actually check" $ do
      let rendered = goalSection env
      rendered `shouldSatisfy` T.isInfixOf "调用 ≤ 2 次，其中发送 ≤ 1 次"
      rendered `shouldSatisfy` T.isInfixOf "send(conversation)"
      rendered `shouldSatisfy` T.isInfixOf "read(external \"web\")"

    it "offers a retained handle" $
      goalSection env {venHandles = Map.singleton "t#12:r0" (handle "t#12:r0" True)}
        `shouldSatisfy` T.isInfixOf "t#12:r0 : text"

    it "hides a released one, because naming it would advertise a rejection" $
      goalSection env {venHandles = Map.singleton "t#12:r0" (handle "t#12:r0" False)}
        `shouldSatisfy` not . T.isInfixOf "t#12:r0"

    it "tells a retry why the last attempt failed" $ do
      let retried =
            goal
              { goalAttempt = 1,
                goalEvidence =
                  [ Evidence
                      { evSource = FromResultSchema,
                        evDetail = "expected text, got [text]",
                        evScope = CurrentConversation
                      }
                  ]
              }
          rendered = goalSection env {venGoal = retried}
      rendered `shouldSatisfy` T.isInfixOf "这是第 2 次尝试"
      rendered `shouldSatisfy` T.isInfixOf "expected text, got [text]"

    it "admits when acceptance is only a shape check" $
      goalSection env {venAdmittedVerifiers = Set.empty}
        `shouldSatisfy` T.isInfixOf "无验收器"

  describe "assembly" $ do
    it "puts the constant guide first, so a prefix cache survives a new goal" $
      frontPrompt env `shouldSatisfy` T.isPrefixOf dialectGuide

    it "starts a child with the same bytes, so both roles share one cache" $
      childPrompt (childEnv env subgoal) `shouldSatisfy` T.isPrefixOf dialectGuide

    it "briefs the child and does not brief the front model" $ do
      childPrompt (childEnv env subgoal) `shouldSatisfy` T.isInfixOf childBriefing
      frontPrompt env `shouldSatisfy` not . T.isInfixOf childBriefing

  describe "what a child can see" $ do
    it "keeps the goal it was dispatched for" $
      (childEnv env subgoal).venGoal.goalObjective `shouldBe` "查甲的资料"

    it "hands over the named inputs and nothing else in scope" $ do
      -- The parent holds two names; the subgoal asked for one.  The other is
      -- not withheld as a policy — it was never resolved to a value for this
      -- child, so naming it would be naming nothing.
      let parent = env {venBindings = Map.fromList [(Binder "框架", SchemaText), (Binder "别的", SchemaInt)]}
          seen = (childEnv parent subgoal {goalInputs = [Binder "框架"]}).venBindings
      Map.keys seen `shouldBe` [Binder "框架"]
      goalSection (childEnv parent subgoal {goalInputs = [Binder "框架"]})
        `shouldSatisfy` T.isInfixOf "框架 : text"

    it "hands over the named handles and nothing else in scope" $ do
      let parent =
            env
              { venHandles =
                  Map.fromList [("t#12:r0", handle "t#12:r0" True), ("t#12:r1", handle "t#12:r1" True)]
              }
          seen = (childEnv parent subgoal {goalResources = ["t#12:r0"]}).venHandles
      Map.keys seen `shouldBe` ["t#12:r0"]

    it "hides a tool its budget could never pay for" $ do
      -- reply@1 sends, and this subgoal may only read.  The kernel would
      -- reject the call anyway; showing it in the catalog would be offering
      -- a guaranteed rejection as an option.
      let rendered = catalogSection (childEnv env subgoal)
      rendered `shouldSatisfy` T.isInfixOf "search_web@3"
      rendered `shouldSatisfy` not . T.isInfixOf "reply@1"

    it "hides a tool it lacks the authority for, separately from the effect" $ do
      let gated = replyEntry {ceRef = ToolRef "gated", ceEffects = Set.empty}
          parent = env {venCatalog = Map.insert (ToolRef "gated") gated env.venCatalog}
      catalogSection (childEnv parent subgoal)
        `shouldSatisfy` not . T.isInfixOf "gated@1"

    it "narrows and never widens, so a child of a child cannot regain anything" $ do
      -- Idempotence is the property that makes depth uninteresting: applying
      -- the projection twice with the same goal is applying it once.
      let parent = env {venBindings = Map.singleton (Binder "框架") SchemaText}
          once = childEnv parent subgoal
      childEnv once subgoal `shouldBe` once

-- | Report what the parser actually said.  When the guide rots, the failure
-- has to name the fragment and the reason, or the test is just a red light.
accepts :: Show e => (Text -> Either e a) -> Text -> Expectation
accepts parser fragment = case parser fragment of
  Left failure -> expectationFailure (T.unpack fragment <> " — " <> show failure)
  Right _ -> pure ()

isAdmissible :: Text -> Expectation
isAdmissible source = case parsePlan source of
  Left failure -> expectationFailure (show failure)
  Right plan -> case validatePlan env "turn:1:0" plan of
    Left rejection -> expectationFailure (T.unpack (rejectionText rejection))
    Right _ -> pure ()

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)
