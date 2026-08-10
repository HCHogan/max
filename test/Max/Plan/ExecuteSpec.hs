module Max.Plan.ExecuteSpec (spec) where

import Data.Aeson (Value (..), decode, encode, object, (.=))
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
            goalResources = [],
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

-- | Drive a plan by hand, forcing the checkpoint through JSON at every
-- suspension.
--
-- This is what a host that journals and authorizes between calls does, and it
-- is also what a restart between two calls lands on: nothing but the encoded
-- state crosses from one call to the next.
driveAcrossRestarts ::
  (PendingCall -> StepOutcome) ->
  ValidPlan ->
  Either Text ExecutionEnd
driveAcrossRestarts answer plan = go initialState
  where
    go state = case stepPlan executionEnv plan state of
      Completes end -> Right end
      Suspends suspension -> case answer suspension.suCall of
        outcome -> case resumeWith executionEnv suspension outcome of
          Left deopt -> Right (Deoptimized deopt)
          Right next -> case reencode next of
            Nothing -> Left "execution state did not survive a round trip"
            Just revived -> go revived

    reencode = decode . encode

spec :: Spec
spec = do
  describe "suspension" $ do
    let searchThenAnswer = valid "let hits = search_web@3({ query: \"q\" })\ndone hits[0].title ?? \"\""

    it "stops before the effect, holding the arguments it is about to use" $ do
      -- A declared ceiling says a plan may search.  Only this says what it is
      -- about to search for, which is the difference between a budget and an
      -- approval.
      case stepPlan executionEnv searchThenAnswer initialState of
        Suspends suspension -> do
          suspension.suCall.pnTool `shouldBe` ToolRef "search_web"
          suspension.suCall.pnArguments `shouldBe` object ["query" .= ("q" :: Text)]
          suspension.suCall.pnNode.unNodeId `shouldBe` "turn:1:0"
          suspension.suBind `shouldBe` Binder "hits"
        other -> expectationFailure ("expected a suspension, got " <> show other)

    it "reports the sends one call would spend, without the caller re-deriving it" $ do
      case stepPlan executionEnv (valid "let sent = reply@1({ text: \"hi\" })\ndone \"ok\"") initialState of
        Suspends suspension -> suspension.suCall.pnSends `shouldBe` 1
        other -> expectationFailure ("expected a suspension, got " <> show other)

    it "charges the call only on the state that resumes past it" $ do
      -- A refused call is never resumed, so the charge never applies to work
      -- that did not happen.
      case stepPlan executionEnv searchThenAnswer initialState of
        Suspends suspension -> do
          suspension.suNext.esCalls `shouldBe` 1
          -- and the state it was reached from is still unspent
          initialState.esCalls `shouldBe` 0
        other -> expectationFailure ("expected a suspension, got " <> show other)

    it "produces the same answer when every checkpoint crosses a restart" $ do
      -- The property the whole split exists for: a crash between two calls
      -- loses the call in flight and nothing else.
      let plan =
            valid
              "let hits = search_web@3({ query: \"q\" })\n\
              \let best = hits[0].title ?? \"\"\n\
              \if length(hits) > 0 { done best } else { done \"无\" }"
      driveAcrossRestarts (const (StepSucceeded hits)) plan
        `shouldBe` Right (Produced (String "第一条"))

    it "carries the bindings a later step needs across that restart" $ do
      -- The binding, not just the position: a resumed walk that had forgotten
      -- `hits` would fail on an expression the kernel proved was well typed.
      let plan =
            valid
              "let hits = search_web@3({ query: \"q\" })\n\
              \let echo = reply@1({ text: hits[0].title ?? \"\" })\n\
              \done \"ok\""
          answered call
            | call.pnTool == ToolRef "search_web" = StepSucceeded hits
            | otherwise = StepCommitted (object [])
      driveAcrossRestarts answered plan `shouldBe` Right (Produced (String "ok"))

    it "round-trips a whole suspension, not only the state" $ do
      case stepPlan executionEnv searchThenAnswer initialState of
        Suspends suspension -> decode (encode suspension) `shouldBe` Just suspension
        other -> expectationFailure ("expected a suspension, got " <> show other)

    it "refuses to reinterpret a checkpoint taken against a different plan" $ do
      -- What a steer produces: the plan was rewritten while this state was in
      -- flight, and the node it stood on is gone.  Guessing a nearby node would
      -- run something nobody asked for.
      let stale = initialState {esPath = PlanPath [StepThen, StepContinue]}
      case stepPlan executionEnv searchThenAnswer stale of
        Completes (Deoptimized (PathNotInPlan node)) ->
          node.unNodeId `shouldBe` "turn:1:0/t/c"
        other -> expectationFailure ("expected a stale-path stop, got " <> show other)

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

    it "binds a pure value without touching a tool or a budget" $ do
      let plan =
            valid
              "let hits = search_web@3({ query: \"q\" })\nlet best = hits[0].title ?? \"\"\ndone best"
      (result, invoked) <- run [("search_web", Right hits)] plan
      result.erEnd `shouldBe` Produced (String "第一条")
      -- One call, not two: the binding is not a step.
      result.erCallsUsed `shouldBe` 1
      length invoked `shouldBe` 1
      map (.srTool) result.erSteps `shouldBe` [ToolRef "search_web"]

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

    it "reports a fork's subgoals rather than dispatching them itself" $ do
      -- Same exit a hole takes.  Running a child means starting an elaboration,
      -- waiting on it, and reconciling the plan against whatever happened in
      -- the conversation meanwhile; none of that belongs in an interpreter.
      (result, invoked) <-
        run
          []
          ( valid
              "fork {\n\
              \  a: hole \"查甲\" : text budget { calls: 1, fanout: 8, tokens: 10, ms: 10 }\n\
              \  b: hole \"查乙\" : text budget { calls: 1, fanout: 8, tokens: 10, ms: 10 }\n\
              \}\n\
              \done concat(a, b)"
          )
      invoked `shouldBe` []
      case result.erEnd of
        Deoptimized (AtFork _ joinPolicy watchPolicy children) -> do
          (joinPolicy, watchPolicy) `shouldBe` (JoinAll, WatchOnFailure)
          map (\(node, binder, goal) -> (node.unNodeId, binder, goal.goalObjective)) children
            `shouldBe` [("turn:1:0/k0", Binder "a", "查甲"), ("turn:1:0/k1", Binder "b", "查乙")]
        other -> expectationFailure ("expected a fork, got " <> show other)

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
