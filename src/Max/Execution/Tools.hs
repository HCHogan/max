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

import Control.Concurrent.MVar (MVar, newMVar, putMVar, takeMVar)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Monad (unless, when)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (for_)
import Data.List (find)
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Concurrent.Async (Concurrent, mapConcurrently)
import Effectful.Exception (SomeException, bracket_, catch, finally, mask, throwIO)
import Max.Agent.Execution
import Max.Effects.Tools (Tools, invokeToolWithIdentity)
import Max.Execution.Types
import Max.Tasks (TaskCancelled (..), TurnRuntime, checkTurnCancellation, turnRuntimeAgentTurn)
import Max.Tool.Control (LoopControl (..), controlReply, controlSkillLoads)
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
    ehUnknown :: JournalExecution -> Text -> Eff es ()
  }

executionHooks :: (IOE :> es) => ExecutionAdmission es -> ExecutionJournal es -> GroupId -> TurnRuntime -> ExecutionHooks es
executionHooks admission journal group turn =
  ExecutionHooks
    { ehCheck = do
        liftIO (checkTurnCancellation turn)
        for_ (turnRuntimeAgentTurn turn) $ \durable -> do
          active <- admission.eaCheck durable
          unless active (throwIO TaskCancelled),
      ehStart = \step start -> maybe (pure Nothing) (\durable -> admission.eaStartTool group durable step start) (turnRuntimeAgentTurn turn),
      ehFinish = journal.ejFinish,
      ehUnknown = journal.ejUnknown
    }

hoistExecutionHooks :: (forall x. Eff es x -> Eff target x) -> ExecutionHooks es -> ExecutionHooks target
hoistExecutionHooks lower hooks =
  ExecutionHooks
    { ehCheck = lower hooks.ehCheck,
      ehStart = \step -> lower . hooks.ehStart step,
      ehFinish = \row -> lower . hooks.ehFinish row,
      ehUnknown = \row -> lower . hooks.ehUnknown row
    }

data ExecutionSession = ExecutionSession
  { remaining :: !(TVar (Maybe Int)),
    terminal :: !(TVar Bool),
    sequenceNumber :: !(TVar Integer),
    batchLock :: !(MVar ())
  }

newExecutionSession :: (IOE :> es) => Maybe Int -> Eff es ExecutionSession
newExecutionSession limit =
  liftIO $
    ExecutionSession <$> newTVarIO (max 0 <$> limit) <*> newTVarIO False <*> newTVarIO 0 <*> newMVar ()

-- | Labels are allocated by the host; durable identity is the journal row ID.
freshExecutionLabel :: (IOE :> es) => ExecutionSession -> Text -> Eff es Text
freshExecutionLabel session prefix = liftIO . atomically $ do
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
executeToolBatch :: (Tools :> es, Concurrent :> es, IOE :> es) => ExecutionSession -> ExecutionHooks es -> [CatalogTool] -> [ToolRequest] -> Eff es ToolBatch
executeToolBatch session hooks catalog requests =
  bracket_ (liftIO (takeMVar session.batchLock)) (liftIO (putMVar session.batchLock ())) $ mask $ \restoreBatch -> do
    hooks.ehCheck
    let view request = find ((== ToolRef request.trName) . (.ctDefinition.tdRef)) catalog
        mode request = maybe WorkCall (.ctDefinition.tdCallMode) (view request)
        finishes = filter ((== FinishCall) . mode) requests
        suppressed request = not (null finishes) && (length finishes /= 1 || mode request /= FinishCall)
        cost request = if mode request == WorkCall then 1 else 0
        total = sum [cost request | request <- requests, not (suppressed request)]
        canParallel request = maybe False ((== ParallelSafe) . (.ctDefinition.tdParallelism)) (view request)
    reserved <- liftIO . atomically $ do
      budget <- readTVar session.remaining
      case budget of
        Just available | total > available -> pure False
        _ -> writeTVar session.remaining (subtract total <$> budget) >> pure True
    if not reserved
      then pure (ToolBatch (map (const (rejected "call_budget_exhausted" "这个子任务的工具调用额度已经用满，不能再执行这个调用")) requests) True)
      else do
        unused <- liftIO (newTVarIO total)
        let release = liftIO . atomically $ do
              refund <- readTVar unused
              modifyTVar' session.remaining (fmap (+ refund))
            execute request
              | suppressed request = pure (rejected "finish_batch_conflict" "结束回合的操作必须单独提交；同一轮的其他工具调用已拒绝")
              | otherwise = do
                  stopped <- liftIO (readTVarIO session.terminal)
                  if stopped
                    then pure (rejected "execution_stopped" "execution has already yielded or finished")
                    else do
                      let start = maybe (unknownJournalStart request) (catalogJournalStart request) (view request)
                          step = if cost request == 0 then ExecutionCheckpoint else ExecutionWork ReserveCall
                          admitting =
                            hooks
                              { ehStart = \reservation entry -> do
                                  row <- hooks.ehStart reservation entry
                                  liftIO . atomically $ modifyTVar' unused (subtract (cost request))
                                  pure row
                              }
                      (_, invocation) <- withExecutionRecord admitting step start $ \row -> mask $ \restore -> do
                        result <- restore (invokeToolWithIdentity ((\entry -> "max:j" <> T.pack (show entry.jeJournalId)) <$> row) request.trName request.trArguments)
                        -- Set before returning to guest or caller; JSON cannot
                        -- clear this latch and a subsequent guest trap cannot
                        -- erase the trusted control returned by this call.
                        when (isJust (controlReply result.tiControl)) $
                          liftIO . atomically $
                            writeTVar session.terminal True
                        pure ((), result)
                      pure invocation
        invocations <- restoreBatch (if all canParallel requests then mapConcurrently execute requests else traverse execute requests) `finally` release
        pure (ToolBatch invocations False)

-- | Mask the admission-to-handler gap. The body is cancellable, and every
-- exception after admission (including failed settlement) leaves conservative
-- evidence. Completed journal rows are never overwritten by the unknown path.
withExecutionRecord :: ExecutionHooks es -> ExecutionStep -> JournalStart -> (Maybe JournalExecution -> Eff es (a, ToolInvocation)) -> Eff es (a, ToolInvocation)
withExecutionRecord hooks step start body = mask $ \restore -> do
  hooks.ehCheck
  row <- hooks.ehStart step start
  ( do
      (value, invocation) <- restore (body row)
      for_ row $ \entry -> hooks.ehFinish entry (journalFinish (journalControl invocation))
      pure (value, invocation {tiOutcome = stripJournalMetadata invocation.tiOutcome})
    )
    `catch` \(exception :: SomeException) -> do
      for_ row $ \entry -> hooks.ehUnknown entry (T.pack (show exception))
      throwIO exception

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

-- Durable activation evidence comes only from the typed host channel. The
-- private manifest is stored atomically with the successful tool result.
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
      jsInput = tc.trArguments,
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
