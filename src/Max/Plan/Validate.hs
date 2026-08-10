-- | The deterministic kernel boundary ADR 002 puts between untrusted
-- elaboration and execution.
--
-- A language model produces a 'Plan'; nothing downstream may assume it is
-- well-typed, in budget, or even coherent.  'validatePlan' is the only way to
-- obtain a 'ValidPlan', whose constructor is not exported, so "was this
-- checked?" is a question the type system answers rather than a convention the
-- executor is trusted to follow.
--
-- What the kernel does /not/ do is as important as what it does:
--
--   * __It never widens.__  Every check compares the plan against a ceiling the
--     host set — the hole's budget, the live catalog, the resolvable handles.
--     Nothing in the plan can raise its own limit, so an injected instruction
--     can make the model write an arbitrary plan but not one that both exceeds
--     its hole's bounds and passes here.
--   * __It does not replace runtime authorization.__  Passing validation means
--     a plan is admissible, not that its effects are pre-approved; every actual
--     invocation still goes through the same scoped host checks the current
--     agent loop uses.
--   * __It reports one reason.__  The kernel's answer is admit or reject, and
--     the reason is the first thing that made the plan inadmissible.  Chasing
--     an exhaustive diagnosis through an already-broken binding environment
--     produces confident nonsense, which is worse feedback than one true fact.
--
-- Static budget checks stop at what is statically visible.  'ebMaxTokens' and
-- 'ebMaxWallClockMs' are runtime ceilings the executor enforces as it goes;
-- there is nothing to check about them here, and pretending otherwise would
-- claim a guarantee this module cannot make.
module Max.Plan.Validate
  ( -- * Kernel
    ValidPlan,
    validPlan,
    validatePlan,

    -- * What the kernel checks against
    CatalogEntry (..),
    entryFromDefinition,
    VerifierEntry (..),
    ValidationEnv (..),
    childEnv,

    -- * Rejections
    Rejection (..),
    RejectReason (..),
    rejectionText,

    -- * Reusable judgements
    admits,
    inferExpr,
    TypeEnv,
    Usage (..),
  )
where

import Control.Monad (foldM)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Max.Effects.Tools (SchemaVersion (..), ToolAuthority, ToolDefinition (..), ToolRef (..))
import Max.Plan.Eval (exprCost, predicateCost)
import Max.Plan.Schema
  ( PlanSchema (..),
    SchemaError (..),
    SchemaField (..),
    projectField,
    projectIndex,
    renderSchema,
    schemaErrorText,
  )
import Max.Plan.Types

-- | A plan that passed every check in 'validatePlan', against the environment
-- it was checked in.  The constructor stays private: a 'ValidPlan' can only be
-- produced by the kernel.
newtype ValidPlan = ValidPlan Plan
  deriving stock (Show, Eq)

validPlan :: ValidPlan -> Plan
validPlan (ValidPlan plan) = plan

-- | Everything the kernel needs to know about one tool.
--
-- Result schemas and plan-level effects are host-owned declarations rather than
-- anything inferred from the tool's name or its description.  ADR 002 step 2
-- moves them into the catalog proper; until then the caller assembles them,
-- which keeps the decision with the host either way.
data CatalogEntry = CatalogEntry
  { ceRef :: !ToolRef,
    ceSchemaVersion :: !SchemaVersion,
    ceInput :: !PlanSchema,
    ceResult :: !PlanSchema,
    ceEffects :: !(Set PlanEffect),
    ceAuthorities :: !(Set ToolAuthority)
  }
  deriving stock (Show, Eq)

-- | Take the fields the tool catalog already declares, and require the caller
-- to supply only the ones ADR 002 step 2 has yet to add.
entryFromDefinition ::
  ToolDefinition ->
  PlanSchema ->
  PlanSchema ->
  Set PlanEffect ->
  CatalogEntry
entryFromDefinition definition input result effects =
  CatalogEntry
    { ceRef = definition.tdRef,
      ceSchemaVersion = definition.tdSchemaVersion,
      ceInput = input,
      ceResult = result,
      ceEffects = effects,
      ceAuthorities = definition.tdAuthorities
    }

-- | A host-registered acceptance verifier.  A plan names one; it cannot define
-- one, and it cannot select one the enclosing hole did not admit.
data VerifierEntry = VerifierEntry
  { veName :: !Text,
    veVersion :: !Int,
    veAccepts :: !PlanSchema
  }
  deriving stock (Show, Eq)

data ValidationEnv = ValidationEnv
  { venCatalog :: !(Map ToolRef CatalogEntry),
    venVerifiers :: !(Map Text VerifierEntry),
    -- | Result handles the host already resolved and scope-checked.  A handle
    -- absent from this map is unresolvable /for this plan/, which is exactly
    -- what an out-of-scope handle looks like from in here.
    venHandles :: !(Map Text ValueRef),
    -- | Verifier names the enclosing hole permits.
    venAdmittedVerifiers :: !(Set Text),
    -- | The hole this plan fills.  Its budget, authority and expected schema
    -- are the ceilings every check compares against.
    venGoal :: !Goal,
    -- | Bindings already in scope from the enclosing plan.
    venBindings :: !(Map Binder PlanSchema),
    venCostCeiling :: !Int
  }
  deriving stock (Show, Eq)

-- | The world as one subgoal's elaboration sees it.
--
-- A fork child is dispatched with the 'Goal' and nothing else — no conversation,
-- no memory, no sibling.  That isolation is the reason a fork is worth paying
-- for, and it has to be built somewhere; this is where.  Everything narrows and
-- nothing widens, which makes the projection idempotent and makes a child of a
-- child strictly poorer than its parent without anyone tracking depth.
--
-- Three narrowings, each for a different reason:
--
--   * __Bindings to 'goalInputs'.__  The parent holds many names; the child asked
--     for some.  The host resolves exactly those to values when it dispatches, so
--     anything else would name a value the child was never handed.
--   * __Handles to 'goalResources'.__  Same argument one level out: the front
--     model chose what is relevant, and choosing is what having the conversation
--     is for.
--   * __Catalog to what this goal's budget and authority admit.__  Unlike the
--     other two this is not a correctness requirement — 'validatePlan' rejects an
--     over-effectful call anyway.  It is the same courtesy 'Max.Plan.Prompt'
--     already extends to released handles: a tool listed here would be a
--     guaranteed rejection advertised as an option, and a model that reaches for
--     it has been misled rather than caught.
--
-- The cost ceiling, the verifier registry and the admitted set carry over
-- unchanged: those are host policy, not the parent's to spend.
childEnv :: ValidationEnv -> Goal -> ValidationEnv
childEnv parent goal =
  parent
    { venGoal = goal,
      venBindings = Map.restrictKeys parent.venBindings (Set.fromList goal.goalInputs),
      venHandles = Map.restrictKeys parent.venHandles (Set.fromList goal.goalResources),
      venCatalog = Map.filter reachable parent.venCatalog
    }
  where
    reachable entry =
      Set.isSubsetOf entry.ceEffects goal.goalBudget.ebEffects
        && Set.isSubsetOf entry.ceAuthorities goal.goalAuthority

data Rejection = Rejection
  { rjNode :: !NodeId,
    rjReason :: !RejectReason
  }
  deriving stock (Show, Eq)

data RejectReason
  = UnknownTool !ToolRef
  | -- | Catalog version, then the version the plan was written against.
    ToolSchemaDrift !ToolRef !Int !Int
  | ArgumentSchema !ToolRef !Text
  | -- | A binder that would shadow a name already in scope.
    ShadowedBinding !Binder
  | UnboundName !Binder
  | -- | Out of scope, or never a handle at all.
    UnresolvableHandle !Text
  | -- | In scope, but retention already released the body.
    ReleasedHandle !Text
  | -- | Expected, then actual.
    ExpressionType !Text !Text
  | -- | An empty literal collection in a position with no expected type.
    AmbiguousEmptyCollection
  | EffectNotPermitted !PlanEffect
  | AuthorityNotPermitted !ToolAuthority
  | -- | Ceiling, then what the plan would spend.
    CallBudgetExceeded !Int !Int
  | SendBudgetExceeded !Int !Int
  | -- | Static cost ceiling, then the priced cost.
    CostCeilingExceeded !Int !Integer
  | -- | Verifier name, what it accepts, what the goal produces.  A gate that
    -- cannot read the value it is gating is not a gate.
    VerifierSchemaMismatch !Text !Text !Text
  | UnknownVerifier !Text
  | -- | Registry version, then the version the plan named.
    VerifierVersionDrift !Text !Int !Int
  | VerifierNotAdmitted !Text
  | -- | A hole asking for more than the hole it sits inside.
    BudgetNotNarrowing !Text
  | -- | A fork whose children, added up, ask for more than the plan has.  What
    -- is spent, then the ceiling, then the sum.
    ForkBudgetExceeded !Text !Int !Int
  | -- | A fork that opens no subgoals: nothing to elaborate, nothing bound.
    EmptyFork
  | -- | A field only the host may write, written by the plan.
    HostOnlyField !Text
  deriving stock (Show, Eq)

rejectionText :: Rejection -> Text
rejectionText rejection =
  rejection.rjNode.unNodeId <> ": " <> reasonText rejection.rjReason

reasonText :: RejectReason -> Text
reasonText = \case
  UnknownTool ref -> "no tool named " <> ref.unToolRef
  ToolSchemaDrift ref catalog written ->
    ref.unToolRef <> " is at schema version " <> tshow catalog <> ", plan was written against " <> tshow written
  ArgumentSchema ref detail -> "arguments to " <> ref.unToolRef <> ": " <> detail
  ShadowedBinding binder -> binder.unBinder <> " is already bound"
  UnboundName binder -> "unbound name " <> binder.unBinder
  UnresolvableHandle handle -> handle <> " does not resolve in this scope"
  ReleasedHandle handle -> handle <> " is no longer retained"
  ExpressionType expected actual -> "expected " <> expected <> ", got " <> actual
  AmbiguousEmptyCollection -> "an empty collection needs an expected type here"
  EffectNotPermitted effect -> "effect " <> effectText effect <> " is outside this goal's budget"
  AuthorityNotPermitted authority -> "authority " <> tshow authority <> " is outside this goal's grant"
  CallBudgetExceeded limit spend ->
    "plan makes " <> tshow spend <> " calls, budget allows " <> tshow limit
  SendBudgetExceeded limit spend ->
    "plan makes " <> tshow spend <> " sends, budget allows " <> tshow limit
  CostCeilingExceeded limit cost ->
    "expression prices at " <> tshow cost <> ", ceiling is " <> tshow limit
  VerifierSchemaMismatch name accepts produced ->
    name <> " accepts " <> accepts <> ", but the goal produces " <> produced
  UnknownVerifier name -> "no verifier named " <> name
  VerifierVersionDrift name registry named ->
    name <> " is at version " <> tshow registry <> ", plan named " <> tshow named
  VerifierNotAdmitted name -> name <> " is not admitted by the enclosing goal"
  BudgetNotNarrowing detail -> "child goal widens its parent: " <> detail
  ForkBudgetExceeded what limit total ->
    "the subgoals of one fork ask for "
      <> tshow total
      <> " "
      <> what
      <> " between them, budget allows "
      <> tshow limit
  EmptyFork -> "a fork with no subgoals"
  HostOnlyField name -> name <> " is written by the host, not by the plan"

effectText :: PlanEffect -> Text
effectText = \case
  EffRead scope -> "read " <> scopeText scope
  EffWrite scope -> "write " <> scopeText scope
  EffSend AudienceConversation -> "send to the conversation"
  EffSend AudienceSender -> "send to the sender"
  EffLLM -> "llm"
  EffReflect namespace -> "reflect " <> namespace

scopeText :: ResourceScope -> Text
scopeText = \case
  CurrentConversation -> "the current conversation"
  SandboxScope handle -> "sandbox " <> handle
  ProcessScope name -> "process " <> name
  ExternalScope origin -> "external " <> origin

-- | What one execution path through a plan may consume.  Sequential
-- composition sums; alternatives take the worse of the two, because a ceiling
-- must cover whichever branch actually runs.
data Usage = Usage
  { usEffects :: !(Set PlanEffect),
    usCalls :: !Int,
    usSends :: !Int
  }
  deriving stock (Show, Eq)

instance Semigroup Usage where
  left <> right =
    Usage
      { usEffects = Set.union left.usEffects right.usEffects,
        usCalls = left.usCalls + right.usCalls,
        usSends = left.usSends + right.usSends
      }

instance Monoid Usage where
  mempty = Usage {usEffects = Set.empty, usCalls = 0, usSends = 0}

worseOf :: Usage -> Usage -> Usage
worseOf left right =
  Usage
    { usEffects = Set.union left.usEffects right.usEffects,
      usCalls = max left.usCalls right.usCalls,
      usSends = max left.usSends right.usSends
    }

-- | What each name in scope is.
type TypeEnv = Map Binder PlanSchema

-- | Admit or reject, with the first reason the plan was inadmissible.
validatePlan :: ValidationEnv -> Text -> Plan -> Either Rejection ValidPlan
validatePlan env root plan = do
  usage <- walk (PlanPath []) env.venBindings plan
  let budget = env.venGoal.goalBudget
      at = Rejection (nodeIdIn root (PlanPath []))
  mapM_
    (\effect -> failIf (not (Set.member effect budget.ebEffects)) (at (EffectNotPermitted effect)))
    (Set.toList usage.usEffects)
  failIf (usage.usCalls > budget.ebMaxCalls) (at (CallBudgetExceeded budget.ebMaxCalls usage.usCalls))
  failIf (usage.usSends > budget.ebMaxSends) (at (SendBudgetExceeded budget.ebMaxSends usage.usSends))
  pure (ValidPlan plan)
  where
    fanout = env.venGoal.goalBudget.ebMaxFanout

    walk path bindings node =
      let here = nodeIdIn root path
          at = Rejection here
       in case node of
            Done expr -> do
              first at (check env bindings fanout env.venGoal.goalExpected expr)
              priceExpr at expr
              pure mempty
            -- A pure binding.  No effect, no call, no send — so nothing is
            -- checked here beyond what any expression is checked for: that it
            -- types, that it prices, and that it does not reuse a name.
            Let binder expr continuation -> do
              schema <- first at (infer env bindings fanout expr)
              priceExpr at expr
              failIf (Map.member binder bindings) (at (ShadowedBinding binder))
              walk (extend path StepContinue) (Map.insert binder schema bindings) continuation
            Call call continuation -> do
              entry <- maybe (Left (at (UnknownTool call.cnTool))) Right (Map.lookup call.cnTool env.venCatalog)
              failIf
                (entry.ceSchemaVersion /= call.cnSchemaVersion)
                (at (ToolSchemaDrift call.cnTool entry.ceSchemaVersion.unSchemaVersion call.cnSchemaVersion.unSchemaVersion))
              first
                (\reason -> at (ArgumentSchema call.cnTool (reasonText reason)))
                (check env bindings fanout entry.ceInput call.cnInput)
              priceExpr at call.cnInput
              mapM_
                (\authority -> failIf (not (Set.member authority env.venGoal.goalAuthority)) (at (AuthorityNotPermitted authority)))
                (Set.toList entry.ceAuthorities)
              failIf (Map.member call.cnBind bindings) (at (ShadowedBinding call.cnBind))
              let bound = Map.insert call.cnBind entry.ceResult bindings
                  here' =
                    Usage
                      { usEffects = entry.ceEffects,
                        usCalls = 1,
                        usSends = length [() | EffSend _ <- Set.toList entry.ceEffects]
                      }
              rest <- walk (extend path StepContinue) bound continuation
              pure (here' <> rest)
            -- A fork is where the one arithmetic fact a static kernel can
            -- usefully know about this language lives: a set of subgoals opened
            -- together spends the sum of what they were each granted, not the
            -- maximum.  Alternatives take the worse branch because only one
            -- runs; siblings all run.  Without this a plan could hand itself
            -- three times its budget by asking for it three times.
            --
            -- The sum lands in 'Usage' as well, so the root check catches a
            -- fork that fits on its own but not alongside the calls around it.
            -- The check here is the local, legible one: it names the fork.
            Fork fork continuation -> do
              failIf (null fork.fnChildren) (at EmptyFork)
              bound <-
                foldM
                  ( \scope (index, (binder, goal)) -> do
                      let childAt = Rejection (nodeIdIn root (extend path (StepChild index)))
                      narrows childAt goal
                      -- Against the scope at the fork, deliberately not the
                      -- accumulating one: a child asking for a sibling's name
                      -- is asking for a value that will not exist when it
                      -- starts, and independence is only structural if it is
                      -- also inexpressible.
                      inputsInScope childAt bindings goal
                      mapM_ (verifier childAt goal) goal.goalAcceptance
                      -- Against the accumulating scope, so one sibling cannot
                      -- take a name another sibling or an outer binding holds.
                      failIf (Map.member binder scope) (childAt (ShadowedBinding binder))
                      pure (Map.insert binder goal.goalExpected scope)
                  )
                  bindings
                  (zip [0 :: Int ..] fork.fnChildren)
              let budgets = [goal.goalBudget | (_, goal) <- fork.fnChildren]
                  parent = env.venGoal.goalBudget
                  spent =
                    Usage
                      { usEffects = Set.unions (map (.ebEffects) budgets),
                        usCalls = sum (map (.ebMaxCalls) budgets),
                        usSends = sum (map (.ebMaxSends) budgets)
                      }
              failIf
                (spent.usCalls > parent.ebMaxCalls)
                (at (ForkBudgetExceeded "calls" parent.ebMaxCalls spent.usCalls))
              failIf
                (spent.usSends > parent.ebMaxSends)
                (at (ForkBudgetExceeded "sends" parent.ebMaxSends spent.usSends))
              rest <- walk (extend path StepContinue) bound continuation
              pure (spent <> rest)
            Guard predicate consequent alternative -> do
              first at (checkPredicate env bindings fanout predicate)
              pricePredicate at predicate
              taken <- walk (extend path StepThen) bindings consequent
              other <- walk (extend path StepElse) bindings alternative
              pure (worseOf taken other)
            -- A goal named mid-plan.  Priced exactly as a hole is — its whole
            -- budget counts against this one — and then the plan carries on,
            -- so the continuation is checked against the type it declared.
            -- That declared type is the only thing making the rest of the plan
            -- checkable before this goal has been filled.
            Bind binder goal continuation -> do
              narrows at goal
              inputsInScope at bindings goal
              mapM_ (verifier at goal) goal.goalAcceptance
              failIf (Map.member binder bindings) (at (ShadowedBinding binder))
              rest <-
                walk
                  (extend path StepContinue)
                  (Map.insert binder goal.goalExpected bindings)
                  continuation
              pure (budgetUsage goal <> rest)
            Hole goal -> do
              narrows at goal
              inputsInScope at bindings goal
              mapM_ (verifier at goal) goal.goalAcceptance
              -- A hole's own budget is what its later elaboration may spend,
              -- so it counts against this one in full.
              pure (budgetUsage goal)

    priceExpr at expr =
      let cost = exprCost fanout expr
       in failIf (cost > fromIntegral env.venCostCeiling) (at (CostCeilingExceeded env.venCostCeiling cost))

    pricePredicate at predicate =
      let cost = predicateCost fanout predicate
       in failIf (cost > fromIntegral env.venCostCeiling) (at (CostCeilingExceeded env.venCostCeiling cost))

    -- A child goal may narrow its parent in every dimension and widen it in
    -- none.  Without this a plan could hand itself a bigger budget simply by
    -- wrapping the rest of its work in a hole.
    narrows at goal = do
      let parent = env.venGoal.goalBudget
          child = goal.goalBudget
      -- Evidence and the attempt counter are the host's record of what already
      -- went wrong.  A plan that could write them could launder a failed
      -- attempt into a fresh one.
      failIf (not (null goal.goalEvidence)) (at (HostOnlyField "evidence"))
      failIf (goal.goalAttempt /= 0) (at (HostOnlyField "attempt"))
      failIf
        (not (Set.isSubsetOf child.ebEffects parent.ebEffects))
        (at (BudgetNotNarrowing "effects"))
      failIf (child.ebMaxCalls > parent.ebMaxCalls) (at (BudgetNotNarrowing "calls"))
      failIf (child.ebMaxSends > parent.ebMaxSends) (at (BudgetNotNarrowing "sends"))
      failIf (child.ebMaxFanout > parent.ebMaxFanout) (at (BudgetNotNarrowing "fanout"))
      failIf (child.ebMaxTokens > parent.ebMaxTokens) (at (BudgetNotNarrowing "tokens"))
      failIf (child.ebMaxWallClockMs > parent.ebMaxWallClockMs) (at (BudgetNotNarrowing "wall clock"))
      failIf
        (not (Set.isSubsetOf goal.goalAuthority env.venGoal.goalAuthority))
        (at (BudgetNotNarrowing "authority"))
      -- A child is handed addresses, and only ones this plan can already
      -- resolve.  Nothing widens: a handle absent from 'venHandles' is out of
      -- scope here, so passing it on is inexpressible rather than forbidden.
      mapM_ (resource at) goal.goalResources

    resource at handle = case Map.lookup handle env.venHandles of
      Nothing -> Left (at (UnresolvableHandle handle))
      Just ref -> failIf (not ref.vrRetained) (at (ReleasedHandle handle))

    -- A goal may ask for bindings the enclosing plan actually holds, and for
    -- no others.  The host resolves each to its value when it dispatches; a
    -- name that is not in scope here would have nothing to resolve to, which
    -- is an unbound name however far away it is eventually read.
    inputsInScope at bindings goal =
      mapM_
        (\binder -> failIf (not (Map.member binder bindings)) (at (UnboundName binder)))
        goal.goalInputs

    verifier at goal ref = do
      failIf (not (Set.member ref.verName env.venAdmittedVerifiers)) (at (VerifierNotAdmitted ref.verName))
      entry <- maybe (Left (at (UnknownVerifier ref.verName))) Right (Map.lookup ref.verName env.venVerifiers)
      failIf
        (entry.veVersion /= ref.verVersion)
        (at (VerifierVersionDrift ref.verName entry.veVersion ref.verVersion))
      -- The gate has to be able to read what it is gating.  Checked against
      -- the hole's own expected schema, since that is the value the verifier
      -- will be handed once the hole is filled.
      failIf
        (not (admits entry.veAccepts goal.goalExpected))
        (at (VerifierSchemaMismatch ref.verName (renderSchema entry.veAccepts) (renderSchema goal.goalExpected)))

-- | What a goal's later elaboration is allowed to spend, charged to the plan
-- that opened it.  A hole and a mid-plan binding are priced identically: both
-- are one elaboration this plan has already committed to paying for.
budgetUsage :: Goal -> Usage
budgetUsage goal =
  Usage
    { usEffects = goal.goalBudget.ebEffects,
      usCalls = goal.goalBudget.ebMaxCalls,
      usSends = goal.goalBudget.ebMaxSends
    }

extend :: PlanPath -> PlanStep -> PlanPath
extend path step = PlanPath (path.unPlanPath <> [step])

failIf :: Bool -> Rejection -> Either Rejection ()
failIf condition rejection = if condition then Left rejection else Right ()

first :: (a -> b) -> Either a c -> Either b c
first f = either (Left . f) Right

-- | Is a value of the second schema acceptable where the first is expected?
--
-- The relation is ordinary width-and-depth subtyping with two widenings max's
-- data actually needs — an enum is text, an int is a number — and one
-- deliberate refusal: a nullable value never satisfies a non-nullable
-- expectation.  Objects stay closed in both directions, so an extra field is a
-- mismatch rather than a tolerated superset.
admits :: PlanSchema -> PlanSchema -> Bool
admits expected actual = case (expected, actual) of
  (SchemaNullable inner, SchemaNullable found) -> admits inner found
  (SchemaNullable inner, found) -> admits inner found
  (_, SchemaNullable _) -> False
  (SchemaText, SchemaEnum _) -> True
  (SchemaNumber, SchemaInt) -> True
  (SchemaArray inner, SchemaArray found) -> admits inner found
  (SchemaObject wanted, SchemaObject found) ->
    let names = map (.sfName) wanted
        foundNames = map (.sfName) found
        lookupField name fields = case filter ((== name) . (.sfName)) fields of
          field : _ -> Just field
          [] -> Nothing
     in all (`elem` names) foundNames
          && all
            ( \want -> case lookupField want.sfName found of
                Nothing -> False
                Just got -> admits want.sfSchema got.sfSchema && (not want.sfRequired || got.sfRequired)
            )
            wanted
  _ -> expected == actual

-- | Checking direction: an expected schema is pushed into the expression.
-- Only the forms that genuinely need it consume the expectation; everything
-- else synthesizes and is compared with 'admits'.
check :: ValidationEnv -> TypeEnv -> Int -> PlanSchema -> Expr -> Either RejectReason ()
check env bindings fanout expected expr = case (expected, expr) of
  (_, ELit LitNull) ->
    case expected of
      SchemaNullable _ -> Right ()
      _ -> Left (ExpressionType (renderSchema expected) "null")
  (SchemaArray element, EArray items) ->
    mapM_ (check env bindings fanout element) items
  (SchemaObject fields, EObject members) -> do
    let declared = map (.sfName) fields
        supplied = map fst members
    mapM_
      ( \field ->
          if field.sfRequired && field.sfName `notElem` supplied
            then Left (ExpressionType (renderSchema expected) ("object without " <> field.sfName))
            else Right ()
      )
      fields
    mapM_
      ( \name ->
          if name `elem` declared
            then Right ()
            else Left (ExpressionType (renderSchema expected) ("object with unknown field " <> name))
      )
      supplied
    mapM_
      ( \(name, value) -> case filter ((== name) . (.sfName)) fields of
          field : _ -> check env bindings fanout field.sfSchema value
          [] -> Left (ExpressionType (renderSchema expected) ("object with unknown field " <> name))
      )
      members
  (_, EIf condition consequent alternative) -> do
    checkPredicate env bindings fanout condition
    check env bindings fanout expected consequent
    check env bindings fanout expected alternative
  (_, ECoalesce primary fallback) -> do
    -- The primary may be null; the fallback must satisfy the expectation on
    -- its own, which is what makes the whole expression non-nullable.
    check env bindings fanout (nullableOf expected) primary
    check env bindings fanout expected fallback
  _ -> do
    actual <- infer env bindings fanout expr
    if admits expected actual
      then Right ()
      else Left (ExpressionType (renderSchema expected) (renderSchema actual))
  where
    nullableOf = \case
      already@(SchemaNullable _) -> already
      inner -> SchemaNullable inner

-- | Synthesis direction.  Exported as 'inferExpr' for the interpreters, which
-- need an expression's shape in exactly the cases where its value is unknown.
infer :: ValidationEnv -> TypeEnv -> Int -> Expr -> Either RejectReason PlanSchema
infer env bindings fanout = go
  where
    go = \case
      ELit lit -> case lit of
        LitText _ -> Right SchemaText
        LitInt _ -> Right SchemaInt
        LitNumber _ -> Right SchemaNumber
        LitBool _ -> Right SchemaBool
        LitNull -> Left AmbiguousEmptyCollection
      EVar binder -> maybe (Left (UnboundName binder)) Right (Map.lookup binder bindings)
      EHandle handle -> case Map.lookup handle env.venHandles of
        Nothing -> Left (UnresolvableHandle handle)
        Just ref
          | not ref.vrRetained -> Left (ReleasedHandle handle)
          | otherwise -> Right ref.vrSchema
      EField source name -> do
        schema <- go source
        schemaStep (projectField name schema)
      EIndex source index -> do
        _ <- if index < 0 then Left (ExpressionType "a non-negative index" (tshow index)) else Right ()
        schema <- go source
        schemaStep (projectIndex schema)
      EArray [] -> Left AmbiguousEmptyCollection
      EArray (first' : rest) -> do
        element <- go first'
        mapM_ (check env bindings fanout element) rest
        pure (SchemaArray element)
      EObject members -> do
        typed <- traverse (\(name, value) -> (name,) <$> go value) members
        pure
          ( SchemaObject
              [ SchemaField {sfName = name, sfSchema = schema, sfRequired = True}
                | (name, schema) <- typed
              ]
          )
      EConcat parts -> do
        mapM_ (check env bindings fanout SchemaText) parts
        pure SchemaText
      ELength source ->
        go source >>= \case
          SchemaArray _ -> Right SchemaInt
          SchemaText -> Right SchemaInt
          SchemaEnum _ -> Right SchemaInt
          other -> Left (ExpressionType "array or text" (renderSchema other))
      ETake count source -> do
        _ <- if count < 0 then Left (ExpressionType "a non-negative count" (tshow count)) else Right ()
        go source >>= \case
          array@(SchemaArray _) -> Right array
          other -> Left (ExpressionType "array" (renderSchema other))
      EMap binder source body -> do
        element <- elementOf =<< go source
        inner <- bindOne binder element
        SchemaArray <$> infer env inner fanout body
      EFilter binder source keep -> do
        element <- elementOf =<< go source
        inner <- bindOne binder element
        checkPredicate env inner fanout keep
        pure (SchemaArray element)
      EIf condition consequent alternative -> do
        checkPredicate env bindings fanout condition
        schema <- go consequent
        check env bindings fanout schema alternative
        pure schema
      ECoalesce primary fallback -> do
        schema <- go primary
        let stripped = case schema of
              SchemaNullable inner -> inner
              inner -> inner
        check env bindings fanout stripped fallback
        pure stripped

    elementOf = \case
      SchemaArray element -> Right element
      other -> Left (ExpressionType "array" (renderSchema other))

    bindOne binder schema
      | Map.member binder bindings = Left (ShadowedBinding binder)
      | otherwise = Right (Map.insert binder schema bindings)

    schemaStep = either (Left . fromSchemaError) Right

checkPredicate :: ValidationEnv -> TypeEnv -> Int -> Predicate -> Either RejectReason ()
checkPredicate env bindings fanout = go bindings
  where
    go scope = \case
      PBool _ -> Right ()
      PNot inner -> go scope inner
      PAnd parts -> mapM_ (go scope) parts
      POr parts -> mapM_ (go scope) parts
      PIsNull source -> () <$ infer env scope fanout source
      PCompare op left right -> do
        leftSchema <- infer env scope fanout left
        rightSchema <- infer env scope fanout right
        comparable op leftSchema rightSchema
      PAll binder source body -> quantify scope binder source body
      PAny binder source body -> quantify scope binder source body

    quantify scope binder source body = do
      element <-
        infer env scope fanout source >>= \case
          SchemaArray inner -> Right inner
          other -> Left (ExpressionType "array" (renderSchema other))
      if Map.member binder scope
        then Left (ShadowedBinding binder)
        else go (Map.insert binder element scope) body

    -- Comparison is where a loose type system usually leaks: @"3" < 4@ has to
    -- be a rejection, not a coincidence about how two values happen to encode.
    comparable op left right = case op of
      OpEq -> same
      OpNe -> same
      OpContains -> case (left, right) of
        (SchemaText, SchemaText) -> Right ()
        (SchemaArray element, found) | admits element found -> Right ()
        _ -> Left (ExpressionType "text in text, or a value in an array of it" (pair left right))
      OpPrefix -> texts
      OpSuffix -> texts
      _ ->
        if (numeric left && numeric right) || (textual left && textual right)
          then Right ()
          else Left (ExpressionType "two numbers or two texts" (pair left right))
      where
        same =
          if admits left right || admits right left
            then Right ()
            else Left (ExpressionType "two comparable values" (pair left right))
        texts =
          if textual left && textual right
            then Right ()
            else Left (ExpressionType "two texts" (pair left right))

    numeric = \case
      SchemaInt -> True
      SchemaNumber -> True
      _ -> False

    textual = \case
      SchemaText -> True
      SchemaEnum _ -> True
      _ -> False

    pair left right = renderSchema left <> " and " <> renderSchema right

fromSchemaError :: SchemaError -> RejectReason
fromSchemaError err = ExpressionType err.schExpected (schemaErrorText err)

tshow :: Show a => a -> Text
tshow = T.pack . show

-- | See 'infer'.
inferExpr :: ValidationEnv -> TypeEnv -> Int -> Expr -> Either RejectReason PlanSchema
inferExpr = infer
