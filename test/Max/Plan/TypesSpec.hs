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
      goalResources = [],
      goalInputs = [],
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

fanOut :: Plan
fanOut =
  Fork
    ForkNode
      { fnChildren = [(Binder "jia", goal), (Binder "yi", goal {goalObjective = "查乙"})],
        fnJoin = JoinAll,
        fnWatch = WatchEach
      }
    (Done (EConcat [EVar (Binder "jia"), EVar (Binder "yi")]))

roundTrip :: Plan -> Maybe Plan
roundTrip = decode . encode

spec :: Spec
spec = do
  describe "codecs" $ do
    it "round-trips a plan through JSON unchanged" $
      roundTrip plan `shouldBe` Just plan

    it "round-trips a goal named mid-plan" $ do
      let midPlan = Bind (Binder "answer") goal (Done (EVar (Binder "answer")))
      roundTrip midPlan `shouldBe` Just midPlan
      -- It is elaborated in place, so it belongs to the holes and not to the
      -- children: nothing dispatches it.
      map fst (planHoles "turn:41:0" midPlan) `shouldBe` [NodeId "turn:41:0"]
      planChildren "turn:41:0" midPlan `shouldBe` []

    it "round-trips a fork, keeping its subgoals in order" $
      -- Order is identity here: a child's node id is its position, so a codec
      -- that let a key map reorder them would rename every child that moved.
      roundTrip fanOut `shouldBe` Just fanOut

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

    it "names each subgoal by its position under the fork" $ do
      map ((.unNodeId) . fst) (planNodes "turn:41:0" fanOut)
        `shouldBe` ["turn:41:0", "turn:41:0/k0", "turn:41:0/k1", "turn:41:0/c"]
      map (kindOf . snd) (planNodes "turn:41:0" fanOut)
        `shouldBe` ["fork", "child", "child", "done"]

    it "keeps subgoals out of the hole list and holes out of the subgoal list" $ do
      -- Two lists because they are two different jobs: a hole is filled by
      -- whoever is writing this plan, a subgoal is dispatched to someone who
      -- will see only the goal.  Collapsing them would lose that distinction
      -- at exactly the point a scheduler needs it.
      planHoles "turn:41:0" fanOut `shouldBe` []
      map (\(_, binder, _) -> binder) (planChildren "turn:41:0" fanOut)
        `shouldBe` [Binder "jia", Binder "yi"]
      planChildren "turn:41:0" plan `shouldBe` []

  describe "goal identity" $ do
    it "gives the same bytes to the same request, so an unchanged goal is not re-dispatched" $
      goalHash goal `shouldBe` goalHash goal {goalObjective = "总结搜索结果"}

    it "moves when the work asked for moves" $ do
      goalHash goal `shouldNotBe` goalHash goal {goalObjective = "别的事"}
      goalHash goal `shouldNotBe` goalHash goal {goalResources = ["t#1:r0"]}

    it "moves when a retry carries an account of what went wrong" $
      -- A re-holed goal is a different request even though the objective reads
      -- the same: whoever fills it is handed the evidence too.
      goalHash goal
        `shouldNotBe` goalHash goal {goalAttempt = 1, goalEvidence = [Evidence FromResultSchema "no" CurrentConversation]}

  describe "budgets" $ do
    it "starts a narrowing from a budget that forbids everything" $ do
      Set.null emptyBudget.ebEffects `shouldBe` True
      emptyBudget.ebMaxCalls `shouldBe` 0
      emptyBudget.ebMaxSends `shouldBe` 0


kindOf :: PlanNode -> Text
kindOf = \case
  NodeDone _ -> "done"
  NodeCall _ -> "call"
  NodeLet _ _ -> "let"
  NodeBind _ _ -> "bind"
  NodeFork _ _ -> "fork"
  NodeChild _ _ -> "child"
  NodeGuard _ -> "guard"
  NodeHole _ -> "hole"
