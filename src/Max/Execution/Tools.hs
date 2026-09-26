{-# LANGUAGE RankNTypes #-}

-- | Host execution shared by model protocol and guest adapters. No LLM or SQL.
module Max.Execution.Tools
  ( ExecutionSession,
    ExecutionHooks (..),
    ToolRequest (..),
    ToolBatch (..),
    newExecutionSession,
    executionHooks,
    hoistExecutionHooks,
    freshExecutionLabel,
    executeToolBatch,
    withExecutionRecord,
    outcomeName,
    outcomeEnvelope,
  )
where

import Control.Monad (unless)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (for_)
import Data.List (find)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Effectful
import Effectful.Concurrent.Async (Concurrent, mapConcurrently)
import Effectful.Concurrent.MVar
  ( MVar,
    newMVar,
    putMVar,
    takeMVar,
  )
import Effectful.Concurrent.STM
  ( TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVar,
    readTVarIO,
    writeTVar,
  )
import Effectful.Exception
  ( Exception,
    SomeException,
    bracket_,
    catch,
    finally,
    mask,
    throwIO,
    try,
  )
import Max.Agent.Execution
import Max.Effects.Tools (Tools, invokeToolWithControl)
import Max.Execution.Types
import Max.Execution.Workflow
import Max.Tasks
  ( TaskCancelled (..),
    TurnRuntime,
    checkTurnCancellation,
    nextExecutionOrdinal,
    turnRuntimeAgentTurn,
  )
import Max.Tool.Control
  ( LoopControl (..),
    controlSkillLoads,
  )
import Max.Tool.Types
import OneBot.Types (GroupId)

data ToolRequest = ToolRequest
  { trCallId :: !Text,
    trName :: !Text,
    trArguments :: !Value
  }
  deriving stock (Show, Eq)

-- | Assembly supplies the same admission/journal implementation to both paths.
data ExecutionHooks es = ExecutionHooks
  { ehCheck :: Eff es (),
    ehStart :: ExecutionStep -> JournalStart -> Eff es (Maybe JournalExecution),
    ehFinish :: JournalExecution -> JournalFinish -> Eff es (),
    ehWorkflow :: Maybe (WorkflowHost es)
  }

executionHooks :: (IOE :> es) => ExecutionAdmission es -> ExecutionJournal es -> GroupId -> TurnRuntime -> ExecutionHooks es
executionHooks admission journal group turn =
  ExecutionHooks
    { ehCheck = do
        liftIO (checkTurnCancellation turn)
        active <- admission.eaCheck (turnRuntimeAgentTurn turn)
        unless active (throwIO TaskCancelled),
      ehStart = \step start -> do
        let ref = turnRuntimeAgentTurn turn
        prepared <- journal.ejPrepare group start
        admission.eaAdmitTool ref step >>= \case
          Admitted -> pure ()
          OverBudget -> throwIO CallBudgetExhausted
          Refused -> throwIO TaskCancelled
        ordinal <- liftIO (nextExecutionOrdinal turn)
        now <- liftIO getCurrentTime
        pure (Just (JournalExecution ref ordinal prepared now)),
      ehFinish = journal.ejFinish,
      ehWorkflow = Nothing
    }

hoistExecutionHooks :: (forall x. Eff es x -> Eff target x) -> ExecutionHooks es -> ExecutionHooks target
hoistExecutionHooks lower hooks =
  ExecutionHooks
    { ehCheck = lower hooks.ehCheck,
      ehStart = \step -> lower . hooks.ehStart step,
      ehFinish = \row -> lower . hooks.ehFinish row,
      ehWorkflow = hoistWorkflowHost lower <$> hooks.ehWorkflow
    }

-- | Admission refused a call because its agent tree's budget is spent. The
-- call is rejected before any effect; the agent itself keeps running.
data CallBudgetExhausted = CallBudgetExhausted deriving stock (Show)

instance Exception CallBudgetExhausted

data ExecutionSession = ExecutionSession
  { remaining :: !(TVar (Maybe Int)),
    sequenceNumber :: !(TVar Integer),
    batchLock :: !(MVar ())
  }

newExecutionSession :: (Concurrent :> es) => Maybe Int -> Eff es ExecutionSession
newExecutionSession limit =
  ExecutionSession <$> newTVarIO (max 0 <$> limit) <*> newTVarIO 0 <*> newMVar ()

-- | Labels are local to this session; result ordinals belong to the turn.
freshExecutionLabel :: (Concurrent :> es) => ExecutionSession -> Text -> Eff es Text
freshExecutionLabel session prefix = atomically $ do
  n <- readTVar session.sequenceNumber
  writeTVar session.sequenceNumber (n + 1)
  pure (prefix <> ":" <> T.pack (show n))

data ToolBatch = ToolBatch
  { tbInvocations :: ![ToolInvocation],
    tbOverBudget :: !Bool
  }
  deriving stock (Show)

-- | A batch owns the scheduling gate, including settlement. Its unused local
-- reservations are released even when admission or a sibling is interrupted.
executeToolBatch :: (Tools :> es, Concurrent :> es) => ExecutionSession -> ExecutionHooks es -> [CatalogTool] -> [ToolRequest] -> Eff es ToolBatch
executeToolBatch session hooks catalog = executeBatch invoke session hooks catalog
  where
    invoke request = invokeToolWithControl request.trName request.trArguments

executeBatch :: (Concurrent :> es) => (ToolRequest -> Eff es ToolInvocation) -> ExecutionSession -> ExecutionHooks es -> [CatalogTool] -> [ToolRequest] -> Eff es ToolBatch
executeBatch invoke session hooks catalog requests =
  bracket_ (takeMVar session.batchLock) (putMVar session.batchLock ()) $ mask $ \restoreBatch -> do
    hooks.ehCheck
    let view request = find ((== ToolRef request.trName) . (.ctDefinition.tdRef)) catalog
        mode request = maybe WorkCall (.ctDefinition.tdCallMode) (view request)
        cost request = if mode request == WorkCall then 1 else 0
        total = sum [cost request | request <- requests]
        canParallel request = maybe False ((`elem` [ParallelSafe, ParallelIndependent]) . (.ctDefinition.tdParallelism)) (view request)
    reserved <- atomically $ do
      budget <- readTVar session.remaining
      case budget of
        Just available | total > available -> pure False
        _ -> writeTVar session.remaining (subtract total <$> budget) >> pure True
    if not reserved
      then pure (ToolBatch (map (const budgetSpent) requests) True)
      else do
        unused <- newTVarIO total
        spent <- newTVarIO False
        let release = atomically $ do
              refund <- readTVar unused
              modifyTVar' session.remaining (fmap (+ refund))
            execute request = do
              let start = maybe (unknownJournalStart request) (catalogJournalStart request) (view request)
                  step = if cost request == 0 then ExecutionCheckpoint else ExecutionWork ReserveCall
                  admitting =
                    hooks
                      { ehStart = \reservation entry -> do
                          row <- hooks.ehStart reservation entry
                          atomically $ modifyTVar' unused (subtract (cost request))
                          pure row
                      }
              recorded <- try $ withExecutionRecord admitting step start $ \_ -> do
                result <- case view request of
                  Nothing -> pure (rejected "unknown_tool" ("tool is outside the execution catalog: " <> request.trName))
                  Just _ -> invoke request
                pure ((), result)
              case recorded of
                Right (_, invocation) -> pure invocation
                Left CallBudgetExhausted -> atomically (writeTVar spent True) >> pure budgetSpent
        invocations <- restoreBatch (if all canParallel requests then mapConcurrently execute requests else traverse execute requests) `finally` release
        ToolBatch invocations <$> readTVarIO spent
  where
    budgetSpent = rejected "call_budget_exhausted" "工具调用预算已经用完，不能再执行这个调用；直接根据已有信息给出最终回复"

-- | Admission is local. Record the outcome after the cancellable body; a
-- diagnostic failure must not reclassify a completed external effect.
withExecutionRecord :: ExecutionHooks es -> ExecutionStep -> JournalStart -> (Maybe JournalExecution -> Eff es (a, ToolInvocation)) -> Eff es (a, ToolInvocation)
withExecutionRecord hooks step start body = mask $ \restore -> do
  hooks.ehCheck
  row <- hooks.ehStart step start
  (value, invocation) <-
    restore (body row)
      `catch` \(exception :: SomeException) -> do
        for_ row $ \entry -> hooks.ehFinish entry (JournalOutcomeUnknown "interrupted" (T.pack (show exception)))
        throwIO exception
  for_ row $ \entry -> hooks.ehFinish entry (journalFinish (journalControl invocation))
  pure (value, invocation {tiOutcome = stripJournalMetadata invocation.tiOutcome})

rejected :: Text -> Text -> ToolInvocation
rejected code message = ToolInvocation (ToolRejected (ToolFault code message RetrySafe)) ContinueLoop

-- | Preserve classification across the guest ABI; never turn unknown into an
-- apparently safe error. Trusted control and journal metadata are not JSON.
outcomeEnvelope :: ToolOutcome -> Value
outcomeEnvelope outcome =
  object $
    ["outcome" .= outcomeName outcome] <> case outcome of
      ToolSucceeded value -> ["value" .= value]
      ToolCommitted value -> ["value" .= value]
      ToolRejected fault -> failure fault
      ToolFailedBeforeEffect fault -> failure fault
      ToolOutcomeUnknown fault -> failure fault
  where
    failure fault = ["error" .= object ["code" .= fault.tfCode, "message" .= fault.tfMessage, "retry" .= retryClassText fault.tfRetryClass]]

outcomeName :: ToolOutcome -> Text
outcomeName = \case
  ToolRejected {} -> "rejected"
  ToolFailedBeforeEffect {} -> "failed-before-effect"
  ToolSucceeded {} -> "succeeded"
  ToolCommitted {} -> "committed"
  ToolOutcomeUnknown {} -> "outcome-unknown"

-- Activation evidence comes only from the typed host channel.
journalControl :: ToolInvocation -> ToolOutcome
journalControl invocation = case controlSkillLoads invocation.tiControl of
  [] -> invocation.tiOutcome
  loads -> case invocation.tiOutcome of
    ToolSucceeded (Object fields) -> ToolSucceeded (Object (KeyMap.insert "_max_journal_observed_manifest" (object ["skill_loads" .= loads]) fields))
    ToolCommitted (Object fields) -> ToolCommitted (Object (KeyMap.insert "_max_journal_observed_manifest" (object ["skill_loads" .= loads]) fields))
    other -> other

catalogJournalStart :: ToolRequest -> CatalogTool -> JournalStart
catalogJournalStart tc view =
  JournalStart
    { jsCallId = tc.trCallId,
      jsToolRef = tc.trName,
      jsSchemaVersion = view.ctDefinition.tdSchemaVersion.unSchemaVersion,
      jsSchemaHash = view.ctSchemaHash.unSchemaHash,
      jsInput = case tc.trArguments of Object fields -> Object (KeyMap.delete "_max_host_network_mode" fields); value -> value,
      jsEffectLabels = toJSON (map effectLabel (Set.toList view.ctDefinition.tdEffects)),
      jsRetryClass = retryClassText view.ctDefinition.tdRetryClass
    }

unknownJournalStart :: ToolRequest -> JournalStart
unknownJournalStart tc =
  JournalStart tc.trCallId tc.trName 0 "unknown" tc.trArguments (toJSON ([] :: [Value])) "safe"

effectLabel :: ToolEffect -> Value
effectLabel = \case
  EffectRead domain -> object ["kind" .= ("read" :: Text), "domain" .= domain]
  EffectWrite domain -> object ["kind" .= ("write" :: Text), "domain" .= domain]
  EffectSend domain -> object ["kind" .= ("send" :: Text), "domain" .= domain]
  EffectLLM -> object ["kind" .= ("llm" :: Text)]
  EffectReflect -> object ["kind" .= ("reflect" :: Text)]

retryClassText :: ToolRetryClass -> Text
retryClassText = \case
  RetrySafe -> "safe"
  RetryIdempotent -> "idempotent"
  RetryUnsafe -> "unsafe"

journalFinish :: ToolOutcome -> JournalFinish
journalFinish = \case
  ToolRejected fault -> JournalRejected fault.tfCode fault.tfMessage
  ToolFailedBeforeEffect fault -> JournalFailed fault.tfCode fault.tfMessage
  ToolSucceeded value -> JournalSucceeded value
  ToolCommitted value -> JournalCommitted value
  ToolOutcomeUnknown fault -> JournalOutcomeUnknown fault.tfCode fault.tfMessage

stripJournalMetadata :: ToolOutcome -> ToolOutcome
stripJournalMetadata = \case
  ToolSucceeded value -> ToolSucceeded (stripValue value)
  ToolCommitted value -> ToolCommitted (stripValue value)
  other -> other
  where
    stripValue (Object fields) =
      Object
        ( KeyMap.delete "_max_journal_canonical_message_id" $
            KeyMap.delete "_max_journal_observed_manifest" fields
        )
    stripValue value = value
