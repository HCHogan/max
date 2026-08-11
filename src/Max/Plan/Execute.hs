-- | ADR 002 step 6 and ADR 007 step 5: the seam where a validated plan
-- actually runs, and stops.
--
-- The interpreter differs from preview and symbolic interpretation in exactly
-- one respect — an effect actually happens. Everything else is shared, which
-- is the point of keeping the plan pure data: the same value that was priced
-- and previewed is the one that executes.
--
-- What is new here is /where/ it stops. Execution is a pure step function over
-- a serializable 'ExecState': it walks until it reaches a tool call, hands
-- back the concrete arguments it is about to use, and goes no further. The
-- caller journals the request, authorizes it, invokes it, and resumes with the
-- outcome. 'executePlan' is that loop, and is now the shortest thing in the
-- module rather than the whole of it.
--
-- The split is what makes a plan resumable. A closure suspended mid-walk
-- cannot survive a restart; a path plus a binding environment can, so a crash
-- between two calls loses the call in flight and nothing else. It is also what
-- makes an approval boundary possible at all: a ceiling declared before
-- elaboration bounds what a plan /may/ ask for, but only a suspension can show
-- what it is actually asking — this query, that recipient, these bytes.
--
-- Three things this module refuses to do, each of which would be easier:
--
--   * __It does not retry.__  Not a rejection, not a failure, and above all not
--     an outcome-unknown.  A plan that re-ran a step whose effect may already
--     have landed would produce exactly the duplicate sends ADR 002's cutover
--     criterion forbids.  Every non-success ends the walk and re-holes.
--   * __It does not re-authorize.__  Validation proved the plan was
--     /admissible/; it never stood in for the checks at the boundary, and this
--     module does not add a second, weaker set.  The suspension exists so that
--     the real one can see concrete arguments.
--   * __It does not repair.__  A result that fails its declared schema stops
--     the walk rather than being coerced, because the binding's type is what
--     every downstream expression was validated against.
--
-- Deoptimization is the normal exit, not the error path. Reaching a hole, a
-- fork, a failing tool, or a spent budget all end the same way: a 'Goal' the
-- caller elaborates again, carrying evidence of what happened.
module Max.Plan.Execute
  ( ExecutionEnv (..),

    -- * Suspendable execution
    ExecState (..),
    initialState,
    PendingCall (..),
    Suspension (..),
    Step (..),
    stepPlan,
    resumeWith,

    -- * Records
    StepRecord (..),
    StepOutcome (..),
    classify,
    Deopt (..),
    deoptText,
    ExecutionEnd (..),
    ExecutionResult (..),

    -- * Driver
    executePlan,
    subplanAt,
    into,
  )
where

import Data.Aeson
  ( FromJSON (..),
    ToJSON (..),
    Value,
    object,
    withObject,
    (.:),
    (.=),
  )
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, (:>))
import Max.Effects.Tools
  ( ToolFault (..),
    ToolOutcome (..),
    ToolRef (..),
    Tools,
    invokeTool,
  )
import Max.Plan.Eval (EvalEnv (..), EvalError, evalErrorText, evalExpr, evalPredicate)
import Max.Plan.Schema (checkValue, schemaErrorText)
import Max.Plan.Types
import Max.Plan.Validate (CatalogEntry (..), ValidPlan, ValidationEnv (..), validPlan)

data ExecutionEnv = ExecutionEnv
  { -- | The same environment the plan was validated against.  Passing a
    -- different one would run a plan no kernel ever admitted.
    exValidation :: !ValidationEnv,
    -- | Bodies for handles the plan may read.
    exHandles :: !(Map Text Value),
    exRoot :: !Text
  }

-- | Where execution is, and everything it has learned.
--
-- Serializable by construction, and that is the whole design: a path is data
-- and a zipper of closures is not. Held against the plan it was taken from —
-- a state whose path no longer exists in the current plan is not silently
-- reinterpreted but reported ('PathNotInPlan'), which is exactly what a steer
-- that rewrote the plan produces.
data ExecState = ExecState
  { esPath :: !PlanPath,
    esBindings :: !(Map Binder Value),
    esCalls :: !Int,
    esSends :: !Int
  }
  deriving stock (Show, Eq)

initialState :: ExecState
initialState =
  ExecState {esPath = PlanPath [], esBindings = Map.empty, esCalls = 0, esSends = 0}

-- | What the plan is about to do, with its arguments already evaluated.
--
-- The concrete form is the point. A declared effect ceiling says a plan may
-- send; only this says to whom, and with what text.
data PendingCall = PendingCall
  { pnNode :: !NodeId,
    pnTool :: !ToolRef,
    pnArguments :: !Value,
    -- | Sends this one call spends, so a caller can report the cost of
    -- allowing it without re-deriving it from the catalog.
    pnSends :: !Int
  }
  deriving stock (Show, Eq)

-- | A stopped walk: what it wants to do, and how to continue once that is
-- decided.
data Suspension = Suspension
  { suCall :: !PendingCall,
    -- | Where the result binds.
    suBind :: !Binder,
    -- | The state to resume from, already past the call and already charged
    -- for it. A refused call is not resumed at all, so the charge never
    -- applies to work that did not happen.
    suNext :: !ExecState
  }
  deriving stock (Show, Eq)

data Step
  = Suspends !Suspension
  | Completes !ExecutionEnd
  deriving stock (Show, Eq)

-- | What one step did, for the journal.
data StepRecord = StepRecord
  { srNode :: !NodeId,
    srTool :: !ToolRef,
    srOutcome :: !StepOutcome
  }
  deriving stock (Show, Eq)

data StepOutcome
  = -- | Ran, and the result matched its declared schema.
    StepSucceeded !Value
  | -- | Ran and committed a visible or durable effect.
    StepCommitted !Value
  | -- | Refused before doing anything.
    StepRejected !Text
  | StepFailed !Text
  | -- | May or may not have taken effect.  Terminal by construction.
    StepOutcomeUnknown !Text
  deriving stock (Show, Eq)

-- | Why the walk stopped short of a result.
data Deopt
  = -- | An unelaborated obligation, which is the ordinary case.
    AtHole !NodeId !Goal
  | -- | An unelaborated obligation whose result binds and whose plan continues.
    AtBind !NodeId !Binder !Goal
  | -- | A set of subgoals to dispatch, each with the name its result binds to.
    --
    -- Reported rather than run.  Dispatching a child means starting a separate
    -- elaboration, waiting on it, and reconciling the plan against whatever the
    -- conversation did meanwhile — a scheduler's job, and this module is an
    -- interpreter.  Stopping here keeps the two apart, and it is the same exit
    -- a hole takes, so the caller already has to handle it.
    AtFork !NodeId !JoinPolicy !WatchPolicy ![(NodeId, Binder, Goal)]
  | -- | A tool did not succeed.
    ToolStopped !NodeId !ToolRef !StepOutcome
  | -- | A tool succeeded and returned something its catalog schema does not
    -- describe.  The catalog is wrong, or the tool is; either way the binding
    -- cannot be trusted.
    ResultOffSchema !NodeId !ToolRef !Text
  | -- | An expression could not be evaluated at run time.  Validation should
    -- have caught this, so it also means the kernel and the evaluator disagree.
    ExpressionFailed !NodeId !EvalError
  | -- | The plan tried to spend past a runtime ceiling.
    BudgetSpent !NodeId !Text
  | -- | A checkpoint taken against a plan this is not.  The ordinary cause is
    -- a steer: the plan was rewritten while this state was in flight, and the
    -- node it was standing on is gone.
    PathNotInPlan !NodeId
  deriving stock (Show, Eq)

deoptText :: Deopt -> Text
deoptText = \case
  AtHole node goal -> node.unNodeId <> ": hole — " <> goal.goalObjective
  AtBind node binder goal ->
    node.unNodeId <> ": hole " <> binder.unBinder <> " — " <> goal.goalObjective
  AtFork node _ _ children ->
    node.unNodeId
      <> ": fork — "
      <> T.intercalate "; " [binder.unBinder <> ": " <> goal.goalObjective | (_, binder, goal) <- children]
  ToolStopped node ref outcome -> node.unNodeId <> ": " <> ref.unToolRef <> " " <> outcomeText outcome
  ResultOffSchema node ref detail ->
    node.unNodeId <> ": " <> ref.unToolRef <> " returned off-schema — " <> detail
  ExpressionFailed node err -> node.unNodeId <> ": " <> evalErrorText err
  BudgetSpent node detail -> node.unNodeId <> ": " <> detail
  PathNotInPlan node -> node.unNodeId <> ": no such node in this plan"

outcomeText :: StepOutcome -> Text
outcomeText = \case
  StepSucceeded _ -> "succeeded"
  StepCommitted _ -> "committed"
  StepRejected detail -> "rejected: " <> detail
  StepFailed detail -> "failed: " <> detail
  StepOutcomeUnknown detail -> "outcome unknown: " <> detail

data ExecutionEnd
  = -- | Reached a 'Done'.  A candidate result: acceptance still has to pass
    -- (see "Max.Plan.Accept") before the goal is complete.
    Produced !Value
  | Deoptimized !Deopt
  deriving stock (Show, Eq)

data ExecutionResult = ExecutionResult
  { erSteps :: ![StepRecord],
    erEnd :: !ExecutionEnd,
    erCallsUsed :: !Int,
    erSendsUsed :: !Int
  }
  deriving stock (Show, Eq)

-- | Walk from where the state stands until something happens that this module
-- may not decide alone.
--
-- Pure. Every branch a guard takes is written into the path rather than
-- recomputed, so resuming after a restart follows the same branch without
-- re-evaluating a predicate over bindings that may have been rebuilt.
stepPlan :: ExecutionEnv -> ValidPlan -> ExecState -> Step
stepPlan env valid state = case subplanAt (validPlan valid) state.esPath of
  Nothing -> Completes (Deoptimized (PathNotInPlan (at state.esPath)))
  Just node -> walk state node
  where
    validation = env.exValidation
    budget = validation.venGoal.goalBudget
    fanout = budget.ebMaxFanout

    at path = nodeIdIn env.exRoot path

    walk here node =
      let this = at here.esPath
          evalEnv =
            EvalEnv {eeBindings = here.esBindings, eeHandles = env.exHandles, eeFanout = fanout}
          stop = Completes . Deoptimized
       in case node of
            Done expr -> case evalExpr evalEnv budget.ebMaxTokens expr of
              Left err -> stop (ExpressionFailed this err)
              Right produced -> Completes (Produced produced)
            Hole hole -> stop (AtHole this hole)
            -- Stops like a hole, and says where the answer goes.  Whoever
            -- fills it produces a value rather than a continuation, so the
            -- plan after this point survives unchanged.
            Bind binder goal _ -> stop (AtBind this binder goal)
            Fork fork _ ->
              stop
                ( AtFork
                    this
                    fork.fnJoin
                    fork.fnWatch
                    [ (at (here.esPath `into` StepChild index), binder, child)
                      | (index, (binder, child)) <- zip [0 ..] fork.fnChildren
                    ]
                )
            -- A pure binding: no tool, no budget, nothing to journal.  It fails
            -- only the way any expression can, which for a validated plan means
            -- the kernel and the evaluator have disagreed.
            Let binder expr continuation -> case evalExpr evalEnv budget.ebMaxTokens expr of
              Left err -> stop (ExpressionFailed this err)
              Right bound ->
                walk
                  here
                    { esPath = here.esPath `into` StepContinue,
                      esBindings = Map.insert binder bound here.esBindings
                    }
                  continuation
            Guard predicate consequent alternative ->
              case evalPredicate evalEnv budget.ebMaxTokens predicate of
                Left err -> stop (ExpressionFailed this err)
                Right True -> walk here {esPath = here.esPath `into` StepThen} consequent
                Right False -> walk here {esPath = here.esPath `into` StepElse} alternative
            Call call _ -> case Map.lookup call.cnTool validation.venCatalog of
              -- Unreachable for a validated plan against the same environment;
              -- treated as a stop rather than a crash.
              Nothing -> stop (ToolStopped this call.cnTool (StepFailed "not in catalog"))
              Just entry
                | here.esCalls >= budget.ebMaxCalls -> stop (BudgetSpent this "call budget spent")
                | here.esSends + sendsOf entry > budget.ebMaxSends ->
                    stop (BudgetSpent this "send budget spent")
                | otherwise -> case evalExpr evalEnv budget.ebMaxTokens call.cnInput of
                    Left err -> stop (ExpressionFailed this err)
                    Right args ->
                      Suspends
                        Suspension
                          { suCall =
                              PendingCall
                                { pnNode = this,
                                  pnTool = call.cnTool,
                                  pnArguments = args,
                                  pnSends = sendsOf entry
                                },
                            suBind = call.cnBind,
                            suNext =
                              here
                                { esPath = here.esPath `into` StepContinue,
                                  esCalls = here.esCalls + 1,
                                  esSends = here.esSends + sendsOf entry
                                }
                          }

-- | Bind a completed call's result and hand back the state to step from.
--
-- The schema check lives here rather than in the caller because the binding's
-- declared type is what every downstream expression was validated against: a
-- result the catalog does not describe is not a value this plan can carry, and
-- coercing it would make the validation a fiction.
resumeWith ::
  ExecutionEnv ->
  Suspension ->
  StepOutcome ->
  Either Deopt ExecState
resumeWith env suspension outcome = case value outcome of
  Nothing -> Left (ToolStopped call.pnNode call.pnTool outcome)
  Just result -> case Map.lookup call.pnTool env.exValidation.venCatalog of
    Nothing -> Left (ToolStopped call.pnNode call.pnTool (StepFailed "not in catalog"))
    Just entry -> case checkValue entry.ceResult result of
      Left mismatch -> Left (ResultOffSchema call.pnNode call.pnTool (schemaErrorText mismatch))
      Right () ->
        Right
          suspension.suNext
            {esBindings = Map.insert suspension.suBind result suspension.suNext.esBindings}
  where
    call = suspension.suCall

    value = \case
      StepSucceeded result -> Just result
      StepCommitted result -> Just result
      _ -> Nothing

-- | Run a validated plan to a result or a deoptimization, invoking each call as
-- the walk reaches it.
--
-- The whole of the effectful half: step, invoke, resume. A caller that needs
-- to journal, authorize, or persist between those does not use this — it uses
-- the three pieces directly, which is the reason they are separate.
executePlan :: Tools :> es => ExecutionEnv -> ValidPlan -> Eff es ExecutionResult
executePlan env valid = go [] initialState
  where
    go steps state = case stepPlan env valid state of
      Completes end -> finish steps end state
      Suspends suspension -> do
        outcome <- classify <$> invokeTool suspension.suCall.pnTool.unToolRef suspension.suCall.pnArguments
        let record =
              StepRecord
                { srNode = suspension.suCall.pnNode,
                  srTool = suspension.suCall.pnTool,
                  srOutcome = outcome
                }
            steps' = record : steps
        case resumeWith env suspension outcome of
          Left deopt -> finish steps' (Deoptimized deopt) suspension.suNext
          Right next -> go steps' next

    finish steps end state =
      pure
        ExecutionResult
          { erSteps = reverse steps,
            erEnd = end,
            erCallsUsed = state.esCalls,
            erSendsUsed = state.esSends
          }

classify :: ToolOutcome -> StepOutcome
classify = \case
  ToolSucceeded value -> StepSucceeded value
  ToolCommitted value -> StepCommitted value
  ToolRejected fault -> StepRejected fault.tfMessage
  ToolFailedBeforeEffect fault -> StepFailed fault.tfMessage
  ToolOutcomeUnknown fault -> StepOutcomeUnknown fault.tfMessage

sendsOf :: CatalogEntry -> Int
sendsOf entry = length [() | EffSend _ <- Set.toList entry.ceEffects]

-- | Descend to the node a path names, or nothing when this plan has no such
-- node.
--
-- Exported because a checkpoint is only meaningful against a plan, and the one
-- thing every reader of a checkpoint has to do first is ask whether the plan it
-- is holding still has that node — which is the same question 'stepPlan' asks
-- and answers with 'PathNotInPlan'.
subplanAt :: Plan -> PlanPath -> Maybe Plan
subplanAt plan path = foldl descend (Just plan) path.unPlanPath
  where
    descend Nothing _ = Nothing
    descend (Just node) step = case (node, step) of
      (Call _ continuation, StepContinue) -> Just continuation
      (Let _ _ continuation, StepContinue) -> Just continuation
      (Fork _ continuation, StepContinue) -> Just continuation
      (Bind _ _ continuation, StepContinue) -> Just continuation
      (Guard _ consequent _, StepThen) -> Just consequent
      (Guard _ _ alternative, StepElse) -> Just alternative
      _ -> Nothing

-- | Extend a path by one step.
into :: PlanPath -> PlanStep -> PlanPath
into path step = PlanPath (path.unPlanPath <> [step])

-- A checkpoint is only a checkpoint if it survives the process.  Bindings
-- encode as a list of pairs rather than an object: a binder is an arbitrary
-- identifier, and a JSON object would quietly merge two that differ only in a
-- way the key type normalizes away.
instance ToJSON ExecState where
  toJSON state =
    object
      [ "path" .= state.esPath,
        "bindings"
          .= [ object ["name" .= binder, "value" .= bound]
               | (binder, bound) <- Map.toAscList state.esBindings
             ],
        "calls" .= state.esCalls,
        "sends" .= state.esSends
      ]

instance FromJSON ExecState where
  parseJSON = withObject "ExecState" $ \o -> do
    bindings <-
      traverse (withObject "binding" (\b -> (,) <$> b .: "name" <*> b .: "value"))
        =<< o .: "bindings"
    ExecState
      <$> o .: "path"
      <*> pure (Map.fromList bindings)
      <*> o .: "calls"
      <*> o .: "sends"

instance ToJSON PendingCall where
  toJSON call =
    object
      [ "node" .= call.pnNode,
        "tool" .= call.pnTool.unToolRef,
        "arguments" .= call.pnArguments,
        "sends" .= call.pnSends
      ]

instance FromJSON PendingCall where
  parseJSON = withObject "PendingCall" $ \o ->
    PendingCall
      <$> o .: "node"
      <*> (ToolRef <$> o .: "tool")
      <*> o .: "arguments"
      <*> o .: "sends"

instance ToJSON Suspension where
  toJSON suspension =
    object
      [ "call" .= suspension.suCall,
        "bind" .= suspension.suBind,
        "next" .= suspension.suNext
      ]

instance FromJSON Suspension where
  parseJSON = withObject "Suspension" $ \o ->
    Suspension <$> o .: "call" <*> o .: "bind" <*> o .: "next"
