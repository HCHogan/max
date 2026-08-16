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
-- would. It also makes @plan_run@ structurally unable to invoke itself, since
-- the subset never contains it. A child can still delegate by opening a new
-- durable plan through its outer agent loop; recursion crosses that journaled
-- turn/plan boundary rather than occurring inside one executor.
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
    plannableSubCatalog,
    PlanJournal (..),
    durablePlanJournal,
    planGoalFor,
    planValidationEnv,
    planResourceHandles,
    validationEnvForContract,
  )
where

import Data.Aeson
import Data.Aeson.Types (Pair, parseEither)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, isJust)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.List (sortOn)
import Data.Scientific qualified as Scientific
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as Vector
import Crypto.Hash.SHA256 qualified as SHA256
import Control.Exception (SomeException)
import Control.Monad (foldM)
import Effectful
import Effectful.Concurrent (Concurrent)
import Effectful.Log (Log, logAttention, logInfo)
import Effectful.PostgreSQL (WithConnection)
import Data.Foldable (for_)
import Max.DB.Plan
  ( PlanId (..),
    PlanLoadError,
    PlanOrdinal (..),
    PlanRef (..),
    PlanStatus (..),
    Revision (..),
    RevisionConflict (..),
    RevisionCause (CauseSteer),
    StoredPlan (..),
    closePlan,
    listOpenPlans,
    openPlanWithGrants,
    planLoadErrorText,
    revisePlan,
    suspendPlan,
  )
import Max.DB.AgentTurn (resolveJournalResultValue)
import Max.Effects.Blob (Blob)
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
    ExecState (..),
    ExecutionEnd (..),
    ExecutionEnv (..),
    ExecutionResult (..),
    StepRecord (..),
    deoptText,
    initialState,
    resumePlan,
  )
import Max.Plan.Parse (parseFailureText, parsePlan)
import Max.Plan.Prompt (childPrompt, frontPrompt)
import Max.Plan.Schema (PlanSchema (..), SchemaField (..))
import Max.Plan.Types
import Max.Plan.Validate (CatalogEntry (..), ValidationEnv (..), childEnv, rejectionText, validatePlan)
import Max.ToolContext (SubgoalReturn (..), ToolContext, toolAuthorPrincipalId, toolCatalogGrants, toolClearedAt, toolConversationScope, toolGroupId, toolSubgoal, toolTurnOutputContext)
import Max.Tools.Schema (integerParam, noArguments, stringParam, toolObject)
import Max.Turn.Continuity (toolCatalogFingerprint)
import Max.Turn.Types (parseTurnHandle, turnOutputAgentTurn)
import Max.Util (catchSync, tshow)

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
  (Log :> es, Concurrent :> es) =>
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
    Right built -> [guideTool journal catalog, runTool journal catalog built, listTool journal, reviseTool journal currentGrants catalog]
  where
    catalog = planCatalog definitions
    currentGrants =
      Map.fromList
        [ (definition.tdRef.unToolRef, toolCatalogFingerprint [definition])
        | definition <- definitions
        ]
    subCatalog = plannableSubCatalog definitions runners

-- | The tools a plan may call, out of what this dispatch resolved.
--
-- Two callers, and they must agree or a plan would resume into a different
-- world than it started in: 'planToolsFor' builds it for an inline run, and the
-- worker that resumes a suspended plan builds it again from the same
-- definitions. Sharing the construction is what makes "the same catalog" a
-- fact rather than a convention.
--
-- @plan_run@ is never in it, so one executor cannot recursively invoke itself.
-- Nested delegation remains possible through a child turn opening another
-- durable plan.
plannableSubCatalog ::
  [ToolDefinition] ->
  [Tool es] ->
  Either Tools.ToolCatalogError (ToolCatalog es)
plannableSubCatalog definitions runners =
  buildToolCatalog
    [d | d <- definitions, Set.member d.tdRef plannable]
    [r | r <- runners, Set.member (ToolRef r.toolName) plannable]
  where
    plannable = Map.keysSet (planCatalog definitions)

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

guideTool :: PlanJournal es -> Map ToolRef CatalogEntry -> Tool es
guideTool journal catalog =
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
        Right (objective :: Text) -> do
          bodies <- journal.pjResolve (maybe [] (.sgGoal.goalResources) journal.pjSubgoal)
          let env = validationEnvForContract catalog objective journal.pjSubgoal bodies
              prompt = if isJust journal.pjSubgoal then childPrompt env else frontPrompt env
          pure . Right $
            object
              [ "guide" .= prompt,
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
  { pjRecord :: Goal -> PlanDocument -> Eff es (Maybe PlanRef),
    -- | A child plans against the complete goal and explicit input values it
    -- was dispatched with. Ordinary turns carry no enclosing goal.
    pjSubgoal :: !(Maybe SubgoalReturn),
    -- | Conversation-scoped steering surface. Child turns get no steering
    -- grants, but keeping the callbacks here preserves a pure tool seam.
    pjList :: Eff es [Either PlanLoadError StoredPlan],
    pjRevise :: PlanRef -> Revision -> PlanDocument -> Eff es (Either Text Revision),
    pjResolve :: [Text] -> Eff es (Map Text Value),
    -- | Park the execution state at a fork, against the revision it walked.
    -- 'False' means the plan moved underneath and this state describes a plan
    -- that is no longer current.
    pjSuspend :: PlanRef -> Revision -> Text -> Value -> Eff es Bool,
    -- | Close a plan that ended inside this call.
    --
    -- Only a fork outlives the tool, so every other ending is the end of the
    -- plan and leaving it open would put a finished plan in the steerable set —
    -- where a steer would land on something nobody is running.
    pjSettle :: PlanRef -> PlanStatus -> Eff es ()
  }

-- | Neither half. What a dispatch with no durable turn gets, and what the
-- specs use to talk about the kernel without talking about Postgres.
noPlanJournal :: PlanJournal es
noPlanJournal =
  PlanJournal
    { pjRecord = \_ _ -> pure Nothing,
      pjSubgoal = Nothing,
      pjList = pure [],
      pjRevise = \_ _ _ -> pure (Left "这一轮没有持久化计划上下文"),
      pjResolve = \_ -> pure Map.empty,
      pjSuspend = \_ _ _ _ -> pure False,
      pjSettle = \_ _ -> pure ()
    }

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
  (Blob :> es, Log :> es, WithConnection :> es, IOE :> es) =>
  ToolContext ->
  PlanJournal es
durablePlanJournal dc = case toolTurnOutputContext dc of
  Nothing -> noPlanJournal
  Just output ->
    PlanJournal
      { pjRecord = \goal document ->
          (Just <$> openPlanWithGrants (turnOutputAgentTurn output) (toolCatalogGrants dc) goal document)
            `catchSync` \e -> do
              logAttention "plan: not persisted" $
                object ["root" .= document.pdRoot, "error" .= T.pack (show (e :: SomeException))]
              pure Nothing,
        pjSubgoal = toolSubgoal dc,
        pjList = listOpenPlans (toolGroupId dc),
        pjRevise = \ref based document -> do
          outcome <-
            revisePlan
              ref
              based
              CauseSteer
              (Just (toolAuthorPrincipalId dc))
              (Just (turnOutputAgentTurn output))
              document
          pure $ case outcome of
            Left conflict -> Left ("计划已经变成 revision " <> tshow conflict.rcHead.unRevision <> "，先重新 plan_list")
            Right revision -> Right revision,
        pjResolve = \handles ->
          Map.fromList . catMaybes
            <$> traverse
              (\handle -> fmap ((handle,) <$>) (resolveJournalResultValue (toolConversationScope dc) (toolClearedAt dc) handle))
              handles,
        pjSuspend = \ref based node state ->
          suspendPlan ref based node state
            `catchSync` \e -> do
              logAttention "plan: not suspended" $
                object ["plan_id" .= ref.prPlanId.unPlanId, "error" .= T.pack (show (e :: SomeException))]
              pure False,
        pjSettle = \ref status ->
          closePlan ref status
            `catchSync` \e ->
              logAttention "plan: not closed" $
                object ["plan_id" .= ref.prPlanId.unPlanId, "error" .= T.pack (show (e :: SomeException))]
      }

listTool :: PlanJournal es -> Tool es
listTool journal =
  Tool
    { toolName = "plan_list",
      toolDescription = "列出当前会话里仍可 steering 的计划、revision 和完整 AST。要修改计划时先读它。",
      toolSchema = noArguments,
      toolRun = \_ -> do
        plans <- journal.pjList
        pure . Right . toJSON $
          [ case row of
              Left err -> object ["error" .= planLoadErrorText err]
              Right plan ->
                object
                  [ "plan" .= plan.stRef.prOrdinal.unPlanOrdinal,
                    "revision" .= plan.stRevision.unRevision,
                    "root" .= plan.stDocument.pdRoot,
                    "document" .= plan.stDocument,
                    "goal" .= plan.stRootGoal
                  ]
          | row <- plans
          ]
    }

reviseTool :: PlanJournal es -> Map Text Text -> Map ToolRef CatalogEntry -> Tool es
reviseTool journal currentGrants catalog =
  Tool
    { toolName = "plan_revise",
      toolDescription = "用 compare-and-set 修改一个仍在运行的计划。必须使用刚从 plan_list 读到的 plan/revision；冲突后重新读取，不得盲重试。",
      toolSchema =
        toolObject
          [ ("plan", integerParam "plan_list 返回的计划号"),
            ("revision", integerParam "plan_list 返回的当前 revision"),
            ("objective", stringParam "修改后计划要完成的目标"),
            ("source", stringParam "新的完整计划源码，不加代码块")
          ]
          ["plan", "revision", "objective", "source"],
      toolRun = \args -> case parseEither (withObject "args" parseRevise) args of
        Left err -> pure (Left ("bad args: " <> T.pack err))
        Right (ordinal, revision, objective, source) -> do
          heads <- journal.pjList
          case [stored | Right stored <- heads, stored.stRef.prOrdinal == PlanOrdinal ordinal] of
            [] -> pure (Left "这个会话里没有仍在运行的这个计划")
            stored : _
              | stored.stRevision /= Revision revision ->
                  pure (Left ("revision 已经过期；现在是 " <> tshow stored.stRevision.unRevision <> "，先重新 plan_list"))
              | otherwise -> case parsePlan source of
                  Left failure -> pure (Left ("计划没解析通过：" <> parseFailureText failure))
                  Right parsed -> do
                    let resourceContract = if stored.stServesSubgoal then stored.stRootGoal else Nothing
                        admittedCatalog =
                          Map.filterWithKey
                            (\ref _ ->
                               Map.lookup ref.unToolRef stored.stToolGrants
                                 == Map.lookup ref.unToolRef currentGrants
                            )
                            catalog
                    bodies <- journal.pjResolve (planResourceHandles resourceContract parsed)
                    let base = validationEnvForContract admittedCatalog objective Nothing bodies
                        env = maybe base (\goal -> base {venGoal = goal}) stored.stRootGoal
                        document = PlanDocument stored.stDocument.pdRoot parsed
                    case validatePlan env document.pdRoot document.pdPlan of
                      Left rejection -> pure (Left ("计划没通过校验：" <> rejectionText rejection))
                      Right _ -> do
                        changed <- journal.pjRevise stored.stRef stored.stRevision document
                        pure $ case changed of
                          Left detail -> Left detail
                          Right next -> Right (object ["plan" .= ordinal, "revision" .= next.unRevision, "updated" .= True])
    }
  where
    parseRevise o = (,,,) <$> o .: "plan" <*> o .: "revision" <*> o .: "objective" <*> o .: "source"

validationEnvForContract ::
  Map ToolRef CatalogEntry ->
  Text ->
  Maybe SubgoalReturn ->
  Map Text Value ->
  ValidationEnv
validationEnvForContract available objective contract bodies = case contract of
  Nothing -> parent
  Just subgoal ->
    childEnv
      parent
        { venBindings =
            Map.fromList
              [ (binder, schema)
              | (binder, value) <- subgoal.sgInputs,
                Just schema <- [schemaOfValue value]
              ]
        }
      subgoal.sgGoal
  where
    parent =
      (planValidationEnv available objective)
        { venHandles = Map.mapMaybeWithKey valueRef bodies
        }
    valueRef handle value = do
      schema <- schemaOfValue value
      let bytes = canonicalBytes value
      pure
        ValueRef
          { vrHandle = handle,
            vrSchema = schema,
            vrScope = CurrentConversation,
            vrDigest = TE.decodeUtf8 (Base16.encode (SHA256.hash bytes)),
            vrLength = BS.length bytes,
            vrRetained = True
          }

-- | Handles an authored plan asks to read. A child is additionally intersected
-- with its root Goal's explicit resource list, so guessing another t# handle
-- cannot widen its authority.
planResourceHandles :: Maybe Goal -> Plan -> [Text]
planResourceHandles rootGoal plan =
  Set.toList $ case rootGoal of
    Nothing -> authored
    Just goal -> Set.intersection authored (Set.fromList goal.goalResources)
  where
    authored = Set.fromList (collect (toJSON plan))
    collect = \case
      String text | isJust (parseTurnHandle text) -> [text]
      Array values -> concatMap collect (Vector.toList values)
      Object fields -> concatMap collect (KeyMap.elems fields)
      _ -> []

-- | Derive the narrow structural type of a host-supplied input value. Empty
-- or heterogeneous collections and null have no honest element/base type in
-- the plan language, so they remain unavailable to authored expressions
-- rather than being advertised under a guessed type.
schemaOfValue :: Value -> Maybe PlanSchema
schemaOfValue = \case
  String _ -> Just SchemaText
  Number n
    | Scientific.isInteger n -> Just SchemaInt
    | otherwise -> Just SchemaNumber
  Bool _ -> Just SchemaBool
  Null -> Nothing
  Array values -> do
    first : rest <- traverse schemaOfValue (Vector.toList values)
    element <- foldM mergeSchema first rest
    pure (SchemaArray element)
  Object fields ->
    SchemaObject
      <$> traverse
        (\(name, value) -> SchemaField (Key.toText name) <$> schemaOfValue value <*> pure True)
        (sortOn (Key.toText . fst) (KeyMap.toList fields))
  where
    mergeSchema left right
      | left == right = Just left
    mergeSchema SchemaInt SchemaNumber = Just SchemaNumber
    mergeSchema SchemaNumber SchemaInt = Just SchemaNumber
    mergeSchema _ _ = Nothing

runTool ::
  (Log :> es, Concurrent :> es) =>
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
          let root = "plan:" <> T.take 12 (T.filter (/= ' ') objective)
          case parsePlan source of
            Left failure -> pure (Left ("计划没解析通过：" <> parseFailureText failure))
            Right parsed -> do
              bodies <- journal.pjResolve (planResourceHandles ((.sgGoal) <$> journal.pjSubgoal) parsed)
              let env = validationEnvForContract catalog objective journal.pjSubgoal bodies
              case validatePlan env root parsed of
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
                  stored <- journal.pjRecord env.venGoal PlanDocument {pdRoot = root, pdPlan = parsed}
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
                      resumePlan
                        ExecutionEnv {exValidation = env, exHandles = Map.restrictKeys bodies (Map.keysSet env.venHandles), exRoot = root}
                        valid
                        initialState {esBindings = Map.fromList (maybe [] (.sgInputs) journal.pjSubgoal)}
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
                          settle stored result
                          pure (report result)
                    _ -> do
                      settle stored result
                      pure (report result)
    }
  where
    parseArgs o = (,) <$> o .: "objective" <*> o .: "plan"

    -- Everything except a parked fork ends here and now.  A plan left open
    -- would sit in the steerable set forever, so a later steer would land on
    -- work nobody is doing.
    settle stored result =
      for_ stored $ \ref ->
        journal.pjSettle ref $ case result.erEnd of
          Produced _ -> PlanDone
          -- A hole is a stop in this slice: nothing resumes from one, and the
          -- model was told to finish by hand.  Recording that as abandoned is
          -- what happened, not a judgement about the plan's quality.
          Deoptimized _ -> PlanAbandoned

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
