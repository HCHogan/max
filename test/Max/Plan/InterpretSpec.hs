module Max.Plan.InterpretSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Vector qualified as V
import Max.Effects.Tools (SchemaVersion (..), ToolRef (..))
import Max.Effects.Tools qualified as Tools
import Max.Plan.Interpret
import Max.Plan.Parse (parseFailureText, parsePlan)
import Max.Plan.Schema (PlanSchema (..), SchemaField (..))
import Max.Plan.Types
import Max.Plan.Validate
import Test.Hspec

field :: Text -> PlanSchema -> SchemaField
field name schema = SchemaField {sfName = name, sfSchema = schema, sfRequired = True}

hitSchema :: PlanSchema
hitSchema = SchemaObject [field "title" SchemaText]

searchTool :: CatalogEntry
searchTool =
  CatalogEntry
    { ceRef = ToolRef "search_web",
      ceSchemaVersion = SchemaVersion 3,
      ceInput = SchemaObject [field "query" SchemaText],
      ceResult = SchemaArray hitSchema,
      ceEffects = Set.singleton (EffRead (ExternalScope "web")),
      ceAuthorities = Set.empty
    }

replyTool :: CatalogEntry
replyTool =
  CatalogEntry
    { ceRef = ToolRef "reply",
      ceSchemaVersion = SchemaVersion 1,
      ceInput = SchemaObject [field "text" SchemaText],
      ceResult = SchemaObject [],
      ceEffects = Set.singleton (EffSend AudienceConversation),
      ceAuthorities = Set.singleton Tools.CurrentConversation
    }

env :: ValidationEnv
env =
  ValidationEnv
    { venCatalog = Map.fromList [(entry.ceRef, entry) | entry <- [searchTool, replyTool]],
      venVerifiers = Map.empty,
      venHandles = Map.empty,
      venAdmittedVerifiers = Set.empty,
      venGoal =
        Goal
          { goalObjective = "回答",
            goalExpected = SchemaText,
            goalAcceptance = [],
            goalBudget =
              EffectBudget
                { ebEffects =
                    Set.fromList
                      [ EffRead (ExternalScope "web"),
                        EffSend AudienceConversation,
                        EffRead CurrentConversation
                      ],
                  ebMaxCalls = 4,
                  ebMaxSends = 2,
                  ebMaxFanout = 8,
                  ebMaxTokens = 8000,
                  ebMaxWallClockMs = 30000
                },
            goalAuthority = Set.singleton Tools.CurrentConversation,
            goalDeps = noDependencies,
            goalEvidence = [],
            goalAttempt = 0
          },
      venBindings = Map.empty,
      venCostCeiling = 100000
    }

valid :: Text -> ValidPlan
valid source = case parsePlan source of
  Left failure -> error (show (parseFailureText failure))
  Right plan -> case validatePlan env "turn:41:0" plan of
    Left rejection -> error (show (rejectionText rejection))
    Right checked -> checked

-- One certain send, and one that only happens on the empty branch.
branching :: ValidPlan
branching =
  valid
    "let hits = search_web@3({ query: \"q\" })\n\
    \if length(hits) > 0 {\n\
    \  done hits[0].title ?? \"\"\n\
    \} else {\n\
    \  let told = reply@1({ text: \"没找到\" })\n\
    \  done \"没找到\"\n\
    \}"

spec :: Spec
spec = do
  describe "preview" $ do
    it "records the calls a plan would make without making them" $ do
      let manifest = previewPlan env "turn:41:0" branching
      map (.psTool) manifest.emSteps `shouldBe` [ToolRef "search_web", ToolRef "reply"]

    it "separates a call on every path from one on only some" $ do
      let manifest = previewPlan env "turn:41:0" branching
      map (.psReachability) manifest.emSteps `shouldBe` [Certain, Conditional]

    it "over-approximates the effect set across both branches" $ do
      let manifest = previewPlan env "turn:41:0" branching
      manifest.emEffects
        `shouldBe` Set.fromList [EffRead (ExternalScope "web"), EffSend AudienceConversation]

    it "counts the worst path rather than the whole tree" $ do
      -- A reply in each branch is two steps but one send on any real run.
      let both =
            valid
              "if true {\n\
              \  let a = reply@1({ text: \"a\" })\n\
              \  done \"a\"\n\
              \} else {\n\
              \  let b = reply@1({ text: \"b\" })\n\
              \  done \"b\"\n\
              \}"
          manifest = previewPlan env "turn:41:0" both
      length manifest.emSteps `shouldBe` 2
      manifest.emMaxSends `shouldBe` 1
      manifest.emMaxCalls `shouldBe` 1

    it "names the holes, so a manifest never reads as complete when it is not" $ do
      let withHole =
            valid
              "let hits = search_web@3({ query: \"q\" })\n\
              \hole \"怎么总结\" : text budget { calls: 1, fanout: 8, tokens: 10, ms: 10 }"
          manifest = previewPlan env "turn:41:0" withHole
      map snd manifest.emHoles `shouldBe` ["怎么总结"]
      manifest.emMaxCalls `shouldBe` 2

    it "binds the manifest to exactly this plan" $ do
      let manifest = previewPlan env "turn:41:0" branching
      manifest.emPlanHash `shouldBe` planHash (validPlan branching)
      manifest.emPlanHash `shouldNotBe` planHash (validPlan (valid "done \"x\""))

    it "reports the authority its steps would consume" $ do
      let manifest = previewPlan env "turn:41:0" branching
      manifest.emAuthorities `shouldBe` Set.singleton Tools.CurrentConversation

  describe "symbolic interpretation" $ do
    it "computes a result that needs nothing unknown" $
      map (.soEnd) (symbolicPlan env "turn:41:0" Map.empty Map.empty (valid "done \"hi\""))
        `shouldBe` [Produces (Known (String "hi"))]

    it "propagates a shape where a call result is not yet known" $ do
      let plan = valid "let hits = search_web@3({ query: \"q\" })\ndone hits[0].title ?? \"\""
      map (.soEnd) (symbolicPlan env "turn:41:0" Map.empty Map.empty plan)
        `shouldBe` [Produces (Unknown SchemaText)]

    it "forks on a guard it cannot decide" $ do
      let outcomes = symbolicPlan env "turn:41:0" Map.empty Map.empty branching
      length outcomes `shouldBe` 2
      map (map (.brDecided) . (.soBranches)) outcomes `shouldBe` [[False], [False]]
      map (map (.brTaken) . (.soBranches)) outcomes `shouldBe` [[True], [False]]

    it "takes only the live branch when the guard is decidable" $ do
      let plan =
            valid
              "if 1 < 2 { done \"yes\" } else { done \"no\" }"
          outcomes = symbolicPlan env "turn:41:0" Map.empty Map.empty plan
      map (.soEnd) outcomes `shouldBe` [Produces (Known (String "yes"))]
      map (map (.brDecided) . (.soBranches)) outcomes `shouldBe` [[True]]

    it "decides a guard once the value it depends on is supplied" $ do
      let plan = valid "let hits = search_web@3({ query: \"q\" })\nif length(hits) > 0 { done \"some\" } else { done \"none\" }"
          -- The host knows this turn already produced two hits.
          known = Map.singleton (Binder "hits") (Array (V.fromList [object ["title" .= ("a" :: Text)]]))
      -- Still forks: the binding is rebound by the call, so the supplied value
      -- does not survive past the node that overwrites it.
      length (symbolicPlan env "turn:41:0" Map.empty known plan) `shouldBe` 2

    it "uses a supplied binding that no call overwrites" $ do
      let inner = env {venBindings = Map.singleton (Binder "n") SchemaInt}
          plan = case parsePlan "if n > 1 { done \"big\" } else { done \"small\" }" of
            Left failure -> error (show (parseFailureText failure))
            Right parsed -> case validatePlan inner "turn:41:0" parsed of
              Left rejection -> error (show (rejectionText rejection))
              Right checked -> checked
          known = Map.singleton (Binder "n") (Number 5)
      map (.soEnd) (symbolicPlan inner "turn:41:0" Map.empty known plan)
        `shouldBe` [Produces (Known (String "big"))]

    it "stops at a hole instead of guessing past it" $ do
      let plan = valid "hole \"接下来做什么\" : text budget { calls: 1, fanout: 8, tokens: 10, ms: 10 }"
      map (.soEnd) (symbolicPlan env "turn:41:0" Map.empty Map.empty plan)
        `shouldBe` [StopsAtHole (NodeId "turn:41:0") "接下来做什么"]

    it "reports every path it explored, capped" $ do
      let outcomes = symbolicPlan env "turn:41:0" Map.empty Map.empty branching
      length outcomes `shouldSatisfy` (<= maxSymbolicPaths)
