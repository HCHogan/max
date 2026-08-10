module Max.Plan.TypesSpec (spec) where

import Data.Aeson (Result (..), decode, encode, fromJSON, object, (.=))
import Data.ByteString.Char8 qualified as BS8
import Data.Set qualified as Set
import Data.Text (Text)
import Max.Effects.Tools (SchemaVersion (..), ToolRef (..))
import Max.Effects.Tools qualified as Tools
import Max.Plan.Schema (PlanSchema (..))
import Max.Plan.Types
import Test.Hspec

goal :: Goal
goal =
  Goal
    { goalObjective = "总结搜索结果",
      goalExpected = SchemaText,
      goalAcceptance = [VerifierRef {verName = "answers-question", verVersion = 1}],
      goalBudget =
        EffectBudget
          { ebEffects = Set.fromList [EffRead CurrentConversation, EffSend AudienceConversation],
            ebMaxCalls = 4,
            ebMaxSends = 1,
            ebMaxFanout = 64,
            ebMaxTokens = 8000,
            ebMaxWallClockMs = 30000
          },
      goalAuthority = Set.singleton Tools.CurrentConversation,
      goalDeclassify = Taint (Set.singleton TaintExternal),
      goalDeps = observeDependency DepToolCatalog "cafe0000" noDependencies,
      goalEvidence = [],
      goalAttempt = 0
    }

-- One plan exercising every node kind, both guard branches, and a hole.
plan :: Plan
plan =
  Call
    CallNode
      { cnBind = Binder "hits",
        cnTool = ToolRef "search_web",
        cnSchemaVersion = SchemaVersion 3,
        cnInput = EObject [("query", ELit (LitText "prime agent"))]
      }
    ( Guard
        (PCompare OpGt (ELength (EVar (Binder "hits"))) (ELit (LitInt 0)))
        (Done (EField (EIndex (EVar (Binder "hits")) 0) "title"))
        (Hole goal)
    )

roundTrip :: Plan -> Maybe Plan
roundTrip = decode . encode

spec :: Spec
spec = do
  describe "codecs" $ do
    it "round-trips a plan through JSON unchanged" $
      roundTrip plan `shouldBe` Just plan

    it "round-trips every expression form" $ do
      let forms =
            [ ELit LitNull,
              ELit (LitNumber 1.5),
              EHandle "t#3:r2",
              EArray [ELit (LitBool True)],
              EConcat [ELit (LitText "a"), EVar (Binder "b")],
              ETake 3 (EVar (Binder "xs")),
              EMap (Binder "x") (EVar (Binder "xs")) (EField (EVar (Binder "x")) "id"),
              EFilter (Binder "x") (EVar (Binder "xs")) (PIsNull (EVar (Binder "x"))),
              EIf (PBool True) (ELit (LitInt 1)) (ELit (LitInt 2)),
              ECoalesce (EVar (Binder "a")) (ELit (LitText ""))
            ]
      map (decode . encode) forms `shouldBe` map Just forms

    it "round-trips every predicate form" $ do
      let forms =
            [ PNot (PBool False),
              PAnd [PBool True, PBool False],
              POr [],
              PCompare OpContains (EVar (Binder "s")) (ELit (LitText "x")),
              PAll (Binder "x") (EVar (Binder "xs")) (PBool True),
              PAny (Binder "x") (EVar (Binder "xs")) (PBool True)
            ]
      map (decode . encode) forms `shouldBe` map Just forms

    it "rejects an unknown node tag instead of skipping the node" $
      (decode "{\"t\":\"exec\",\"cmd\":\"rm -rf /\"}" :: Maybe Plan) `shouldBe` Nothing

    it "round-trips a document and refuses a version it does not know" $ do
      let document = PlanDocument {pdRoot = "turn:41:0", pdPlan = plan}
      decode (encode document) `shouldBe` Just document
      let wrong = object ["v" .= (99 :: Int), "root" .= ("turn:41:0" :: Text), "plan" .= plan]
      case fromJSON wrong :: Result PlanDocument of
        Error _ -> pure ()
        Success _ -> expectationFailure "a future IR version decoded as if it were this one"

  describe "canonical encoding" $ do
    it "sorts object keys, so the bytes do not depend on aeson's key order" $
      BS8.take 13 (canonicalBytes goal) `shouldBe` "{\"acceptance\""

    it "gives identical bytes to a plan and its round-tripped copy" $
      fmap canonicalBytes (roundTrip plan) `shouldBe` Just (canonicalBytes plan)

    it "changes the hash when any literal changes" $ do
      let other = Call CallNode {cnBind = Binder "hits", cnTool = ToolRef "search_web", cnSchemaVersion = SchemaVersion 3, cnInput = EObject [("query", ELit (LitText "prime agents"))]} (Done (ELit LitNull))
      planHash plan `shouldNotBe` planHash other

    it "keeps the hash stable across encode and decode" $
      fmap planHash (roundTrip plan) `shouldBe` Just (planHash plan)

  describe "derived node ids" $ do
    it "walks the plan in pre-order, naming each node by its path" $
      map ((.unNodeId) . fst) (planNodes "turn:41:0" plan)
        `shouldBe` [ "turn:41:0",
                     "turn:41:0/c",
                     "turn:41:0/c/t",
                     "turn:41:0/c/e"
                   ]

    it "gives every node a distinct id" $ do
      let ids = map fst (planNodes "turn:41:0" plan)
      length (Set.fromList ids) `shouldBe` length ids

    it "finds each hole under the id its path derives" $
      map (\(nodeId, found) -> (nodeId.unNodeId, found.goalObjective)) (planHoles "turn:41:0" plan)
        `shouldBe` [("turn:41:0/c/e", "总结搜索结果")]

    it "reports node kinds in the same order" $
      map (kindOf . snd) (planNodes "turn:41:0" plan)
        `shouldBe` ["call", "guard", "done", "hole"]

  describe "budgets" $ do
    it "starts a narrowing from a budget that forbids everything" $ do
      Set.null emptyBudget.ebEffects `shouldBe` True
      emptyBudget.ebMaxCalls `shouldBe` 0
      emptyBudget.ebMaxSends `shouldBe` 0

    it "unions taint rather than replacing it" $
      taintUnion [Taint (Set.singleton TaintExternal), Taint (Set.singleton TaintPrivate)]
        `shouldBe` Taint (Set.fromList [TaintExternal, TaintPrivate])

    it "starts from no taint at all" $
      untainted `shouldBe` Taint Set.empty

kindOf :: PlanNode -> Text
kindOf = \case
  NodeDone _ -> "done"
  NodeCall _ -> "call"
  NodeLet _ _ -> "let"
  NodeGuard _ -> "guard"
  NodeHole _ -> "hole"
