-- | The two interpreters that read a plan without running it.
--
-- ADR 002 asks for three interpretations of one 'Plan': the real one calls
-- tools, __preview__ records what it would call without executing, and
-- __symbolic__ propagates result shapes and stops or forks where a value is
-- unknown.  This module is the second and third.  Neither acquires a runner,
-- so neither can accidentally become the first.
--
-- Both take a 'ValidPlan'.  A manifest computed from an unchecked plan would
-- be a description of something that will never run, and showing one to a
-- person about to approve an effect is worse than showing nothing.
--
-- The manifest is an __over-approximation on purpose__.  A guard's branch
-- depends on a result no one has yet, so preview reports both sides and marks
-- them 'Conditional'.  "May send" is weaker than "will send", which is exactly
-- why the distinction is carried explicitly instead of being collapsed: an
-- approval that cannot tell the two apart is an approval for the worse one.
module Max.Plan.Interpret
  ( -- * Preview
    Reachability (..),
    PreviewStep (..),
    EffectManifest (..),
    previewPlan,

    -- * Symbolic interpretation
    Symbolic (..),
    SymbolicError (..),
    Branch (..),
    SymbolicEnd (..),
    SymbolicOutcome (..),
    symbolicPlan,
    maxSymbolicPaths,
  )
where

import Data.Aeson (Value)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Max.Effects.Tools (ToolAuthority, ToolRef (..))
import Max.Plan.Eval
  ( EvalEnv (..),
    EvalError (..),
    defaultCostCeiling,
    evalExpr,
    evalPredicate,
  )
import Max.Plan.Schema (PlanSchema)
import Max.Plan.Types
import Max.Plan.Validate
  ( CatalogEntry (..),
    RejectReason,
    ValidPlan,
    ValidationEnv (..),
    inferExpr,
    validPlan,
  )

-- | Whether a step is on every execution path, or only on some.
data Reachability
  = Certain
  | Conditional
  deriving stock (Show, Eq, Ord)

data PreviewStep = PreviewStep
  { psNode :: !NodeId,
    psTool :: !ToolRef,
    psEffects :: !(Set PlanEffect),
    psAuthorities :: !(Set ToolAuthority),
    psReachability :: !Reachability
  }
  deriving stock (Show, Eq)

-- | The normalized description an approval binds to.
--
-- 'emPlanHash' is what makes the binding meaningful: a residual or deoptimized
-- plan hashes differently and therefore does not inherit the approval.
data EffectManifest = EffectManifest
  { emSteps :: ![PreviewStep],
    emEffects :: !(Set PlanEffect),
    emAuthorities :: !(Set ToolAuthority),
    -- | Worst-path counts, not totals over the tree.
    emMaxCalls :: !Int,
    emMaxSends :: !Int,
    -- | Unelaborated obligations, with the objective each states.  A manifest
    -- over a plan with holes describes only what is decided so far, and saying
    -- so is the difference between an honest preview and a misleading one.
    emHoles :: ![(NodeId, Text)],
    emPlanHash :: !Text
  }
  deriving stock (Show, Eq)

-- | Walk a validated plan, recording what it would do.
--
-- A tool missing from the catalog cannot occur — validation already rejected
-- that — so an unknown ref contributes no effects rather than raising: preview
-- is a reporting path, and failing it would turn a diagnostic into an outage.
previewPlan :: ValidationEnv -> Text -> ValidPlan -> EffectManifest
previewPlan env root valid =
  EffectManifest
    { emSteps = steps,
      emEffects =
        Set.unions
          (map (.psEffects) steps <> [goal.goalBudget.ebEffects | (_, goal) <- holes']),
      emAuthorities =
        Set.unions
          (map (.psAuthorities) steps <> [goal.goalAuthority | (_, goal) <- holes']),
      emMaxCalls = calls,
      emMaxSends = sends,
      emHoles = [(nodeId, goal.goalObjective) | (nodeId, goal) <- holes'],
      emPlanHash = planHash plan
    }
  where
    plan = validPlan valid
    holes' = planHoles root plan
    (steps, calls, sends) = go (PlanPath []) Certain plan

    go path reach node =
      let here = nodeIdIn root path
       in case node of
            Done _ -> ([], 0, 0)
            Call call continuation ->
              let entry = Map.lookup call.cnTool env.venCatalog
                  effects = maybe Set.empty (.ceEffects) entry
                  step =
                    PreviewStep
                      { psNode = here,
                        psTool = call.cnTool,
                        psEffects = effects,
                        psAuthorities = maybe Set.empty (.ceAuthorities) entry,
                        psReachability = reach
                      }
                  (rest, restCalls, restSends) = go (path `into` StepContinue) reach continuation
               in ( step : rest,
                    1 + restCalls,
                    length [() | EffSend _ <- Set.toList effects] + restSends
                  )
            -- A pure binding is invisible to a preview: it invokes nothing, so
            -- there is no step to show and nothing to count.
            Let _ _ continuation -> go (path `into` StepContinue) reach continuation
            -- Both branches are reported; the counts take the worse one,
            -- because a ceiling must cover whichever branch actually runs.
            Guard _ consequent alternative ->
              let (a, aCalls, aSends) = go (path `into` StepThen) Conditional consequent
                  (b, bCalls, bSends) = go (path `into` StepElse) Conditional alternative
               in (a <> b, max aCalls bCalls, max aSends bSends)
            Hole goal -> ([], goal.goalBudget.ebMaxCalls, goal.goalBudget.ebMaxSends)

into :: PlanPath -> PlanStep -> PlanPath
into path step = PlanPath (path.unPlanPath <> [step])

-- | A value during symbolic interpretation: either computable now, or only
-- known by shape.
data Symbolic
  = Known !Value
  | Unknown !PlanSchema
  deriving stock (Show, Eq)

data SymbolicError
  = SymbolicEval !EvalError
  | SymbolicType !RejectReason
  deriving stock (Show, Eq)

-- | Which way a guard went, and whether the interpreter knew or guessed.
data Branch = Branch
  { brNode :: !NodeId,
    brTaken :: !Bool,
    -- | 'False' when the predicate was undecidable and the path forked.
    brDecided :: !Bool
  }
  deriving stock (Show, Eq)

data SymbolicEnd
  = -- | Reached a 'Done' with this result.
    Produces !Symbolic
  | -- | Reached a hole; everything past it depends on an elaboration that has
    -- not happened.
    StopsAtHole !NodeId !Text
  | Fails !NodeId !SymbolicError
  | -- | The path cap was hit before this path finished.
    Truncated !NodeId
  deriving stock (Show, Eq)

data SymbolicOutcome = SymbolicOutcome
  { soBranches :: ![Branch],
    soEnd :: !SymbolicEnd
  }
  deriving stock (Show, Eq)

-- | Forking is exponential in undecided guards, so the walk is capped.  A
-- truncated exploration reports 'Truncated' rather than silently presenting a
-- partial set as complete.
maxSymbolicPaths :: Int
maxSymbolicPaths = 32

-- | Interpret a validated plan over partially known inputs.
--
-- @known@ supplies the bindings and handle bodies that already have values —
-- typically results from earlier in the turn.  Everything else propagates as a
-- shape, and a guard whose predicate cannot be decided forks the walk.
symbolicPlan ::
  ValidationEnv ->
  Text ->
  -- | Handle bodies the host has actually loaded.
  Map Text Value ->
  -- | Bindings already known, by value.
  Map Binder Value ->
  ValidPlan ->
  [SymbolicOutcome]
symbolicPlan env root handles known valid =
  take maxSymbolicPaths (go (PlanPath []) [] known env.venBindings (validPlan valid))
  where
    fanout = env.venGoal.goalBudget.ebMaxFanout

    go path branches values types node =
      let here = nodeIdIn root path
          finish end = [SymbolicOutcome {soBranches = reverse branches, soEnd = end}]
       in case node of
            Done expr -> finish (either (Fails here) Produces (evaluate values types expr))
            Call call continuation ->
              case Map.lookup call.cnTool env.venCatalog of
                -- Unreachable for a validated plan; treated as opaque rather
                -- than as a crash.
                Nothing -> finish (Truncated here)
                Just entry ->
                  -- A call's result is never known without running it, so the
                  -- binding becomes a shape and everything downstream of it
                  -- degrades with it.
                  go
                    (path `into` StepContinue)
                    branches
                    (Map.delete call.cnBind values)
                    (Map.insert call.cnBind (entry.ceResult, entry.ceIntroduces) types)
                    continuation
            -- A pure binding is the one place symbolic interpretation gets to
            -- keep knowing things: if everything the expression reads is known,
            -- so is the result.  It degrades to a shape only when it reads
            -- something a call has already made opaque.
            Let binder expr continuation -> case inferExpr env types fanout expr of
              Left reason -> finish (Fails here (SymbolicType reason))
              Right typed -> case evaluate values types expr of
                Left err -> finish (Fails here err)
                Right resolved ->
                  go
                    (path `into` StepContinue)
                    branches
                    ( case resolved of
                        Known value -> Map.insert binder value values
                        Unknown _ -> Map.delete binder values
                    )
                    (Map.insert binder typed types)
                    continuation
            Guard predicate consequent alternative ->
              case decide values predicate of
                Left err -> finish (Fails here err)
                Right (Just True) ->
                  go (path `into` StepThen) (Branch here True True : branches) values types consequent
                Right (Just False) ->
                  go (path `into` StepElse) (Branch here False True : branches) values types alternative
                Right Nothing ->
                  go (path `into` StepThen) (Branch here True False : branches) values types consequent
                    <> go (path `into` StepElse) (Branch here False False : branches) values types alternative
            Hole goal -> finish (StopsAtHole here goal.goalObjective)

    -- Try the concrete evaluator first; fall back to the shape when it runs
    -- into a name whose value is not available.  For a validated plan an
    -- 'UnboundVariable' or 'UnresolvedHandle' can only mean "typed, but not
    -- known here" — the type environment already proved every name is bound.
    evaluate values types expr =
      case evalExpr (evalEnv values) defaultCostCeiling expr of
        Right value -> Right (Known value)
        Left err
          | opaque err -> shapeOf types expr
          | otherwise -> Left (SymbolicEval err)

    -- A predicate has no shape to fall back to: either it decides, or the walk
    -- forks.  That is the whole "stops or forks on unknown values" rule.
    decide values predicate =
      case evalPredicate (evalEnv values) defaultCostCeiling predicate of
        Right verdict -> Right (Just verdict)
        Left err
          | opaque err -> Right Nothing
          | otherwise -> Left (SymbolicEval err)

    opaque = \case
      UnboundVariable _ -> True
      UnresolvedHandle _ -> True
      _ -> False

    shapeOf types expr =
      case inferExpr env types fanout expr of
        Right (schema, _) -> Right (Unknown schema)
        Left reason -> Left (SymbolicType reason)

    evalEnv values =
      EvalEnv {eeBindings = values, eeHandles = handles, eeFanout = fanout}
