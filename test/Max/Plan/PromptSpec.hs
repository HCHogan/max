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

  describe "assembly" $
    it "puts the constant guide first, so a prefix cache survives a new goal" $
      elaborationPrompt env `shouldSatisfy` T.isPrefixOf dialectGuide

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
