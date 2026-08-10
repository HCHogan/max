module Max.Plan.ExecuteSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Vector qualified as V
import Effectful (liftIO, runEff)
import Max.Effects.Tools
  ( SchemaVersion (..),
    Tool (..),
    ToolDefinition (..),
    ToolEffect (..),
    ToolParallelism (..),
    ToolRef (..),
    ToolRetryClass (..),
    buildToolCatalog,
    runTools,
  )
import Max.Effects.Tools qualified as Tools
import Max.Plan.Execute
import Max.Plan.Parse (parsePlan)
import Max.Plan.Schema (PlanSchema (..), SchemaField (..))
import Max.Plan.Types
import Max.Plan.Validate
import Test.Hspec

field :: Text -> PlanSchema -> SchemaField
field name schema = SchemaField {sfName = name, sfSchema = schema, sfRequired = True}

-- The kernel's view of the two tools.
searchEntry :: CatalogEntry
searchEntry =
  CatalogEntry
    { ceRef = ToolRef "search_web",
      ceSchemaVersion = SchemaVersion 3,
      ceInput = SchemaObject [field "query" SchemaText],
      ceResult = SchemaArray (SchemaObject [field "title" SchemaText]),
      ceEffects = Set.singleton (EffRead (ExternalScope "web")),
      ceAuthorities = Set.empty,
      ceIntroduces = Taint (Set.singleton TaintExternal)
    }

replyEntry :: CatalogEntry
replyEntry =
  CatalogEntry
    { ceRef = ToolRef "reply",
      ceSchemaVersion = SchemaVersion 1,
      ceInput = SchemaObject [field "text" SchemaText],
      ceResult = SchemaObject [],
      ceEffects = Set.singleton (EffSend AudienceConversation),
      ceAuthorities = Set.singleton Tools.CurrentConversation,
      ceIntroduces = untainted
    }

-- The runtime's view of the same two.  Deliberately the real catalog rather
-- than a hand-interpreted effect: execution then goes through the same argument
-- validation and outcome classification production uses.
wireSchema :: Text -> Value
wireSchema name =
  object
    [ "type" .= ("object" :: Text),
      "properties" .= object [Key.fromText name .= object ["type" .= ("string" :: Text)]],
      "required" .= [name]
    ]

searchDefinition :: ToolDefinition
searchDefinition =
  ToolDefinition
    { tdRef = ToolRef "search_web",
      tdSchemaVersion = SchemaVersion 1,
      tdEffects = Set.singleton (EffectRead "web"),
      tdParallelism = ParallelSafe,
      tdRetryClass = RetrySafe,
      tdAuthorities = Set.empty,
      tdFailuresPrecedeEffects = False
    }

replyDefinition :: ToolDefinition
replyDefinition =
  ToolDefinition
    { tdRef = ToolRef "reply",
      tdSchemaVersion = SchemaVersion 1,
      tdEffects = Set.singleton (EffectSend "conversation"),
      tdParallelism = SequentialOnly,
      tdRetryClass = RetryUnsafe,
      tdAuthorities = Set.singleton Tools.CurrentConversation,
      tdFailuresPrecedeEffects = False
    }

validation :: ValidationEnv
validation =
  ValidationEnv
    { venCatalog = Map.fromList [(entry.ceRef, entry) | entry <- [searchEntry, replyEntry]],
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
                    Set.fromList [EffRead (ExternalScope "web"), EffSend AudienceConversation],
                  ebMaxCalls = 3,
                  ebMaxSends = 1,
                  ebMaxFanout = 8,
                  ebMaxTokens = 100000,
                  ebMaxWallClockMs = 30000
                },
            goalAuthority = Set.singleton Tools.CurrentConversation,
            goalDeclassify = Taint (Set.singleton TaintExternal),
            goalDeps = noDependencies,
            goalEvidence = [],
            goalAttempt = 0
          },
      venBindings = Map.empty,
      venCostCeiling = 100000
    }

executionEnv :: ExecutionEnv
executionEnv =
  ExecutionEnv {exValidation = validation, exHandles = Map.empty, exRoot = "turn:1:0"}

valid :: Text -> ValidPlan
valid source = case parsePlan source of
  Left failure -> error (show failure)
  Right plan -> case validatePlan validation "turn:1:0" plan of
    Left rejection -> error (show (rejectionText rejection))
    Right checked -> checked

hits :: Value
hits = Array (V.fromList [object ["title" .= ("第一条" :: Text)]])

-- | Run a plan against a catalog whose runners answer from the given table and
-- record what they were called with.
run ::
  [(Text, Either Text Value)] ->
  ValidPlan ->
  IO (ExecutionResult, [(Text, Value)])
run answers plan = do
  seen <- newIORef []
  catalog <-
    either (fail . show) pure $
      buildToolCatalog
        [searchDefinition, replyDefinition]
        [ Tool
            { toolName = "search_web",
              toolDescription = "fake search",
              toolSchema = wireSchema "query",
              toolRun = \args -> do
                liftIO (modifyIORef' seen (<> [("search_web", args)]))
                pure (maybe (Right Null) id (lookup "search_web" answers))
            },
          Tool
            { toolName = "reply",
              toolDescription = "fake reply",
              toolSchema = wireSchema "text",
              toolRun = \args -> do
                liftIO (modifyIORef' seen (<> [("reply", args)]))
                pure (maybe (Right Null) id (lookup "reply" answers))
            }
        ]
  result <- runEff . runTools catalog $ executePlan executionEnv plan
  invoked <- readIORef seen
  pure (result, invoked)

spec :: Spec
spec = do
  describe "execution" $ do
    let searchThenAnswer = valid "let hits = search_web@3({ query: \"q\" })\ndone hits[0].title ?? \"\""

    it "calls the tool with the arguments the expression built" $ do
      (_, invoked) <- run [("search_web", Right hits)] searchThenAnswer
      invoked `shouldBe` [("search_web", object ["query" .= ("q" :: Text)])]

    it "binds a result and produces the value the plan asked for" $ do
      (result, _) <- run [("search_web", Right hits)] searchThenAnswer
      result.erEnd `shouldBe` Produced (String "第一条")
      result.erCallsUsed `shouldBe` 1

    it "takes the branch the live result selects" $ do
      let plan = valid "let hits = search_web@3({ query: \"q\" })\nif length(hits) > 0 { done \"有\" } else { done \"无\" }"
      (found, _) <- run [("search_web", Right hits)] plan
      found.erEnd `shouldBe` Produced (String "有")
      (none, _) <- run [("search_web", Right (Array mempty))] plan
      none.erEnd `shouldBe` Produced (String "无")

    it "records every step for the journal" $ do
      (result, _) <- run [("search_web", Right hits)] searchThenAnswer
      map (\step -> (step.srNode.unNodeId, step.srTool)) result.erSteps
        `shouldBe` [("turn:1:0", ToolRef "search_web")]

  describe "deoptimization" $ do
    let searchThenAnswer = valid "let hits = search_web@3({ query: \"q\" })\ndone hits[0].title ?? \"\""

    it "stops at a hole rather than inventing a continuation" $ do
      (result, invoked) <-
        run [] (valid "hole \"接着做什么\" : text budget { calls: 1, fanout: 8, tokens: 10, ms: 10 }")
      invoked `shouldBe` []
      case result.erEnd of
        Deoptimized (AtHole _ goal) -> goal.goalObjective `shouldBe` "接着做什么"
        other -> expectationFailure ("expected a hole, got " <> show other)

    it "stops on a failure instead of retrying it" $ do
      (result, invoked) <- run [("search_web", Left "upstream down")] searchThenAnswer
      length invoked `shouldBe` 1
      case result.erEnd of
        Deoptimized (ToolStopped _ _ (StepFailed detail)) -> detail `shouldBe` "upstream down"
        other -> expectationFailure ("expected a stop, got " <> show other)

    it "never re-runs a step whose outcome is unknown" $ do
      -- reply sends, so a returned error is conservatively outcome-unknown.
      -- That call may already have landed; running it again is the
      -- duplicate-effect failure mode the executor exists to avoid.
      (result, invoked) <-
        run
          [("reply", Left "connection reset")]
          (valid "let sent = reply@1({ text: \"hi\" })\ndone \"ok\"")
      length invoked `shouldBe` 1
      case result.erEnd of
        Deoptimized (ToolStopped _ _ (StepOutcomeUnknown _)) -> pure ()
        other -> expectationFailure ("expected an unknown-outcome stop, got " <> show other)

    it "refuses a result its catalog schema does not describe" $ do
      (result, _) <- run [("search_web", Right (String "not an array of hits"))] searchThenAnswer
      case result.erEnd of
        Deoptimized (ResultOffSchema _ ref _) -> ref `shouldBe` ToolRef "search_web"
        other -> expectationFailure ("expected an off-schema stop, got " <> show other)

    it "stops before a call that would exceed the send budget" $ do
      let noSends =
            executionEnv
              { exValidation =
                  validation
                    { venGoal =
                        validation.venGoal
                          {goalBudget = validation.venGoal.goalBudget {ebMaxSends = 0}}
                    }
              }
      seen <- newIORef []
      catalog <-
        either (fail . show) pure $
          buildToolCatalog
            [replyDefinition]
            [ Tool
                { toolName = "reply",
                  toolDescription = "fake reply",
                  toolSchema = wireSchema "text",
                  toolRun = \args -> do
                    liftIO (modifyIORef' seen (<> [("reply" :: Text, args)]))
                    pure (Right Null)
                }
            ]
      result <-
        runEff . runTools catalog $
          executePlan noSends (valid "let sent = reply@1({ text: \"hi\" })\ndone \"ok\"")
      invoked <- readIORef seen
      -- Nothing was sent: the ceiling is checked before the call, not after.
      invoked `shouldBe` []
      case result.erEnd of
        Deoptimized (BudgetSpent _ detail) -> detail `shouldBe` "send budget spent"
        other -> expectationFailure ("expected a budget stop, got " <> show other)
