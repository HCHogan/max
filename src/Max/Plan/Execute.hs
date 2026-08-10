-- | ADR 002 step 6: the seam where a validated plan actually runs.
--
-- The real interpreter differs from preview and symbolic interpretation in
-- exactly one respect — it calls 'invokeTool'. Everything else is shared, which
-- is the point of keeping the plan pure data: the same value that was priced
-- and previewed is the one that executes.
--
-- Three things this module refuses to do, each of which would be easier:
--
--   * __It does not retry.__  Not a rejection, not a failure, and above all not
--     an outcome-unknown.  A plan that re-ran a step whose effect may already
--     have landed would produce exactly the duplicate sends ADR 002's cutover
--     criterion forbids.  Every non-success ends the walk and re-holes.
--   * __It does not re-authorize.__  'invokeTool' runs the same scoped host
--     checks the current agent loop uses.  Validation proved the plan was
--     /admissible/; it never stood in for the checks at the boundary, and this
--     module does not add a second, weaker set.
--   * __It does not repair.__  A result that fails its declared schema stops
--     the walk rather than being coerced, because the binding's type is what
--     every downstream expression was validated against.
--
-- Deoptimization is the normal exit, not the error path.  Reaching a hole, a
-- failing tool, or a spent budget all end the same way: a 'Goal' the caller
-- elaborates again, carrying evidence of what happened.
module Max.Plan.Execute
  ( ExecutionEnv (..),
    StepRecord (..),
    StepOutcome (..),
    Deopt (..),
    deoptText,
    ExecutionEnd (..),
    ExecutionResult (..),
    executePlan,
  )
where

import Data.Aeson (Value)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Effectful (Eff, (:>))
import Max.Effects.Tools
  ( ToolFault (..),
    ToolRef (..),
    ToolOutcome (..),
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
  deriving stock (Show, Eq)

deoptText :: Deopt -> Text
deoptText = \case
  AtHole node goal -> node.unNodeId <> ": hole — " <> goal.goalObjective
  ToolStopped node ref outcome -> node.unNodeId <> ": " <> ref.unToolRef <> " " <> outcomeText outcome
  ResultOffSchema node ref detail ->
    node.unNodeId <> ": " <> ref.unToolRef <> " returned off-schema — " <> detail
  ExpressionFailed node err -> node.unNodeId <> ": " <> evalErrorText err
  BudgetSpent node detail -> node.unNodeId <> ": " <> detail

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

-- | Run a validated plan.
executePlan :: Tools :> es => ExecutionEnv -> ValidPlan -> Eff es ExecutionResult
executePlan env valid = go (PlanPath []) Map.empty 0 0 [] (validPlan valid)
  where
    validation = env.exValidation
    goal = validation.venGoal
    budget = goal.goalBudget
    fanout = budget.ebMaxFanout

    finish steps end calls sends =
      pure
        ExecutionResult
          { erSteps = reverse steps,
            erEnd = end,
            erCallsUsed = calls,
            erSendsUsed = sends
          }

    go path bindings calls sends steps node =
      let here = nodeIdIn env.exRoot path
          evalEnv = EvalEnv {eeBindings = bindings, eeHandles = env.exHandles, eeFanout = fanout}
       in case node of
            Done expr -> case evalExpr evalEnv budget.ebMaxTokens expr of
              Left err -> finish steps (Deoptimized (ExpressionFailed here err)) calls sends
              Right produced -> finish steps (Produced produced) calls sends
            Hole hole -> finish steps (Deoptimized (AtHole here hole)) calls sends
            -- A pure binding: no tool, no budget, nothing to journal.  It fails
            -- only the way any expression can, which for a validated plan means
            -- the kernel and the evaluator have disagreed.
            Let binder expr continuation -> case evalExpr evalEnv budget.ebMaxTokens expr of
              Left err -> finish steps (Deoptimized (ExpressionFailed here err)) calls sends
              Right bound ->
                go
                  (path `into` StepContinue)
                  (Map.insert binder bound bindings)
                  calls
                  sends
                  steps
                  continuation
            Guard predicate consequent alternative ->
              case evalPredicate evalEnv budget.ebMaxTokens predicate of
                Left err -> finish steps (Deoptimized (ExpressionFailed here err)) calls sends
                Right True -> go (path `into` StepThen) bindings calls sends steps consequent
                Right False -> go (path `into` StepElse) bindings calls sends steps alternative
            Call call continuation -> case Map.lookup call.cnTool validation.venCatalog of
              -- Unreachable for a validated plan against the same environment;
              -- treated as a stop rather than a crash.
              Nothing ->
                finish steps (Deoptimized (ToolStopped here call.cnTool (StepFailed "not in catalog"))) calls sends
              Just entry
                | calls >= budget.ebMaxCalls ->
                    finish steps (Deoptimized (BudgetSpent here "call budget spent")) calls sends
                | sends + sendsOf entry > budget.ebMaxSends ->
                    finish steps (Deoptimized (BudgetSpent here "send budget spent")) calls sends
                | otherwise -> case evalExpr evalEnv budget.ebMaxTokens call.cnInput of
                    Left err -> finish steps (Deoptimized (ExpressionFailed here err)) calls sends
                    Right args -> do
                      outcome <- invokeTool call.cnTool.unToolRef args
                      let step = StepRecord {srNode = here, srTool = call.cnTool, srOutcome = classify outcome}
                          steps' = step : steps
                          calls' = calls + 1
                          sends' = sends + sendsOf entry
                      case value step.srOutcome of
                        Nothing ->
                          finish steps' (Deoptimized (ToolStopped here call.cnTool step.srOutcome)) calls' sends'
                        Just result -> case checkValue entry.ceResult result of
                          Left mismatch ->
                            finish
                              steps'
                              (Deoptimized (ResultOffSchema here call.cnTool (schemaErrorText mismatch)))
                              calls'
                              sends'
                          Right () ->
                            go
                              (path `into` StepContinue)
                              (Map.insert call.cnBind result bindings)
                              calls'
                              sends'
                              steps'
                              continuation

    sendsOf entry = length [() | EffSend _ <- Set.toList entry.ceEffects]

    value = \case
      StepSucceeded result -> Just result
      StepCommitted result -> Just result
      _ -> Nothing

classify :: ToolOutcome -> StepOutcome
classify = \case
  ToolSucceeded value -> StepSucceeded value
  ToolCommitted value -> StepCommitted value
  ToolRejected fault -> StepRejected fault.tfMessage
  ToolFailedBeforeEffect fault -> StepFailed fault.tfMessage
  ToolOutcomeUnknown fault -> StepOutcomeUnknown fault.tfMessage

into :: PlanPath -> PlanStep -> PlanPath
into path step = PlanPath (path.unPlanPath <> [step])
