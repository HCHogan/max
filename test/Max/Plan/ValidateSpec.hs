module Max.Plan.ValidateSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Max.Effects.Tools (SchemaVersion (..), ToolRef (..))
import Max.Effects.Tools qualified as Tools
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
      ceAuthorities = Set.empty,
      ceIntroduces = Taint (Set.singleton TaintExternal)
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
      ceAuthorities = Set.singleton Tools.CurrentConversation,
      ceIntroduces = untainted
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
      ceAuthorities = Set.singleton Tools.CurrentConversation,
      ceIntroduces = Taint (Set.singleton TaintPrivate)
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
      ceAuthorities = Set.singleton (Tools.ProcessResource "browser"),
      ceIntroduces = untainted
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
      ceAuthorities = Set.empty,
      ceIntroduces = untainted
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
      goalDeclassify = Taint (Set.singleton TaintExternal),
      goalDeps = noDependencies
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
                  vrTaint = untainted,
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
                  vrTaint = untainted,
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

  describe "effects, authority and information flow" $ do
    it "rejects an effect the goal's budget does not list" $ do
      let exec = search {cnBind = Binder "out", cnTool = ToolRef "sandbox_exec", cnSchemaVersion = SchemaVersion 1, cnInput = EObject []}
      reasonOf (Call exec (Done (EVar (Binder "out"))))
        `shouldBe` Just (EffectNotPermitted (EffWrite (SandboxScope "work")))

    it "rejects an authority the goal never granted" $ do
      let browse = search {cnBind = Binder "page", cnTool = ToolRef "browse", cnSchemaVersion = SchemaVersion 1, cnInput = EObject []}
      reasonOf (Call browse (Done (EVar (Binder "page"))))
        `shouldBe` Just (AuthorityNotPermitted (Tools.ProcessResource "browser"))

    it "lets an externally tainted value out, because this goal declassifies it" $
      admitted (Call search (Done firstTitle))

    it "refuses to let a privately scoped value out of a goal that cannot declassify it" $ do
      let readMemory = search {cnBind = Binder "note", cnTool = ToolRef "read_memory", cnSchemaVersion = SchemaVersion 1, cnInput = EObject []}
      reasonOf (Call readMemory (Done (EVar (Binder "note"))))
        `shouldBe` Just (TaintNotDeclassified TaintPrivate)

    it "propagates taint through an expression rather than losing it" $ do
      let readMemory = search {cnBind = Binder "note", cnTool = ToolRef "read_memory", cnSchemaVersion = SchemaVersion 1, cnInput = EObject []}
      reasonOf (Call readMemory (Done (EConcat [ELit (LitText "备注："), EVar (Binder "note")])))
        `shouldBe` Just (TaintNotDeclassified TaintPrivate)

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

    it "rejects a hole that widens its own declassification" $
      reasonOf (Hole childGoal {goalDeclassify = Taint (Set.fromList [TaintExternal, TaintPrivate])})
        `shouldBe` Just (BudgetNotNarrowing "declassification")

    it "counts a hole's whole budget against the enclosing one" $
      reasonOf (Call search (Hole childGoal {goalBudget = budget {ebMaxCalls = 3, ebMaxSends = 0}}))
        `shouldBe` Just (CallBudgetExceeded 3 4)

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
