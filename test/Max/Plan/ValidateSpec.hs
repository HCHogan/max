module Max.Plan.ValidateSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Max.Effects.Tools (SchemaVersion (..), ToolRef (..))
import Max.Effects.Tools qualified as Tools
import Max.Plan.Parse (parseFailureText, parsePlan)
import Max.Plan.Schema (PlanSchema (..), SchemaField (..))
import Max.Plan.Types
import Max.Plan.Validate
import Test.Hspec

field :: Text -> PlanSchema -> SchemaField
field name schema = SchemaField {sfName = name, sfSchema = schema, sfRequired = True}

hitSchema :: PlanSchema
hitSchema = SchemaObject [field "title" SchemaText, field "url" SchemaText]

-- A read of the open web: no host authority, but every result is external.
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

-- A visible send, which needs conversation authority.
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

-- Reads a narrower scope than the turn's audience, so its results are private.
memoryTool :: CatalogEntry
memoryTool =
  CatalogEntry
    { ceRef = ToolRef "read_memory",
      ceSchemaVersion = SchemaVersion 1,
      ceInput = SchemaObject [],
      ceResult = SchemaText,
      ceEffects = Set.singleton (EffRead CurrentConversation),
      ceAuthorities = Set.singleton Tools.CurrentConversation
    }

-- Wants an authority the goal never granted.
browserTool :: CatalogEntry
browserTool =
  CatalogEntry
    { ceRef = ToolRef "browse",
      ceSchemaVersion = SchemaVersion 1,
      ceInput = SchemaObject [],
      ceResult = SchemaText,
      ceEffects = Set.singleton (EffRead (ExternalScope "web")),
      ceAuthorities = Set.singleton (Tools.ProcessResource "browser")
    }

-- Writes a sandbox, an effect the goal's budget does not list.
sandboxTool :: CatalogEntry
sandboxTool =
  CatalogEntry
    { ceRef = ToolRef "sandbox_exec",
      ceSchemaVersion = SchemaVersion 1,
      ceInput = SchemaObject [],
      ceResult = SchemaText,
      ceEffects = Set.singleton (EffWrite (SandboxScope "work")),
      ceAuthorities = Set.empty
    }

budget :: EffectBudget
budget =
  EffectBudget
    { ebEffects =
        Set.fromList
          [ EffRead (ExternalScope "web"),
            EffRead CurrentConversation,
            EffSend AudienceConversation
          ],
      ebMaxCalls = 3,
      ebMaxSends = 1,
      ebMaxFanout = 8,
      ebMaxTokens = 8000,
      ebMaxWallClockMs = 30000
    }

goal :: Goal
goal =
  Goal
    { goalObjective = "回答用户的问题",
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
    { venCatalog =
        Map.fromList
          [ (entry.ceRef, entry)
            | entry <- [searchTool, replyTool, memoryTool, browserTool, sandboxTool]
          ],
      venVerifiers =
        Map.singleton
          "answers-question"
          VerifierEntry {veName = "answers-question", veVersion = 1, veAccepts = SchemaText},
      venHandles =
        Map.fromList
          [ ( "t#1:r1",
              ValueRef
                { vrHandle = "t#1:r1",
                  vrSchema = SchemaText,
                  vrScope = CurrentConversation,
                  vrDigest = "abc",
                  vrLength = 12,
                  vrRetained = True
                }
            ),
            ( "t#1:r2",
              ValueRef
                { vrHandle = "t#1:r2",
                  vrSchema = SchemaText,
                  vrScope = CurrentConversation,
                  vrDigest = "def",
                  vrLength = 12,
                  vrRetained = False
                }
            )
          ],
      venAdmittedVerifiers = Set.singleton "answers-question",
      venGoal = goal,
      venBindings = Map.empty,
      venCostCeiling = 100000
    }

search :: CallNode
search =
  CallNode
    { cnBind = Binder "hits",
      cnTool = ToolRef "search_web",
      cnSchemaVersion = SchemaVersion 3,
      cnInput = EObject [("query", ELit (LitText "prime agent"))]
    }

-- hits[0].title, with the null the index type forces eliminated.
firstTitle :: Expr
firstTitle =
  ECoalesce
    (EField (EIndex (EVar (Binder "hits")) 0) "title")
    (ELit (LitText "没有结果"))

check :: Plan -> Either Rejection ValidPlan
check = validatePlan env "turn:41:0"

reasonOf :: Plan -> Maybe RejectReason
reasonOf = either (Just . (.rjReason)) (const Nothing) . check

nodeOf :: Plan -> Maybe Text
nodeOf = either (Just . (.rjNode.unNodeId)) (const Nothing) . check

admitted :: Plan -> Expectation
admitted plan = case check plan of
  Right valid -> validPlan valid `shouldBe` plan
  Left rejection -> expectationFailure ("unexpectedly rejected: " <> show (rejectionText rejection))

spec :: Spec
spec = do
  describe "admission" $ do
    it "admits a well-typed plan inside its budget" $
      admitted (Call search (Done firstTitle))

    it "hands back exactly the plan that was checked" $
      admitted (Done (ELit (LitText "hi")))

    it "admits a resolvable, still-retained handle" $
      admitted (Done (EHandle "t#1:r1"))

    it "admits what the DSL parser produces for the same program" $ do
      -- The end-to-end claim of E5's front half: a model writes surface
      -- syntax, the parser yields the IR, and the kernel admits it — with no
      -- hand-built plan value anywhere in between.
      let source =
            T.unlines
              [ "let hits = search_web@3({ query: \"prime agent\" })",
                "done hits[0].title ?? \"没有结果\""
              ]
      case parsePlan source of
        Left failure -> expectationFailure ("did not parse: " <> show (parseFailureText failure))
        Right plan -> admitted plan

    it "rejects a parsed plan that exceeds the budget it was written under" $ do
      let source =
            T.unlines
              [ "let a = reply@1({ text: \"one\" })",
                "let b = reply@1({ text: \"two\" })",
                "done \"done\""
              ]
      case parsePlan source of
        Left failure -> expectationFailure ("did not parse: " <> show (parseFailureText failure))
        Right plan -> either (.rjReason) (const (UnknownVerifier "none")) (check plan) `shouldBe` SendBudgetExceeded 1 2

  describe "catalog and schema" $ do
    it "rejects a tool the catalog does not have" $
      reasonOf (Call search {cnTool = ToolRef "rm_rf"} (Done (ELit (LitText "x"))))
        `shouldBe` Just (UnknownTool (ToolRef "rm_rf"))

    it "rejects a plan written against a drifted schema version" $
      reasonOf (Call search {cnSchemaVersion = SchemaVersion 2} (Done (ELit (LitText "x"))))
        `shouldBe` Just (ToolSchemaDrift (ToolRef "search_web") 3 2)

    it "rejects arguments that do not match the tool's input schema" $ do
      let wrong = search {cnInput = EObject [("query", ELit (LitInt 1))]}
      case reasonOf (Call wrong (Done (ELit (LitText "x")))) of
        Just (ArgumentSchema (ToolRef "search_web") _) -> pure ()
        other -> expectationFailure ("expected an argument rejection, got " <> show other)

    it "rejects an argument object with a field the tool never declared" $ do
      let wrong = search {cnInput = EObject [("query", ELit (LitText "q")), ("admin", ELit (LitBool True))]}
      case reasonOf (Call wrong (Done (ELit (LitText "x")))) of
        Just (ArgumentSchema (ToolRef "search_web") _) -> pure ()
        other -> expectationFailure ("expected an argument rejection, got " <> show other)

    it "rejects a result used at the wrong type" $
      case reasonOf (Call search (Done (EVar (Binder "hits")))) of
        Just (ExpressionType "text" _) -> pure ()
        other -> expectationFailure ("expected a type rejection, got " <> show other)

  describe "bindings" $ do
    it "rejects a binder that shadows a name already in scope" $
      reasonOf (Call search (Call search (Done (ELit (LitText "x")))))
        `shouldBe` Just (ShadowedBinding (Binder "hits"))

    it "rejects a name that is not bound anywhere" $
      reasonOf (Done (EVar (Binder "hits")))
        `shouldBe` Just (UnboundName (Binder "hits"))

    it "rejects a forward reference to a later call's result" $
      reasonOf (Done (EConcat [EVar (Binder "hits")]))
        `shouldBe` Just (UnboundName (Binder "hits"))

    it "rejects a combinator binder that shadows an outer one" $
      reasonOf (Call search (Done (EConcat [EMap (Binder "hits") (EVar (Binder "hits")) (ELit (LitText "x"))])))
        `shouldBe` Just (ShadowedBinding (Binder "hits"))

  describe "handles" $ do
    it "rejects a handle that does not resolve in this scope" $
      reasonOf (Done (EHandle "t#9:r9")) `shouldBe` Just (UnresolvableHandle "t#9:r9")

    it "rejects a handle whose body retention already released" $
      reasonOf (Done (EHandle "t#1:r2")) `shouldBe` Just (ReleasedHandle "t#1:r2")

  describe "effects and authority" $ do
    it "rejects an effect the goal's budget does not list" $ do
      let exec = search {cnBind = Binder "out", cnTool = ToolRef "sandbox_exec", cnSchemaVersion = SchemaVersion 1, cnInput = EObject []}
      reasonOf (Call exec (Done (EVar (Binder "out"))))
        `shouldBe` Just (EffectNotPermitted (EffWrite (SandboxScope "work")))

    it "rejects an authority the goal never granted" $ do
      let browse = search {cnBind = Binder "page", cnTool = ToolRef "browse", cnSchemaVersion = SchemaVersion 1, cnInput = EObject []}
      reasonOf (Call browse (Done (EVar (Binder "page"))))
        `shouldBe` Just (AuthorityNotPermitted (Tools.ProcessResource "browser"))

  describe "pure bindings" $ do
    it "admits naming a value" $
      admitted (Let (Binder "greeting") (ELit (LitText "hi")) (Done (EVar (Binder "greeting"))))

    it "types the binding from its expression, and holds the use to that type" $
      reasonOf (Let (Binder "n") (ELit (LitInt 1)) (Done (EVar (Binder "n"))))
        `shouldBe` Just (ExpressionType "text" "int")

    it "rejects a name already in scope, exactly as a call would" $
      reasonOf
        ( Call
            search
            (Let (Binder "hits") (ELit (LitText "x")) (Done (ELit (LitText "y"))))
        )
        `shouldBe` Just (ShadowedBinding (Binder "hits"))

    it "rejects an expression that does not typecheck" $
      reasonOf (Let (Binder "bad") (ELength (ELit (LitBool True))) (Done (ELit (LitText "x"))))
        `shouldSatisfy` \case
          Just (ExpressionType _ _) -> True
          _ -> False

    it "spends no call and no send, however many bindings there are" $ do
      -- The point of the whole construct: it buys legibility and nothing else.
      -- If a pure binding could move any ceiling, adding it would have been a
      -- change to the kernel's guarantees rather than to its ergonomics.
      let names = [Binder ("v" <> tshow n) | n <- [1 .. 20 :: Int]]
          nest = foldr (\binder rest -> Let binder (ELit (LitText "x")) rest) (Done (ELit (LitText "x"))) names
      admitted nest

  describe "budgets" $ do
    it "rejects a plan that makes more calls than the budget allows" $ do
      let chain n
            | n <= (0 :: Int) = Done (ELit (LitText "x"))
            | otherwise = Call search {cnBind = Binder ("hits" <> tshow n)} (chain (n - 1))
      reasonOf (chain 4) `shouldBe` Just (CallBudgetExceeded 3 4)

    it "rejects a plan that sends more often than the budget allows" $ do
      let send name rest =
            Call
              CallNode
                { cnBind = Binder name,
                  cnTool = ToolRef "reply",
                  cnSchemaVersion = SchemaVersion 1,
                  cnInput = EObject [("text", ELit (LitText "hi"))]
                }
              rest
      reasonOf (send "a" (send "b" (Done (ELit (LitText "x")))))
        `shouldBe` Just (SendBudgetExceeded 1 2)

    it "charges guard branches as alternatives, not as a sum" $ do
      -- Two sends, but never both on one execution path, so the ceiling of one
      -- send is respected.
      let send name rest =
            Call
              CallNode
                { cnBind = Binder name,
                  cnTool = ToolRef "reply",
                  cnSchemaVersion = SchemaVersion 1,
                  cnInput = EObject [("text", ELit (LitText "hi"))]
                }
              rest
      admitted
        ( Guard
            (PCompare OpEq (ELit (LitInt 1)) (ELit (LitInt 1)))
            (send "a" (Done (ELit (LitText "x"))))
            (send "b" (Done (ELit (LitText "y"))))
        )

    it "prices an over-nested expression out of the cost ceiling" $ do
      -- Well-typed, so it is the price that rejects it and not the shape:
      -- three nested maps over the fanout cap, indexed back down to text.
      let nest 0 = ELit (LitText "x")
          nest depth = EMap (Binder ("i" <> tshow depth)) (EArray [ELit (LitText "a")]) (nest (depth - 1 :: Int))
          expensive = ECoalesce (EIndex (EIndex (EIndex (nest 3) 0) 0) 0) (ELit (LitText "fallback"))
          tiny = env {venCostCeiling = 100}
      case validatePlan tiny "turn:41:0" (Done expensive) of
        Left rejection -> case rejection.rjReason of
          CostCeilingExceeded 100 _ -> pure ()
          other -> expectationFailure ("expected a cost rejection, got " <> show other)
        Right _ -> expectationFailure "an over-nested expression was admitted"

  describe "holes" $ do
    let childGoal = goal {goalObjective = "子目标", goalBudget = budget {ebMaxCalls = 1, ebMaxSends = 0}}

    it "admits a hole that narrows its parent" $
      admitted (Hole childGoal)

    it "rejects a hole that hands itself more calls than its parent has" $
      reasonOf (Hole childGoal {goalBudget = budget {ebMaxCalls = 99}})
        `shouldBe` Just (BudgetNotNarrowing "calls")

    it "rejects a hole that grants itself an effect its parent lacks" $
      reasonOf (Hole childGoal {goalBudget = budget {ebEffects = Set.insert (EffReflect "tools") budget.ebEffects}})
        `shouldBe` Just (BudgetNotNarrowing "effects")

    it "refuses a plan that writes its own evidence or attempt count" $ do
      -- Only the host attaches these, on re-hole.  A plan that could write them
      -- could launder a failed attempt into a fresh one, or fabricate an
      -- account of a failure that never happened.
      let forged =
            Evidence
              { evSource = FromVerifier "answers-question",
                evDetail = "trust me, it passed",
                evScope = CurrentConversation
              }
      reasonOf (Hole childGoal {goalEvidence = [forged]})
        `shouldBe` Just (HostOnlyField "evidence")
      reasonOf (Hole childGoal {goalAttempt = 0 - 5})
        `shouldBe` Just (HostOnlyField "attempt")

    it "counts a hole's whole budget against the enclosing one" $
      reasonOf (Call search (Hole childGoal {goalBudget = budget {ebMaxCalls = 3, ebMaxSends = 0}}))
        `shouldBe` Just (CallBudgetExceeded 3 4)

    it "rejects a goal handed a resource this plan cannot resolve" $
      reasonOf (Hole childGoal {goalResources = ["t#9:r9"]})
        `shouldBe` Just (UnresolvableHandle "t#9:r9")

    it "rejects a goal handed a resource whose body retention released" $
      reasonOf (Hole childGoal {goalResources = ["t#1:r2"]})
        `shouldBe` Just (ReleasedHandle "t#1:r2")

    it "admits a goal handed a resource this plan holds" $
      admitted (Hole childGoal {goalResources = ["t#1:r1"]})

  describe "forks" $ do
    let child name calls =
          ( Binder name,
            goal
              { goalObjective = "查 " <> name,
                goalExpected = SchemaText,
                goalBudget = budget {ebMaxCalls = calls, ebMaxSends = 0}
              }
          )
        forkOf children = Fork ForkNode {fnChildren = children, fnJoin = JoinAll, fnWatch = WatchOnFailure}

    it "admits two subgoals whose grants add up to what the plan has" $
      admitted (forkOf [child "a" 1, child "b" 2] (Done (EConcat [EVar (Binder "a"), EVar (Binder "b")])))

    it "adds sibling budgets rather than taking the largest" $
      -- The whole arithmetic point.  Each child narrows its parent on its own —
      -- 2 ≤ 3 twice over — and together they are over.  A check that only
      -- compared each child against the ceiling would admit this, and admitting
      -- it means a plan can have any budget it likes by asking n times.
      reasonOf (forkOf [child "a" 2, child "b" 2] (Done (EVar (Binder "a"))))
        `shouldBe` Just (ForkBudgetExceeded "calls" 3 4)

    it "counts a fork alongside the calls around it, not only against itself" $
      -- Fits on its own (2 ≤ 3); does not fit after a search has spent one.
      reasonOf (Call search (forkOf [child "a" 1, child "b" 2] (Done (EVar (Binder "a")))))
        `shouldBe` Just (CallBudgetExceeded 3 4)

    it "still holds each subgoal to its parent on its own" $
      reasonOf (forkOf [child "a" 99] (Done (EVar (Binder "a"))))
        `shouldBe` Just (BudgetNotNarrowing "calls")

    it "binds each subgoal's declared type, so the join is checked before it runs" $
      -- The continuation is written before any child has produced anything.
      -- What makes that checkable is the declared result type and nothing else.
      reasonOf (forkOf [child "a" 1] (Done (ELength (EVar (Binder "a")))))
        `shouldBe` Just (ExpressionType "text" "int")

    it "rejects a subgoal naming something already in scope" $
      reasonOf (Call search (forkOf [child "hits" 1] (Done (EVar (Binder "hits")))))
        `shouldBe` Just (ShadowedBinding (Binder "hits"))

    it "rejects two siblings claiming the same name" $
      reasonOf (forkOf [child "a" 1, child "a" 1] (Done (EVar (Binder "a"))))
        `shouldBe` Just (ShadowedBinding (Binder "a"))

    it "rejects a fork that opens nothing" $
      reasonOf (forkOf [] (Done (ELit (LitText "ok")))) `shouldBe` Just EmptyFork

    it "points at the subgoal that failed, not at the fork" $
      nodeOf (forkOf [child "a" 1, child "b" 99] (Done (EVar (Binder "a"))))
        `shouldBe` Just "turn:41:0/k1"

  describe "acceptance verifiers" $ do
    let withVerifier ref = goal {goalObjective = "子目标", goalAcceptance = [ref], goalBudget = budget {ebMaxCalls = 1, ebMaxSends = 0}}

    it "admits a registered, admitted verifier at the right version" $
      admitted (Hole (withVerifier VerifierRef {verName = "answers-question", verVersion = 1}))

    it "rejects a verifier the registry has never heard of" $
      reasonOf (Hole (withVerifier VerifierRef {verName = "looks-good", verVersion = 1}))
        `shouldBe` Just (VerifierNotAdmitted "looks-good")

    it "rejects a verifier version the registry has moved past" $
      reasonOf (Hole (withVerifier VerifierRef {verName = "answers-question", verVersion = 7}))
        `shouldBe` Just (VerifierVersionDrift "answers-question" 1 7)

    it "rejects a gate that cannot read the value it is gating" $ do
      let numeric = (withVerifier VerifierRef {verName = "answers-question", verVersion = 1}) {goalExpected = SchemaInt}
      reasonOf (Hole numeric)
        `shouldBe` Just (VerifierSchemaMismatch "answers-question" "text" "int")

  describe "rejection reporting" $ do
    it "points at the node that failed, not at the root" $
      nodeOf (Call search (Done (EVar (Binder "nope")))) `shouldBe` Just "turn:41:0/c"

    it "points into the failing guard branch" $
      nodeOf
        ( Guard
            (PBool True)
            (Done (ELit (LitText "ok")))
            (Done (EVar (Binder "nope")))
        )
        `shouldBe` Just "turn:41:0/e"

  describe "subsumption" $ do
    it "widens an enum to text and an int to a number" $ do
      admits SchemaText (SchemaEnum ["a"]) `shouldBe` True
      admits SchemaNumber SchemaInt `shouldBe` True
      admits SchemaInt SchemaNumber `shouldBe` False

    it "accepts a non-null value where null is allowed, but never the reverse" $ do
      admits (SchemaNullable SchemaText) SchemaText `shouldBe` True
      admits SchemaText (SchemaNullable SchemaText) `shouldBe` False

    it "keeps objects closed in both directions" $ do
      let wanted = SchemaObject [field "a" SchemaText]
          extra = SchemaObject [field "a" SchemaText, field "b" SchemaText]
      admits wanted extra `shouldBe` False
      admits extra wanted `shouldBe` False

    it "rejects an optional field where a required one is expected" $ do
      let wanted = SchemaObject [field "a" SchemaText]
          optional = SchemaObject [SchemaField {sfName = "a", sfSchema = SchemaText, sfRequired = False}]
      admits wanted optional `shouldBe` False
      admits optional wanted `shouldBe` True

tshow :: Show a => a -> Text
tshow = T.pack . show
