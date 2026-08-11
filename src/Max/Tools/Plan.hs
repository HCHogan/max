-- | The front model's way into the plan kernel: state an objective, read the
-- dialect, submit a plan, get its result.
--
-- ADR 007 §9 and §10.  Two commitments show up in the shape of this module.
--
-- __Nobody decides for the model whether a turn deserves a plan.__  There is no
-- host heuristic and no classifier; there is a tool, and the model calls it when
-- it judges the work worth planning.  Models already write plans unprompted
-- before hard tasks, so the signal exists — asking something cheap to guess at
-- what the expensive model already knows is the mistake §8 deleted, and it does
-- not improve by being made about plans instead of about messages.  Never
-- calling these is exactly today's behaviour, which is what makes them safe to
-- ship.
--
-- __The guide arrives on demand.__  It is roughly four thousand tokens and
-- cannot ride in every turn's tool list; @plan_guide@ costs one round trip, paid
-- only by turns that plan.  The same progressive disclosure @use_skill@ uses,
-- for the same reason.
--
-- __A plan runs in a catalog containing only plannable tools.__  Not a
-- restriction bolted on: 'runTools' is re-interpreted over the plannable subset,
-- so a plan calling anything else fails at the same place an invented tool name
-- would.  It also makes @plan_run@ structurally unable to invoke itself, since
-- the subset never contains it — no recursion guard needed, because there is no
-- recursion to guard.
--
-- __A fork parks the plan rather than ending it.__  §11.  The walk stops at the
-- fork either way — an interpreter cannot start a turn — but where it used to
-- report a stop and lose everything it had computed, it now writes the
-- execution state down against the plan it was walking and hands the fork to
-- whoever drives suspended plans.  The turn goes on and the model replies; the
-- plan wakes later, in a turn of its own.
--
-- Without a durable plan there is nothing to park against, and a fork degrades
-- to exactly the old behaviour: reported as a stop, work already done reported
-- with it.  That is the honest answer for a dispatch that has no turn rather
-- than a degraded one.
--
-- What is still deliberately not here: holes are reported rather than
-- elaborated.  Filling one is the front model's own next step, and it is
-- already the front model's turn.
module Max.Tools.Plan
  ( planToolsFor,
    PlanJournal (..),
    durablePlanJournal,
    planGoalFor,
    planValidationEnv,
  )
where

import Data.Aeson
import Data.Aeson.Types (Pair, parseEither)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Control.Exception (SomeException)
import Effectful
import Effectful.Log (Log, logAttention, logInfo)
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Plan (PlanId (..), PlanRef (..), Revision (..), openPlan, suspendPlan)
import Max.Effects.Tools
  ( Tool (..),
    ToolCatalog,
    ToolDefinition (..),
    ToolRef (..),
    buildToolCatalog,
    runTools,
  )
import Max.Effects.Tools qualified as Tools
import Max.Plan.Catalog (planCatalog)
import Max.Plan.Execute
  ( Deopt (..),
    ExecutionEnd (..),
    ExecutionEnv (..),
    ExecutionResult (..),
    StepRecord (..),
    deoptText,
    executePlan,
  )
import Max.Plan.Parse (parseFailureText, parsePlan)
import Max.Plan.Prompt (frontPrompt)
import Max.Plan.Schema (PlanSchema (..))
import Max.Plan.Types
import Max.Plan.Validate (CatalogEntry (..), ValidationEnv (..), rejectionText, validatePlan)
import Max.ToolContext (ToolContext, toolTurnOutputContext)
import Max.Tools.Schema (stringParam, toolObject)
import Max.Turn.Types (turnOutputAgentTurn)
import Max.Util (catchSync)

-- | Both runners, built against the tools this dispatch actually got.
--
-- Visibility is not decided here: @plan_guide@ and @plan_run@ sit in
-- "Max.Toolset"'s inventory like every other tool, so the same gates and the
-- same 'toolAllowedByEffectCeiling' narrowing apply to them.  Deciding it here
-- as well would put the two in a position to disagree, and the failure mode of
-- disagreeing is a catalog that refuses the whole dispatch.
--
-- The sub-catalog is the plannable subset of what the caller already built.  A
-- plan therefore reaches exactly the tools the host resolved for this turn, at
-- the same effect row, through the same 'runTools' — and cannot reach
-- @plan_run@, because the subset never contains it.
planToolsFor ::
  Log :> es =>
  PlanJournal es ->
  [ToolDefinition] ->
  [Tool es] ->
  [Tool es]
planToolsFor journal definitions runners =
  case subCatalog of
    -- Unreachable in practice: the subset is a filter of an already-valid
    -- catalog.  Dropping both tools is still the right answer to it — better a
    -- turn with no planning than a turn whose plan tool holds a broken catalog.
    Left _ -> []
    Right built -> [guideTool catalog, runTool journal catalog built]
  where
    catalog = planCatalog definitions
    plannable = Map.keysSet catalog
    subCatalog =
      buildToolCatalog
        [d | d <- definitions, Set.member d.tdRef plannable]
        [r | r <- runners, Set.member (ToolRef r.toolName) plannable]

-- | The ceiling a front-of-house plan runs under.
--
-- Host-set, as every budget in this design is.  @sends: 0@ is not caution about
-- what a plan might say — no plannable tool can send at all — but it keeps the
-- kernel's arithmetic agreeing with that fact instead of merely coinciding with
-- it, so the day a sending tool becomes plannable the ceiling has to be raised
-- deliberately.
--
-- Effects are the union of what the plannable catalog declares, because a
-- ceiling narrower than the tools it admits would reject plans for calling
-- exactly the tools it advertised.
planGoalFor :: Map ToolRef CatalogEntry -> Text -> Goal
planGoalFor catalog objective =
  Goal
    { goalObjective = objective,
      -- Text, because the plan's result comes back to a model that is about to
      -- write a reply.  A richer type would only be projected into prose here.
      goalExpected = SchemaText,
      goalAcceptance = [],
      goalBudget =
        EffectBudget
          { ebEffects = Set.unions [entry.ceEffects | entry <- Map.elems catalog],
            ebMaxCalls = 4,
            ebMaxSends = 0,
            ebMaxFanout = 16,
            ebMaxTokens = 8000,
            ebMaxWallClockMs = 60000
          },
      goalAuthority = Set.singleton Tools.CurrentConversation,
      goalResources = [],
      goalInputs = [],
      goalDeps = noDependencies,
      goalEvidence = [],
      goalAttempt = 0
    }

-- | What the model is shown and what the kernel checks against, from one value.
planValidationEnv :: Map ToolRef CatalogEntry -> Text -> ValidationEnv
planValidationEnv catalog objective =
  ValidationEnv
    { venCatalog = catalog,
      -- No verifiers are admitted yet, so the goal section says "shape check
      -- only" and an @accept@ block is a rejection.  Honest: a verifier
      -- registry exists in the kernel and has no entries in production.
      venVerifiers = Map.empty,
      venHandles = Map.empty,
      venAdmittedVerifiers = Set.empty,
      venGoal = planGoalFor catalog objective,
      venBindings = Map.empty,
      venCostCeiling = 100000
    }

guideTool :: Map ToolRef CatalogEntry -> Tool es
guideTool catalog =
  Tool
    { toolName = "plan_guide",
      toolDescription =
        T.unwords
          [ "取「计划」这门小语言的完整说明。",
            "手上的事需要好几步、几次查询才能答，且步骤之间的依赖你已经想清楚时，先用它拿说明，再用 plan_run 提交。",
            "简单一问一答不需要计划，直接答或直接调工具就行。"
          ],
      toolSchema =
        toolObject
          [("objective", stringParam "这一轮你打算用计划完成什么，一句话。说明会按它给出额度和可用工具。")]
          ["objective"],
      toolRun = \args -> case parseEither (withObject "args" (.: "objective")) args of
        Left e -> pure (Left ("bad args: " <> T.pack e))
        Right (objective :: Text) ->
          pure . Right $
            object
              [ "guide" .= frontPrompt (planValidationEnv catalog objective),
                "next" .= ("照说明写好计划，用 plan_run 提交，objective 写同一句。" :: Text)
              ]
    }

-- | How an admitted plan and its suspension get written down, if at all.
--
-- Injected rather than reached for, and not only to keep a database out of the
-- tool's specs.  What a plan /is/ — parsed, admissible, executable — is settled
-- entirely by this module and the kernel; where a copy of it lives is somebody
-- else's decision, and the two have no business being one type.
--
-- The two writes travel together because the second is meaningless without the
-- first: a checkpoint identifies itself by the plan it belongs to, and a
-- dispatch that could not open a plan has nothing to park against.
data PlanJournal es = PlanJournal
  { pjRecord :: PlanDocument -> Eff es (Maybe PlanRef),
    -- | Park the execution state at a fork, against the revision it walked.
    -- 'False' means the plan moved underneath and this state describes a plan
    -- that is no longer current.
    pjSuspend :: PlanRef -> Revision -> Text -> Value -> Eff es Bool
  }

-- | Neither half. What a dispatch with no durable turn gets, and what the
-- specs use to talk about the kernel without talking about Postgres.
noPlanJournal :: PlanJournal es
noPlanJournal =
  PlanJournal {pjRecord = \_ -> pure Nothing, pjSuspend = \_ _ _ _ -> pure False}

-- | Record revision 1 against the turn that produced it, and park against it.
--
-- Best-effort, and that asymmetry is the point.  The plan is admissible
-- whatever the database says, and refusing to run it because a row would not go
-- in would let bookkeeping veto work the kernel already approved.  Losing the
-- row costs a record; losing the turn costs an answer.
--
-- A dispatch with no durable turn records nothing, which is the honest answer
-- rather than a degraded one: 'openPlan' derives the conversation /from/ the
-- turn precisely so the two cannot disagree, and there is nothing to derive it
-- from here.
durablePlanJournal ::
  (Log :> es, WithConnection :> es, IOE :> es) =>
  ToolContext ->
  PlanJournal es
durablePlanJournal dc = case toolTurnOutputContext dc of
  Nothing -> noPlanJournal
  Just output ->
    PlanJournal
      { pjRecord = \document ->
          (Just <$> openPlan (turnOutputAgentTurn output) document)
            `catchSync` \e -> do
              logAttention "plan: not persisted" $
                object ["root" .= document.pdRoot, "error" .= T.pack (show (e :: SomeException))]
              pure Nothing,
        pjSuspend = \ref based node state ->
          suspendPlan ref based node state
            `catchSync` \e -> do
              logAttention "plan: not suspended" $
                object ["plan_id" .= ref.prPlanId.unPlanId, "error" .= T.pack (show (e :: SomeException))]
              pure False
      }

runTool ::
  Log :> es =>
  PlanJournal es ->
  Map ToolRef CatalogEntry ->
  ToolCatalog es ->
  Tool es
runTool journal catalog sub =
  Tool
    { toolName = "plan_run",
      toolDescription =
        T.unwords
          [ "提交并执行一段计划（先用 plan_guide 拿语法说明）。",
            "整段计划一次跑完，中间的工具结果不会进你的上下文——只有 done 的那个值会回来。",
            "解析或校验没过会原样告诉你哪儿不对，可以改了重交。"
          ],
      toolSchema =
        toolObject
          [ ("objective", stringParam "跟 plan_guide 用的同一句。"),
            ("plan", stringParam "计划正文，从第一个 let / done / if / hole / fork 开始。不要加 ``` 代码块。")
          ]
          ["objective", "plan"],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure (Left ("bad args: " <> T.pack e))
        Right (objective, source) -> do
          let env = planValidationEnv catalog objective
              root = "plan:" <> T.take 12 (T.filter (/= ' ') objective)
          case parsePlan source of
            Left failure -> pure (Left ("计划没解析通过：" <> parseFailureText failure))
            Right parsed -> case validatePlan env root parsed of
              Left rejection -> pure (Left ("计划没通过校验：" <> rejectionText rejection))
              Right valid -> do
                -- Written before execution rather than after it: the row
                -- records what was *admitted*, and an admitted plan that then
                -- crashed is exactly the case worth having on disk.  It is also
                -- the identity later work hangs off — a fork's spawn edges
                -- reference a plan id, a steer replaces a head revision, and
                -- neither exists until somebody writes the first one.  Step 3
                -- built these tables deliberately ahead of the executor and
                -- left them with no writer; this is the writer.
                stored <- journal.pjRecord PlanDocument {pdRoot = root, pdPlan = parsed}
                logInfo "plan: admitted" $
                  object
                    [ "objective" .= objective,
                      "hash" .= planHash parsed,
                      "holes" .= length (planHoles root parsed),
                      "children" .= length (planChildren root parsed),
                      "plan_id" .= fmap (.prPlanId.unPlanId) stored
                    ]
                result <-
                  runTools sub $
                    executePlan
                      ExecutionEnv {exValidation = env, exHandles = Map.empty, exRoot = root}
                      valid
                case (result.erEnd, stored) of
                  (Deoptimized (AtFork node _ _ children), Just ref) -> do
                    -- Revision 1 by construction: this tool opens the plan a
                    -- few lines above and nothing else has had the chance to
                    -- move it.  Passed rather than assumed inside the journal
                    -- so that the day a plan arrives here already revised, the
                    -- compiler asks which revision it walked.
                    parked <- journal.pjSuspend ref (Revision 1) node.unNodeId (toJSON result.erState)
                    if parked
                      then do
                        logInfo "plan: suspended at a fork" $
                          object
                            [ "plan_id" .= ref.prPlanId.unPlanId,
                              "node" .= node.unNodeId,
                              "children" .= length children
                            ]
                        pure (reportSuspension result children)
                      else do
                        -- The head moved between admitting this plan and
                        -- reaching its fork.  Reported as an ordinary stop:
                        -- the work already done still counts, and the model is
                        -- the one who can say what the change meant.
                        logAttention "plan: fork not parked; plan moved" $
                          object ["plan_id" .= ref.prPlanId.unPlanId, "node" .= node.unNodeId]
                        pure (report result)
                  _ -> pure (report result)
    }
  where
    parseArgs o = (,) <$> o .: "objective" <*> o .: "plan"

-- | Turn an execution into something a model can act on.
--
-- A stopped plan is reported as a value rather than as an error, and the
-- distinction is deliberate: nothing went wrong, the plan simply asked for
-- something this slice cannot supply, and the steps it did take are real work
-- the model should not repeat.  An error string would invite a retry of the
-- whole thing.
report :: ExecutionResult -> Either Text Value
report result =
  Right $
    object
      ( ran result
          <> case result.erEnd of
            Produced value -> ["done" .= value]
            Deoptimized deopt ->
              [ "stopped" .= deoptText deopt,
                "advice" .= ("计划停在这里了。上面 tools_run 里的工具已经跑过，不用重来；剩下的这一轮自己接着做。" :: Text)
              ]
      )

-- | A fork that was parked: not a stop, and the difference matters to what the
-- model does next.
--
-- Nothing went wrong and nothing is waiting on this turn.  The subgoals will
-- each get a turn of their own, and the plan continues when they are back —
-- in a turn this one has no part in.  So the advice is the opposite of the
-- stop's: /do not/ pick the work up by hand, because doing it here would race
-- the children that are about to do it.
reportSuspension :: ExecutionResult -> [(NodeId, Binder, Goal)] -> Either Text Value
reportSuspension result children =
  Right $
    object
      ( ran result
          <> [ "suspended"
                 .= [ object ["binder" .= binder.unBinder, "objective" .= goal.goalObjective]
                    | (_, binder, goal) <- children
                    ],
               "advice"
                 .= T.unwords
                   [ "计划挂起了，上面这些子任务会各自开一轮去做，做完计划自己接着往下走，到时候会来叫你看结果。",
                     "所以现在别自己再查一遍，也别等在这儿。",
                     "这一轮你要么先说一句在办了，要么直接 [silence]。"
                   ]
             ]
      )

ran :: ExecutionResult -> [Pair]
ran result =
  [ "calls_used" .= result.erCallsUsed,
    "tools_run" .= [record.srTool.unToolRef | record <- result.erSteps]
  ]
